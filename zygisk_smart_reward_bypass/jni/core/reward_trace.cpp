#include "reward_trace.hpp"
#include "log.hpp"
#include "strings.hpp"
#include "../discovery/report_writer.hpp"

#include <chrono>
#include <sstream>
#include <iomanip>
#include <algorithm>

namespace smartreward {

namespace {

uint64_t steady_now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

uint64_t wall_now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
}

} // namespace

RewardTraceManager &RewardTraceManager::instance() {
    static RewardTraceManager s_instance;
    return s_instance;
}

void RewardTraceManager::evict_oldest_trace_locked() {
    if (trace_order_.empty()) return;

    // 1. Поиск завершенных или упавших с ошибкой трейсов
    for (auto it = trace_order_.begin(); it != trace_order_.end(); ++it) {
        auto tr_it = traces_.find(*it);
        if (tr_it != traces_.end()) {
            if (tr_it->second.ad_state == AdState::Completed || tr_it->second.ad_state == AdState::Failed) {
                uint64_t tid = *it;
                trace_order_.erase(it);
                traces_.erase(tid);
                return;
            }
        }
    }

    // 2. Поиск устаревших трейсов (stale > 5 минут)
    uint64_t now_steady = steady_now_ms();
    for (auto it = trace_order_.begin(); it != trace_order_.end(); ++it) {
        auto tr_it = traces_.find(*it);
        if (tr_it != traces_.end()) {
            if (now_steady - tr_it->second.steady_last_event_ms > 300000) {
                uint64_t tid = *it;
                trace_order_.erase(it);
                traces_.erase(tid);
                return;
            }
        }
    }

    // 3. Крайний случай: удаление самого старого трейса из очереди
    uint64_t oldest_id = trace_order_.front();
    trace_order_.pop_front();
    traces_.erase(oldest_id);
}

uint64_t RewardTraceManager::start_trace(const std::string &package, const std::string &process,
                                        const std::string &engine, const std::string &sdk,
                                        const std::string &placement, uintptr_t obj_ptr, int confidence) {
    std::lock_guard<std::mutex> lock(mutex_);
    uint64_t tid = ++next_trace_id_;
    uint64_t now_steady = steady_now_ms();
    uint64_t now_wall = wall_now_ms();

    // Извлечение чистого базового пакета
    std::string clean_pkg = package.empty() ? "unknown_package" : package;
    auto colon_pos = clean_pkg.find(':');
    if (colon_pos != std::string::npos) {
        clean_pkg = clean_pkg.substr(0, colon_pos);
    }

    RewardTrace trace;
    trace.id = tid;
    trace.package_name = clean_pkg;
    trace.process_name = process.empty() ? clean_pkg : process;
    trace.engine = engine;
    trace.sdk = sdk;
    trace.placement = placement.empty() ? "default_rewarded" : placement;
    trace.rewarded_object = obj_ptr;
    trace.steady_started_ms = now_steady;
    trace.steady_last_event_ms = now_steady;
    trace.wall_started_ms = now_wall;
    trace.ad_state = AdState::Loading;
    trace.highest_stage = RewardStage::ProcessDetected;
    trace.failed_at_stage = RewardStage::ProcessDetected;
    trace.failure = RewardFailure::None;
    trace.confidence = confidence;
    trace.facts.fact_process_detected = true;

    std::string start_msg = "START package=" + trace.package_name + " process=" + trace.process_name +
                            " engine=" + engine + " sdk=" + sdk + " placement=" + trace.placement;
    trace.event_log.push_back(start_msg);

    // Умное вытеснение (Smart LRU) при достижении лимита
    if (trace_order_.size() >= MAX_TRACES) {
        evict_oldest_trace_locked();
    }
    trace_order_.push_back(tid);
    traces_[tid] = trace;

    LOGI("[RW][T#%llu] %s", static_cast<unsigned long long>(tid), start_msg.c_str());
    return tid;
}

