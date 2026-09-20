#include "report_writer.hpp"
#include "../core/reward_trace.hpp"
#include "../core/log.hpp"
#include "../core/strings.hpp"

#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <chrono>
#include <functional>
#include <map>
#include <sstream>
#include <vector>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <pthread.h>
#include <thread>

namespace smartreward {
namespace {

uint64_t wall_now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

std::string get_clean_package(const std::string &pkg) {
    auto colon_pos = pkg.find(':');
    return colon_pos == std::string::npos ? pkg : pkg.substr(0, colon_pos);
}

bool atomic_write_file(const std::string &path, const std::string &content) {
    std::string tmp_path = path + ".tmp." + std::to_string(getpid());
    FILE *f = fopen(tmp_path.c_str(), "w");
    if (!f) return false;
    const size_t wrote = fwrite(content.data(), 1, content.size(), f);
    fflush(f);
    fsync(fileno(f));
    fclose(f);
    if (wrote != content.size()) {
        remove(tmp_path.c_str());
        return false;
    }
    if (rename(tmp_path.c_str(), path.c_str()) != 0) {
        remove(tmp_path.c_str());
        return false;
    }
    return true;
}

static std::string s_app_data_dir;

std::string profile_dir_for(const std::string &clean_pkg) {
    std::vector<std::string> roots;
    if (!s_app_data_dir.empty()) {
        roots.push_back(s_app_data_dir + "/files");
        roots.push_back(s_app_data_dir);
    }
    roots.push_back("/data/user/0/" + clean_pkg + "/files");
    roots.push_back("/data/data/" + clean_pkg + "/files");

    for (const auto &root : roots) {
        if (access(root.c_str(), W_OK) != 0) continue;
        std::string dir = root + "/zygisk_smart_reward_bypass";
        if (mkdir(dir.c_str(), 0700) == 0 || errno == EEXIST) return dir;
    }
    return std::string();
}


struct AggregatedFact {
    uint64_t first_seen_ms = 0;
    uint64_t last_seen_ms = 0;
    uint64_t seen_count = 0;
    std::string process;
    std::string type;
    std::string trust;
    std::string source;
    std::string sdk;
    std::string format;
    std::string identifier;
    std::string placement;
    std::string reward_type;
    std::string reward_amount;
    std::string detail;
};

bool extract_flat_json_string(const std::string &line, const char *key, std::string *out) {
    if (!out) return false;
    const std::string marker = std::string("\"") + key + "\":\"";
    size_t pos = line.find(marker);
    if (pos == std::string::npos) return false;
    pos += marker.size();
    std::string value;
    bool escaped = false;
    for (; pos < line.size(); ++pos) {
        char c = line[pos];
        if (!escaped && c == '"') {
            *out = value;
            return true;
        }
        if (escaped) {
            switch (c) {
                case 'n': value.push_back('\n'); break;
                case 'r': value.push_back('\r'); break;
                case 't': value.push_back('\t'); break;
                case '\\': value.push_back('\\'); break;
                case '"': value.push_back('"'); break;
                default: value.push_back(c); break;
            }
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else {
            value.push_back(c);
        }
    }
    return false;
}

bool extract_flat_json_u64(const std::string &line, const char *key, uint64_t *out) {
    if (!out) return false;
    const std::string marker = std::string("\"") + key + "\":";
    size_t pos = line.find(marker);
    if (pos == std::string::npos) return false;
    pos += marker.size();
    while (pos < line.size() && (line[pos] == ' ' || line[pos] == '\t')) ++pos;
    size_t end = pos;
    while (end < line.size() && line[end] >= '0' && line[end] <= '9') ++end;
    if (end == pos) return false;
    try {
        *out = static_cast<uint64_t>(std::stoull(line.substr(pos, end - pos)));
        return true;
    } catch (...) {
        return false;
    }
}


std::string normalize_trust(const std::string &trust) {
    if (trust == "observed" || trust == "inferred" || trust == "synthetic") return trust;
    // Unknown provenance must never be promoted to an observed fact.
    return "inferred";
}

std::string aggregate_key(const AggregatedFact &f) {
    // Process is intentionally not part of the key: the same fact observed from
    // multiple processes is one durable fact with a cumulative seen_count.
    const char sep = '\x1f';
    return f.type + sep + f.trust + sep + f.source + sep + f.sdk + sep + f.format + sep +
           f.identifier + sep + f.placement + sep + f.reward_type + sep + f.reward_amount + sep + f.detail;
}

void emit_fact_json(FILE *out, const AggregatedFact &f) {
    fprintf(out,
            "    {\"first_seen_ms\":%llu,\"last_seen_ms\":%llu,\"seen_count\":%llu,"
            "\"last_process\":\"%s\",\"type\":\"%s\",\"trust\":\"%s\","
            "\"source\":\"%s\",\"sdk\":\"%s\",\"format\":\"%s\","
            "\"identifier\":\"%s\",\"placement\":\"%s\",\"reward_type\":\"%s\","
            "\"reward_amount\":\"%s\",\"detail\":\"%s\"}",
            static_cast<unsigned long long>(f.first_seen_ms),
            static_cast<unsigned long long>(f.last_seen_ms),
            static_cast<unsigned long long>(f.seen_count),
            json_escape(f.process).c_str(), json_escape(f.type).c_str(), json_escape(f.trust).c_str(),
            json_escape(f.source).c_str(), json_escape(f.sdk).c_str(), json_escape(f.format).c_str(),
            json_escape(f.identifier).c_str(), json_escape(f.placement).c_str(), json_escape(f.reward_type).c_str(),
            json_escape(f.reward_amount).c_str(), json_escape(f.detail).c_str());
}

std::string event_json(const std::string &process_name,
                       const std::string &type,
                       const std::string &trust,
                       const std::string &source,
                       const std::string &sdk,
                       const std::string &format,
                       const std::string &identifier,
                       const std::string &placement,
                       const std::string &reward_type,
                       const std::string &reward_amount,
                       const std::string &detail) {
    std::ostringstream ss;
    ss << "{"
       << "\"ts_ms\":" << wall_now_ms() << ","
       << "\"process\":\"" << json_escape(process_name) << "\","
       << "\"type\":\"" << json_escape(type) << "\","
       << "\"trust\":\"" << json_escape(trust) << "\","
       << "\"source\":\"" << json_escape(source) << "\","
       << "\"sdk\":\"" << json_escape(sdk) << "\","
       << "\"format\":\"" << json_escape(format) << "\","
       << "\"identifier\":\"" << json_escape(identifier) << "\","
       << "\"placement\":\"" << json_escape(placement) << "\","
       << "\"reward_type\":\"" << json_escape(reward_type) << "\","
       << "\"reward_amount\":\"" << json_escape(reward_amount) << "\","
       << "\"detail\":\"" << json_escape(detail) << "\"}"
       << "\n";
    return ss.str();
}

bool render_locked(const std::string &clean_pkg, const std::string &dir) {
    const std::string events_path = dir + "/" + clean_pkg + "__events.jsonl";
    const std::string telemetry_path = dir + "/" + clean_pkg + "__latest_telemetry.json";
    const std::string fingerprint_path = dir + "/" + clean_pkg + "__latest_fingerprint.json";
    const std::string report_path = dir + "/" + clean_pkg + "__report.json";
    const std::string tmp_path = report_path + ".tmp." + std::to_string(getpid());

    // Build a durable de-duplicated index while preserving the append-only event stream.
    std::map<std::string, AggregatedFact> index;
    FILE *events = fopen(events_path.c_str(), "r");
    if (events) {
        char *line = nullptr;
        size_t cap = 0;
        ssize_t n = 0;
        while ((n = getline(&line, &cap, events)) > 0) {
            while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
            if (n <= 0 || line[0] != '{') continue;
            std::string raw(line, static_cast<size_t>(n));
            AggregatedFact f;
            extract_flat_json_u64(raw, "ts_ms", &f.last_seen_ms);
            f.first_seen_ms = f.last_seen_ms;
            extract_flat_json_string(raw, "process", &f.process);
            extract_flat_json_string(raw, "type", &f.type);
            extract_flat_json_string(raw, "trust", &f.trust);
            extract_flat_json_string(raw, "source", &f.source);
            extract_flat_json_string(raw, "sdk", &f.sdk);
            extract_flat_json_string(raw, "format", &f.format);
            extract_flat_json_string(raw, "identifier", &f.identifier);
            extract_flat_json_string(raw, "placement", &f.placement);
            extract_flat_json_string(raw, "reward_type", &f.reward_type);
            extract_flat_json_string(raw, "reward_amount", &f.reward_amount);
            extract_flat_json_string(raw, "detail", &f.detail);
            f.seen_count = 1;

            const std::string key = aggregate_key(f);
            auto it = index.find(key);
            if (it == index.end()) {
                index.emplace(key, f);
            } else {
                AggregatedFact &dst = it->second;
                if (dst.first_seen_ms == 0 || (f.first_seen_ms != 0 && f.first_seen_ms < dst.first_seen_ms)) {
                    dst.first_seen_ms = f.first_seen_ms;
                }
                if (f.last_seen_ms >= dst.last_seen_ms) {
                    dst.last_seen_ms = f.last_seen_ms;
                    dst.process = f.process;
                }
                dst.seen_count++;
            }
        }
        free(line);
        fclose(events);
    }

    FILE *out = fopen(tmp_path.c_str(), "w");
    if (!out) return false;
    fprintf(out, "{\n  \"schema_version\": 3,\n  \"package\": \"%s\",\n  \"generated_at_ms\": %llu,\n",
            json_escape(clean_pkg).c_str(), static_cast<unsigned long long>(wall_now_ms()));
    fprintf(out, "  \"trust_model\": {\"observed\":\"received from app/SDK runtime\",\"inferred\":\"derived from classes/methods\",\"synthetic\":\"generated by module; never treat as app fact\"},\n");
    fprintf(out, "  \"fact_index\": [\n");
    bool first_fact = true;
    for (const auto &pair : index) {
        if (!first_fact) fprintf(out, ",\n");
        emit_fact_json(out, pair.second);
        first_fact = false;
    }
    fprintf(out, "\n  ],\n");

    // Full chronological history remains available for forensic/audit use.
    fprintf(out, "  \"observations\": [\n");
    events = fopen(events_path.c_str(), "r");
    bool first = true;
    if (events) {
        char *line = nullptr;
        size_t cap = 0;
        ssize_t n = 0;
        while ((n = getline(&line, &cap, events)) > 0) {
            while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
            if (n <= 0 || line[0] != '{') continue;
            fprintf(out, "%s    %s", first ? "" : ",\n", line);
            first = false;
        }
        free(line);
        fclose(events);
    }
    fprintf(out, "\n  ],\n");

    auto emit_optional_json = [&](const char *name, const std::string &path) {
        fprintf(out, "  \"%s\": ", name);
        FILE *f = fopen(path.c_str(), "r");
        if (!f) {
            fprintf(out, "null");
            return;
        }
        char buf[8192];
        size_t r;
        while ((r = fread(buf, 1, sizeof(buf), f)) > 0) fwrite(buf, 1, r, out);
        fclose(f);
    };

    emit_optional_json("latest_fingerprint", fingerprint_path);
    fprintf(out, ",\n");
    emit_optional_json("latest_reward_telemetry", telemetry_path);
    fprintf(out, "\n}\n");
    fflush(out);
    fsync(fileno(out));
    fclose(out);

    if (rename(tmp_path.c_str(), report_path.c_str()) != 0) {
        remove(tmp_path.c_str());
        return false;
    }
    return true;
}

bool with_profile_lock(const std::string &clean_pkg, const std::function<bool(const std::string&)> &fn) {
    std::string dir = profile_dir_for(clean_pkg);
    if (dir.empty()) return false;
    std::string lock_path = dir + "/.profile.lock";
    FILE *lf = fopen(lock_path.c_str(), "a+");
    if (!lf) return false;
    if (flock(fileno(lf), LOCK_EX) != 0) {
        fclose(lf);
        return false;
    }
    bool ok = fn(dir);
    flock(fileno(lf), LOCK_UN);
    fclose(lf);
    return ok;
}

// Предельный размер журнала событий профиля. Отчёт — диагностический артефакт,
// а не хранилище: при превышении лимита сохраняется одна резервная копия, и
// журнал начинается заново. Иначе полная пересборка отчёта дорожает без предела.
constexpr long kMaxEventLogBytes = 2 * 1024 * 1024;

void rotate_event_log_if_needed(const std::string &path) {
    struct stat st{};
    if (stat(path.c_str(), &st) != 0) return;
    if (st.st_size < kMaxEventLogBytes) return;
    const std::string backup = path + ".1";
    ::remove(backup.c_str());
    ::rename(path.c_str(), backup.c_str());
}

bool append_event_locked(const std::string &clean_pkg, const std::string &dir, const std::string &event) {
    const std::string path = dir + "/" + clean_pkg + "__events.jsonl";
    rotate_event_log_if_needed(path);
    FILE *f = fopen(path.c_str(), "a");
    if (!f) return false;
    const bool ok = fwrite(event.data(), 1, event.size(), f) == event.size();
    fflush(f);
    fclose(f);
    return ok;
}

// ---------------------------------------------------------------------------
// Асинхронная запись профиля.
//
// Пересборка отчёта читает весь журнал событий и переписывает файл целиком.
// Выполнять это в теле перехвата нельзя: перехват срабатывает на главном
// потоке игры, и дисковая операция на мегабайтном файле даёт видимый фриз, а на
// разросшемся профиле — ANR. Поэтому в перехвате выполняется только постановка
// задачи в очередь, а вся работа с диском вынесена в фоновый поток с
// объединением задач по пакету.
// ---------------------------------------------------------------------------
struct ProfileJob {
    std::string package;
    std::string event;      // может быть пустым
    std::string telemetry;  // может быть пустым
};

std::mutex g_job_mutex;
std::condition_variable g_job_cv;
std::vector<ProfileJob> g_jobs;
bool g_worker_started = false;

void *profile_worker(void *) {
    for (;;) {
        std::vector<ProfileJob> batch;
        {
            std::unique_lock<std::mutex> lock(g_job_mutex);
            g_job_cv.wait(lock, [] { return !g_jobs.empty(); });
            batch.swap(g_jobs);
        }

        // Объединение по пакету: события дописываются все, отчёт пересобирается
        // один раз на пакет.
        std::map<std::string, std::string> latest_telemetry;
        std::vector<std::string> order;
        for (const auto &job : batch) {
            if (job.package.empty()) continue;
            if (latest_telemetry.find(job.package) == latest_telemetry.end()) {
                latest_telemetry[job.package] = "";
                order.push_back(job.package);
            }
            if (!job.telemetry.empty()) latest_telemetry[job.package] = job.telemetry;
        }

        for (const auto &pkg : order) {
            with_profile_lock(pkg, [&](const std::string &dir) {
                for (const auto &job : batch) {
                    if (job.package == pkg && !job.event.empty()) {
                        append_event_locked(pkg, dir, job.event);
                    }
                }
                const std::string &tele = latest_telemetry[pkg];
                if (!tele.empty()) {
                    atomic_write_file(dir + "/" + pkg + "__latest_telemetry.json", tele);
                }
                return render_locked(pkg, dir);
            });
        }

        // Пауза объединяет частые события в один проход по диску.
        usleep(2000000);
    }
    return nullptr;
}

void enqueue_profile_job(const std::string &package, const std::string &event,
                         const std::string &telemetry) {
    if (package.empty()) return;
    {
        std::lock_guard<std::mutex> lock(g_job_mutex);
        // Защита от неограниченного роста очереди, если диск недоступен.
        if (g_jobs.size() < 512) {
            g_jobs.push_back(ProfileJob{package, event, telemetry});
        }
        if (!g_worker_started) {
            pthread_t th{};
            if (pthread_create(&th, nullptr, profile_worker, nullptr) == 0) {
                pthread_detach(th);
                g_worker_started = true;
            }
        }
    }
    g_job_cv.notify_one();
}

std::string build_fingerprint_json(const GameFingerprint &fp) {
    std::stringstream ss;
    ss << "{\n";
    ss << "  \"package\": \"" << json_escape(get_clean_package(fp.package_name)) << "\",\n";
    ss << "  \"process\": \"" << json_escape(fp.package_name) << "\",\n";
    ss << "  \"engine\": \"" << json_escape(fp.engine) << "\",\n";
    ss << "  \"abi\": \"" << json_escape(fp.abi) << "\",\n";
    ss << "  \"assemblies\": " << fp.assemblies_count << ",\n";
    ss << "  \"methodsSeen\": " << fp.methods_seen << ",\n";
    ss << "  \"totalMethodsIndexed\": " << fp.total_methods_indexed << ",\n";
    ss << "  \"scanTruncated\": " << (fp.scan_truncated ? "true" : "false") << ",\n";
    ss << "  \"indexBudget\": " << METADATA_INDEX_BUDGET << ",\n";
    ss << "  \"sdks\": [\n";
    for (size_t i = 0; i < fp.detected_sdks.size(); ++i) {
        ss << "    \"" << json_escape(fp.detected_sdks[i]) << "\""
           << (i + 1 < fp.detected_sdks.size() ? "," : "") << "\n";
    }
    ss << "  ],\n";
    ss << "  \"candidates\": [\n";
    for (size_t i = 0; i < fp.candidates.size(); ++i) {
        const auto &c = fp.candidates[i];
        const char *tier = c.confidence_tier == ConfidenceTier::SdkConfirmed ? "SDK_CONFIRMED" :
                           (c.confidence_tier == ConfidenceTier::AdSemantic ? "AD_SEMANTIC" : "HEURISTIC_ONLY");
        ss << "    {\n"
           << "      \"assembly\": \"" << json_escape(c.assembly) << "\",\n"
           << "      \"namespace\": \"" << json_escape(c.name_space) << "\",\n"
           << "      \"class\": \"" << json_escape(c.class_name) << "\",\n"
           << "      \"method\": \"" << json_escape(c.method_name) << "\",\n"
           << "      \"tier\": \"" << tier << "\",\n"
           << "      \"static\": " << (c.is_static ? "true" : "false") << ",\n"
           << "      \"return\": \"" << json_escape(c.return_type) << "\",\n"
           << "      \"paramCount\": " << c.param_count << ",\n"
           << "      \"scores\": {\"lexical\":" << c.lexical_score
           << ",\"signature\":" << c.signature_score
           << ",\"sdk\":" << c.sdk_score
           << ",\"total\":" << c.total_score << "},\n"
           << "      \"params\": [";
        for (size_t p = 0; p < c.param_types.size(); ++p) {
            if (p) ss << ",";
            ss << "\"" << json_escape(c.param_types[p]) << "\"";
        }
        ss << "]\n    }" << (i + 1 < fp.candidates.size() ? "," : "") << "\n";
    }
    ss << "  ]\n}";
    return ss.str();
}

std::string build_legacy_runtime_report(const GameFingerprint &fp, const std::string &telemetry) {
    std::string out = build_fingerprint_json(fp);
    const size_t pos = out.find_last_of('}');
    if (pos != std::string::npos) out.erase(pos);
    out += ",\n  \"reward_telemetry\": " + telemetry + "\n}\n";
    return out;
}

} // namespace

bool ReportWriter::initialize_process(const std::string &package_name, const std::string &process_name, const std::string &app_data_dir) {
    if (!app_data_dir.empty()) {
        s_app_data_dir = app_data_dir;
    }
    if (package_name.empty()) return false;
    const std::string clean_pkg = get_clean_package(package_name);
    return record_ad_observation(clean_pkg, process_name, "process_session", "observed",
                                 "zygisk", "", "", "", "", "", "", "process started");
}

bool ReportWriter::record_ad_observation(const std::string &package_name,
                                         const std::string &process_name,
                                         const std::string &type,
                                         const std::string &trust,
                                         const std::string &source,
                                         const std::string &sdk,
                                         const std::string &format,
                                         const std::string &identifier,
                                         const std::string &placement,
                                         const std::string &reward_type,
                                         const std::string &reward_amount,
                                         const std::string &detail) {
    if (package_name.empty()) return false;
    const std::string clean_pkg = get_clean_package(package_name);
    const std::string safe_trust = normalize_trust(trust);
    const std::string event = event_json(process_name, type, safe_trust, source, sdk, format,
                                         identifier, placement, reward_type, reward_amount, detail);
    enqueue_profile_job(clean_pkg, event, "");
    return true;
}

bool ReportWriter::write_json_report(const GameFingerprint &fp) {
    if (fp.package_name.empty()) return false;
    const std::string clean_pkg = get_clean_package(fp.package_name);
    const std::string fingerprint_json = build_fingerprint_json(fp);

    bool profile_ok = with_profile_lock(clean_pkg, [&](const std::string &dir) {
        atomic_write_file(dir + "/" + clean_pkg + "__latest_fingerprint.json", fingerprint_json);
        for (const auto &sdk : fp.detected_sdks) {
            append_event_locked(clean_pkg, dir,
                event_json(fp.package_name, "sdk_detected", "inferred", "il2cpp_fingerprint",
                           sdk, "", "", "", "", "", "class/method fingerprint"));
        }
        for (const auto &c : fp.candidates) {
            const char *tier = c.confidence_tier == ConfidenceTier::SdkConfirmed ? "SDK_CONFIRMED" :
                               (c.confidence_tier == ConfidenceTier::AdSemantic ? "AD_SEMANTIC" : "HEURISTIC_ONLY");
            std::string detail = c.assembly + ":" + c.name_space + "." + c.class_name + "::" + c.method_name +
                                 " tier=" + tier + " score=" + std::to_string(c.total_score);
            append_event_locked(clean_pkg, dir,
                event_json(fp.package_name, "method_candidate", "inferred", "il2cpp_metadata",
                           "", "", "", "", "", "", detail));
        }
        return render_locked(clean_pkg, dir);
    });

    // Keep the old snapshot paths and top-level schema for backwards compatibility.
    const std::string content = build_legacy_runtime_report(
        fp, RewardTraceManager::instance().to_json_summary());
    atomic_write_file("/data/user/0/" + clean_pkg + "/cache/runtime_report.json", content);
    atomic_write_file("/data/data/" + clean_pkg + "/cache/runtime_report.json", content);
    return profile_ok;
}

bool ReportWriter::update_telemetry(const std::string &package_name, const std::string &telemetry_json) {
    if (package_name.empty() || telemetry_json.empty()) return false;
    const std::string clean_pkg = get_clean_package(package_name);
    enqueue_profile_job(clean_pkg, "", telemetry_json);
    return true;
}

bool ReportWriter::render_package_report(const std::string &package_name) {
    if (package_name.empty()) return false;
    const std::string clean_pkg = get_clean_package(package_name);
    return with_profile_lock(clean_pkg, [&](const std::string &dir) { return render_locked(clean_pkg, dir); });
}

} // namespace smartreward