void RewardTraceManager::apply_event(uint64_t trace_id, LifecycleEvent event,
                                     RewardFailure failure,
                                     const std::string &detail) {
    std::string pkg_to_update;
    std::string telemetry_json;

    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = traces_.find(trace_id);
        if (it == traces_.end()) {
            LOGW("[RW] UNATTRIBUTED event detail=%s (no matching trace %llu)",
                 detail.c_str(), static_cast<unsigned long long>(trace_id));
            return;
        }

        RewardTrace &trace = it->second;
        trace.steady_last_event_ms = steady_now_ms();
        uint64_t now_wall = wall_now_ms();

        AdState prev_state = trace.ad_state;

        switch (event) {
            case LifecycleEvent::LoadRequested:
                trace.ad_state = AdState::Loading;
                break;
            case LifecycleEvent::LoadSuccess:
                trace.ad_state = AdState::Loaded;
                break;
            case LifecycleEvent::ReadyObserved:
            case LifecycleEvent::ReadyOverrideApplied:
                trace.ad_state = AdState::Ready;
                break;
            case LifecycleEvent::ShowRequested:
                trace.facts.fact_show_observed = true;
                trace.facts.ts_show_ms = now_wall;
                trace.ad_state = AdState::Showing;
                break;
            case LifecycleEvent::Displayed:
                trace.facts.fact_display_observed = true;
                trace.facts.ts_display_ms = now_wall;
                trace.ad_state = AdState::Showing;
                break;
            case LifecycleEvent::Completed:
                trace.facts.fact_completion_observed = true;
                trace.facts.ts_completion_ms = now_wall;
                trace.ad_state = AdState::Completed;
                break;
            case LifecycleEvent::RewardGranted:
                trace.facts.fact_reward_observed = true;
                trace.facts.ts_reward_ms = now_wall;
                break;
            case LifecycleEvent::Failed:
                trace.facts.fact_failed = true;
                trace.facts.ts_failed_ms = now_wall;
                trace.failure = failure;
                trace.ad_state = AdState::Failed;
                break;
        }

        std::string msg = "EVENT state=" + std::string(to_string(trace.ad_state));
        if (!detail.empty()) msg += " " + detail;
        if (failure != RewardFailure::None) msg += " reason=" + std::string(to_string(failure));

        if (trace.event_log.size() >= MAX_EVENT_LOG) {
            trace.event_log.erase(trace.event_log.begin());
        }
        trace.event_log.push_back(msg);

        // Запись телеметрии только при переходе в терминальное состояние или получении награды
        if ((trace.ad_state == AdState::Completed || trace.ad_state == AdState::Failed) &&
            (prev_state != trace.ad_state || event == LifecycleEvent::RewardGranted)) {
            print_reward_summary_locked(trace_id);
            pkg_to_update = trace.package_name;
            telemetry_json = to_json_summary_locked();
        }
    }

    if (!pkg_to_update.empty() && !telemetry_json.empty()) {
        ReportWriter::update_telemetry(pkg_to_update, telemetry_json);
    }
}

void RewardTraceManager::record_stage(uint64_t trace_id, RewardStage stage,
                                      RewardFailure failure,
                                      const std::string &detail) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = traces_.find(trace_id);
        if (it != traces_.end()) {
            RewardTrace &trace = it->second;
            if (static_cast<int>(stage) > static_cast<int>(trace.highest_stage)) {
                trace.highest_stage = stage;
            }
            if (failure != RewardFailure::None) {
                trace.failed_at_stage = stage;
            }
        }
    }

    if (failure != RewardFailure::None) {
        apply_event(trace_id, LifecycleEvent::Failed, failure, detail);
    } else {
        switch (stage) {
            case RewardStage::ShowObserved:
                apply_event(trace_id, LifecycleEvent::ShowRequested, RewardFailure::None, detail);
                break;
            case RewardStage::AdDisplayed:
                apply_event(trace_id, LifecycleEvent::Displayed, RewardFailure::None, detail);
                break;
            case RewardStage::CompletionObserved:
                apply_event(trace_id, LifecycleEvent::Completed, RewardFailure::None, detail);
                break;
            case RewardStage::RewardCallbackObserved:
                apply_event(trace_id, LifecycleEvent::RewardGranted, RewardFailure::None, detail);
                break;
            case RewardStage::Finished:
                apply_event(trace_id, LifecycleEvent::Completed, RewardFailure::None, detail);
                break;
            default:
                break;
        }
    }
}

uint64_t RewardTraceManager::correlate_trace(uintptr_t obj_ptr, const std::string &placement, const std::string &sdk) {
    std::lock_guard<std::mutex> lock(mutex_);
    uint64_t now_steady = steady_now_ms();

    // 1. Поиск по точному совпадению указателя объекта
    if (obj_ptr != 0) {
        std::vector<uint64_t> matches;
        for (const auto &pair : traces_) {
            if (pair.second.rewarded_object == obj_ptr && (now_steady - pair.second.steady_last_event_ms < 60000)) {
                matches.push_back(pair.first);
            }
        }
        if (matches.size() == 1) {
            return matches[0];
        } else if (matches.size() > 1) {
            LOGW("[RW] AMBIGUOUS match by object 0x%lx (count=%zu); ContextCollision",
                 static_cast<unsigned long>(obj_ptr), matches.size());
            return 0;
        }
    }

    // 2. Поиск по placement & sdk за последние 30 секунд
    if (!placement.empty()) {
        std::vector<uint64_t> matches;
        for (const auto &pair : traces_) {
            if (pair.second.placement == placement && (sdk.empty() || pair.second.sdk == sdk) &&
                (now_steady - pair.second.steady_last_event_ms < 30000)) {
                matches.push_back(pair.first);
            }
        }
        if (matches.size() == 1) {
            return matches[0];
        } else if (matches.size() > 1) {
            LOGW("[RW] AMBIGUOUS match by placement '%s' (count=%zu); ContextCollision",
                 placement.c_str(), matches.size());
            return 0;
        }
    }

    // 3. Поиск единственного активного трейса того же SDK
    std::vector<uint64_t> matches;
    for (const auto &pair : traces_) {
        if ((sdk.empty() || pair.second.sdk == sdk) && pair.second.ad_state != AdState::Completed &&
            pair.second.ad_state != AdState::Failed && (now_steady - pair.second.steady_last_event_ms < 20000)) {
            matches.push_back(pair.first);
        }
    }
    if (matches.size() == 1) {
        return matches[0];
    } else if (matches.size() > 1) {
        LOGW("[RW] AMBIGUOUS match by active SDK '%s' (count=%zu); ContextCollision",
             sdk.c_str(), matches.size());
        return 0;
    }

    LOGI("[RW] CONTEXT_LOST (no unique active trace found for placement=%s sdk=%s)",
         placement.c_str(), sdk.c_str());
    return 0;
}

void RewardTraceManager::print_reward_summary_locked(uint64_t trace_id) const {
    auto it = traces_.find(trace_id);
    if (it == traces_.end()) return;

    const RewardTrace &trace = it->second;
    uint64_t duration = (trace.steady_last_event_ms >= trace.steady_started_ms)
                            ? (trace.steady_last_event_ms - trace.steady_started_ms)
                            : 0;

    std::stringstream ss;
    ss << "\n================ REWARD TRACE ================\n"
       << "trace_id:       " << trace.id << "\n"
       << "package:        " << trace.package_name << "\n"
       << "process:        " << trace.process_name << "\n"
       << "engine:         " << trace.engine << "\n"
       << "sdk:            " << trace.sdk << " (confidence=" << trace.confidence << "%)\n"
       << "placement:      " << trace.placement << "\n"
       << "duration:       " << duration << " ms\n\n"
       << "ad state:       " << to_string(trace.ad_state) << "\n"
       << "highest stage:  " << to_string(trace.highest_stage) << "\n"
       << "failed at:      " << to_string(trace.failed_at_stage) << "\n"
       << "failure reason: " << to_string(trace.failure) << "\n"
       << "facts:          show=" << trace.facts.fact_show_observed
       << " disp=" << trace.facts.fact_display_observed
       << " comp=" << trace.facts.fact_completion_observed
       << " rwd=" << trace.facts.fact_reward_observed << "\n"
       << "==============================================";
    LOGI("%s", ss.str().c_str());
}

void RewardTraceManager::print_reward_summary(uint64_t trace_id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    print_reward_summary_locked(trace_id);
}

void RewardTraceManager::record_ready_check(const ReadyTrace &ready) {
    std::lock_guard<std::mutex> lock(mutex_);
    uint64_t now_wall = (ready.last_seen_ms != 0) ? ready.last_seen_ms : wall_now_ms();

    // Точный ключ агрегации с временным окном COALESCE_WINDOW_MS (2000 мс)
    if (!ready_checks_.empty()) {
        auto &last = ready_checks_.back();
        if (last.trace_id == ready.trace_id &&
            last.object == ready.object &&
            last.sdk == ready.sdk &&
            last.format == ready.format &&
            last.placement == ready.placement &&
            last.class_name == ready.class_name &&
            last.method_name == ready.method_name &&
            last.event_type == ready.event_type &&
            last.origin == ready.origin &&
            last.transport == ready.transport &&
            last.observed_value == ready.observed_value &&
            last.effective_value == ready.effective_value &&
            last.reason == ready.reason &&
            (now_wall - last.last_seen_ms <= COALESCE_WINDOW_MS)) {
            last.count++;
            last.last_seen_ms = now_wall;
            return;
        }
    }

    ReadyTrace item = ready;
    if (item.first_seen_ms == 0) item.first_seen_ms = now_wall;
    if (item.last_seen_ms == 0) item.last_seen_ms = now_wall;

    if (ready_checks_.size() >= MAX_READY_CHECKS) {
        ready_checks_.erase(ready_checks_.begin());
    }
    ready_checks_.push_back(item);

    LOGI("[READY-CHECK] type=%s origin=%s transport=%s sdk=%s %s::%s obs=%s eff=%s reason=%s",
         to_string(item.event_type), to_string(item.origin), to_string(item.transport),
         item.sdk.c_str(), item.class_name.c_str(), item.method_name.c_str(),
         val_to_string(item.observed_value), val_to_string(item.effective_value),
         to_string(item.reason));
}

void RewardTraceManager::print_readiness_summary() const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (ready_checks_.empty()) return;

    std::stringstream ss;
    ss << "\n========== AD READINESS REPORT ==========\n"
       << "Total checks: " << ready_checks_.size() << "\n";
    for (const auto &r : ready_checks_) {
        ss << "  - [" << to_string(r.event_type) << "][" << to_string(r.origin)
           << "/" << to_string(r.transport) << "] " << r.sdk << " " << r.class_name << "::" << r.method_name
           << " obs=" << val_to_string(r.observed_value) << " eff=" << val_to_string(r.effective_value)
           << " (count=" << r.count << ", reason=" << to_string(r.reason) << ")\n";
    }
    ss << "=========================================";
    LOGI("%s", ss.str().c_str());
}

std::string RewardTraceManager::to_json_summary_locked() const {
    std::stringstream ss;
    ss << "{\n";
    ss << "  \"total_traces\": " << traces_.size() << ",\n";
    ss << "  \"traces\": [\n";

    size_t idx = 0;
    for (const auto &pair : traces_) {
        const auto &t = pair.second;
        uint64_t duration = (t.steady_last_event_ms >= t.steady_started_ms)
                                ? (t.steady_last_event_ms - t.steady_started_ms)
                                : 0;
        ss << "    {\n"
           << "      \"trace_id\": " << t.id << ",\n"
           << "      \"package\": \"" << json_escape(t.package_name) << "\",\n"
           << "      \"process\": \"" << json_escape(t.process_name) << "\",\n"
           << "      \"engine\": \"" << json_escape(t.engine) << "\",\n"
           << "      \"sdk\": \"" << json_escape(t.sdk) << "\",\n"
           << "      \"placement\": \"" << json_escape(t.placement) << "\",\n"
           << "      \"object\": \"0x" << std::hex << t.rewarded_object << std::dec << "\",\n"
           << "      \"confidence\": " << t.confidence << ",\n"
           << "      \"ad_state\": \"" << to_string(t.ad_state) << "\",\n"
           << "      \"highest_stage\": \"" << to_string(t.highest_stage) << "\",\n"
           << "      \"failed_at\": \"" << to_string(t.failed_at_stage) << "\",\n"
           << "      \"failure\": \"" << to_string(t.failure) << "\",\n"
           << "      \"duration_ms\": " << duration << ",\n"
           << "      \"wall_timestamp\": " << t.wall_started_ms << ",\n"
           << "      \"facts\": {\n"
           << "        \"show_observed\": " << (t.facts.fact_show_observed ? "true" : "false") << ",\n"
           << "        \"display_observed\": " << (t.facts.fact_display_observed ? "true" : "false") << ",\n"
           << "        \"completion_observed\": " << (t.facts.fact_completion_observed ? "true" : "false") << ",\n"
           << "        \"reward_observed\": " << (t.facts.fact_reward_observed ? "true" : "false") << "\n"
           << "      },\n"
           << "      \"event_log\": [\n";
        for (size_t e = 0; e < t.event_log.size(); ++e) {
            ss << "        \"" << json_escape(t.event_log[e]) << "\"" << (e + 1 < t.event_log.size() ? "," : "") << "\n";
        }
        ss << "      ]\n"
           << "    }" << (++idx < traces_.size() ? "," : "") << "\n";
    }
    ss << "  ],\n";

    ss << "  \"ready_checks\": [\n";
    for (size_t i = 0; i < ready_checks_.size(); ++i) {
        const auto &r = ready_checks_[i];
        ss << "    {\n"
           << "      \"trace_id\": " << r.trace_id << ",\n"
           << "      \"event_type\": \"" << to_string(r.event_type) << "\",\n"
           << "      \"origin\": \"" << to_string(r.origin) << "\",\n"
           << "      \"transport\": \"" << to_string(r.transport) << "\",\n"
           << "      \"sdk\": \"" << json_escape(r.sdk) << "\",\n"
           << "      \"format\": \"" << json_escape(r.format) << "\",\n"
           << "      \"placement\": \"" << json_escape(r.placement) << "\",\n"
           << "      \"class\": \"" << json_escape(r.class_name) << "\",\n"
           << "      \"method\": \"" << json_escape(r.method_name) << "\",\n"
           << "      \"observed_value\": \"" << val_to_string(r.observed_value) << "\",\n"
           << "      \"effective_value\": \"" << val_to_string(r.effective_value) << "\",\n"
           << "      \"count\": " << r.count << ",\n"
           << "      \"first_seen_ms\": " << r.first_seen_ms << ",\n"
           << "      \"last_seen_ms\": " << r.last_seen_ms << ",\n"
           << "      \"reason\": \"" << to_string(r.reason) << "\"\n"
           << "    }" << (i + 1 < ready_checks_.size() ? "," : "") << "\n";
    }
    ss << "  ]\n";
    ss << "}";
    return ss.str();
}

std::string RewardTraceManager::to_json_summary() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return to_json_summary_locked();
}

const char *RewardTraceManager::to_string(RewardStage stage) {
    switch (stage) {
        case RewardStage::ProcessDetected: return "ProcessDetected";
        case RewardStage::EngineDetected: return "EngineDetected";
        case RewardStage::RuntimeReady: return "RuntimeReady";
        case RewardStage::SdkDetected: return "SdkDetected";
        case RewardStage::RewardObjectFound: return "RewardObjectFound";
        case RewardStage::PlacementResolved: return "PlacementResolved";
        case RewardStage::ShowObserved: return "ShowObserved";
        case RewardStage::ListenerResolved: return "ListenerResolved";
        case RewardStage::AdDisplayed: return "AdDisplayed";
        case RewardStage::CompletionObserved: return "CompletionObserved";
        case RewardStage::RewardCallbackObserved: return "RewardCallbackObserved";
        case RewardStage::AppHandlerObserved: return "AppHandlerObserved";
        case RewardStage::Finished: return "Finished";
        default: return "Unknown";
    }
}

const char *RewardTraceManager::to_string(AdState state) {
    switch (state) {
        case AdState::Unknown: return "Unknown";
        case AdState::SdkUnavailable: return "SdkUnavailable";
        case AdState::SdkInitializing: return "SdkInitializing";
        case AdState::ObjectMissing: return "ObjectMissing";
        case AdState::Idle: return "Idle";
        case AdState::Loading: return "Loading";
        case AdState::Loaded: return "Loaded";
        case AdState::Ready: return "Ready";
        case AdState::Showing: return "Showing";
        case AdState::Completed: return "Completed";
        case AdState::Failed: return "Failed";
        default: return "Unknown";
    }
}

const char *RewardTraceManager::to_string(ReadyOrigin origin) {
    switch (origin) {
        case ReadyOrigin::Sdk: return "Sdk";
        case ReadyOrigin::GameWrapper: return "GameWrapper";
        case ReadyOrigin::UiGate: return "UiGate";
        default: return "Unknown";
    }
}

const char *RewardTraceManager::to_string(ReadyTransport transport) {
    switch (transport) {
        case ReadyTransport::Native: return "Native";
        case ReadyTransport::Il2Cpp: return "Il2Cpp";
        case ReadyTransport::Jni: return "Jni";
        case ReadyTransport::Java: return "Java";
        default: return "Unknown";
    }
}

const char *RewardTraceManager::to_string(ReadyEventType event_type) {
    switch (event_type) {
        case ReadyEventType::Observed: return "READY_OBSERVED";
        case ReadyEventType::OverrideApplied: return "READY_OVERRIDE_APPLIED";
        case ReadyEventType::Lifecycle: return "LIFECYCLE_EVENT";
        default: return "UNKNOWN";
    }
}

const char *RewardTraceManager::to_string(RewardFailure failure) {
    switch (failure) {
        case RewardFailure::None: return "None";
        case RewardFailure::UnsupportedEngine: return "UNSUPPORTED_ENGINE";
        case RewardFailure::RuntimeNotLoaded: return "RUNTIME_NOT_LOADED";
        case RewardFailure::RuntimeInitTimeout: return "RUNTIME_INIT_TIMEOUT";
        case RewardFailure::SdkNotDetected: return "SDK_NOT_DETECTED";
        case RewardFailure::SdkVersionUnknown: return "SDK_VERSION_UNKNOWN";
        case RewardFailure::BackendUnavailable: return "BACKEND_UNAVAILABLE";
        case RewardFailure::RewardObjectNotFound: return "REWARD_OBJECT_NOT_FOUND";
        case RewardFailure::MethodNotFound: return "METHOD_NOT_FOUND";
        case RewardFailure::SignatureMismatch: return "SIGNATURE_MISMATCH";
        case RewardFailure::AbiUnsafe: return "ABI_UNSAFE";
        case RewardFailure::ListenerNotFound: return "LISTENER_NOT_FOUND";
        case RewardFailure::ListenerInstalledLate: return "LISTENER_INSTALLED_LATE";
        case RewardFailure::ShowNotObserved: return "SHOW_NOT_OBSERVED";
        case RewardFailure::DisplayCallbackMissing: return "DISPLAY_CALLBACK_MISSING";
        case RewardFailure::CompletionCallbackMissing: return "COMPLETION_CALLBACK_MISSING";
        case RewardFailure::RewardCallbackMissing: return "REWARD_CALLBACK_MISSING";
        case RewardFailure::AppHandlerMissing: return "APP_HANDLER_MISSING";
        case RewardFailure::PlacementUnknown: return "PLACEMENT_UNKNOWN";
        case RewardFailure::ContextLost: return "CONTEXT_LOST";
        case RewardFailure::ContextCollision: return "CONTEXT_COLLISION";
        case RewardFailure::SecondaryProcessIgnored: return "SECONDARY_PROCESS_IGNORED";
        case RewardFailure::TargetFiltered: return "TARGET_FILTERED";
        case RewardFailure::ServerSideValidationLikely: return "SERVER_SIDE_VALIDATION_LIKELY";
        case RewardFailure::InternalError: return "INTERNAL_ERROR";
        default: return "UNKNOWN";
    }
}

const char *RewardTraceManager::to_string(NotReadyReason reason) {
    switch (reason) {
        case NotReadyReason::Unknown: return "UNKNOWN";
        case NotReadyReason::NotLoaded: return "NOT_LOADED";
        case NotReadyReason::LoadNotStarted: return "LOAD_NOT_STARTED";
        case NotReadyReason::LoadInProgress: return "LOAD_IN_PROGRESS";
        case NotReadyReason::LoadFailed: return "LOAD_FAILED";
        case NotReadyReason::NoNetwork: return "NO_NETWORK";
        case NotReadyReason::NoFill: return "NO_FILL";
        case NotReadyReason::SdkNotInitialized: return "SDK_NOT_INITIALIZED";
        case NotReadyReason::ConsentRequired: return "CONSENT_REQUIRED";
        case NotReadyReason::PlacementInvalid: return "PLACEMENT_INVALID";
        case NotReadyReason::Cooldown: return "COOLDOWN";
        case NotReadyReason::FrequencyCap: return "FREQUENCY_CAP";
        case NotReadyReason::BackendUnavailable: return "BACKEND_UNAVAILABLE";
        case NotReadyReason::ObjectNotFound: return "OBJECT_NOT_FOUND";
        case NotReadyReason::CallbackMissing: return "CALLBACK_MISSING";
        default: return "UNKNOWN";
    }
}

const char *RewardTraceManager::val_to_string(int8_t val) {
    if (val == 1) return "true";
    if (val == 0) return "false";
    return "unknown";
}

} // namespace smartreward
