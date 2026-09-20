#include "fingerprint.hpp"
#include "../core/log.hpp"
#include "../core/strings.hpp"
#include <algorithm>
#include <cctype>

namespace smartreward {

namespace {

#if defined(__aarch64__)
constexpr const char *CURRENT_ABI = "arm64-v8a";
#elif defined(__arm__)
constexpr const char *CURRENT_ABI = "armeabi-v7a";
#elif defined(__i386__)
constexpr const char *CURRENT_ABI = "x86";
#elif defined(__x86_64__)
constexpr const char *CURRENT_ABI = "x86_64";
#else
constexpr const char *CURRENT_ABI = "unknown";
#endif

// Настоящий токенизатор идентификаторов по camelCase, PascalCase, _, ., ::, -
void tokenize_identifier(const std::string &str, std::vector<std::string> &tokens) {
    if (str.empty()) return;

    std::string current;
    for (size_t i = 0; i < str.length(); ++i) {
        char c = str[i];
        if (c == '_' || c == '.' || c == ':' || c == '-' || c == '/' || c == '$' || c == '<' || c == '>' || c == '`') {
            if (!current.empty()) {
                tokens.push_back(to_lower(current));
                current.clear();
            }
            continue;
        }

        // Переход lowercase -> UPPERCASE (camelCase boundary)
        if (std::isupper(static_cast<unsigned char>(c))) {
            if (!current.empty() && !std::isupper(static_cast<unsigned char>(str[i - 1]))) {
                tokens.push_back(to_lower(current));
                current.clear();
            }
        }

        current += c;
    }

    if (!current.empty()) {
        tokens.push_back(to_lower(current));
    }
}

// Нормализатор: очищает строку от разделителей для надежного поиска составных паттернов
std::string normalize_name(const std::string &str) {
    std::string out;
    out.reserve(str.size());
    for (char c : str) {
        if (std::isalnum(static_cast<unsigned char>(c))) {
            out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
        }
    }
    return out;
}

bool has_exact_token(const std::vector<std::string> &tokens, const std::string &target) {
    for (const auto &t : tokens) {
        if (t == target) return true;
    }
    return false;
}

bool has_token_pair(const std::vector<std::string> &tokens, const std::string &t1, const std::string &t2) {
    bool f1 = false, f2 = false;
    for (const auto &t : tokens) {
        if (t == t1) f1 = true;
        if (t == t2) f2 = true;
    }
    return f1 && f2;
}

bool has_token_triple(const std::vector<std::string> &tokens, const std::string &t1, const std::string &t2, const std::string &t3) {
    bool f1 = false, f2 = false, f3 = false;
    for (const auto &t : tokens) {
        if (t == t1) f1 = true;
        if (t == t2) f2 = true;
        if (t == t3) f3 = true;
    }
    return f1 && f2 && f3;
}

} // namespace

void FingerprintCollector::score_method(MethodDescriptor &m, const std::vector<std::string> &sdks) {
    m.lexical_score = 0;
    m.signature_score = 0;
    m.sdk_score = 0;
    m.confidence_tier = ConfidenceTier::HeuristicOnly;

    std::string norm_class = normalize_name(m.class_name);
    std::string norm_method = normalize_name(m.method_name);
    std::string norm_ns = normalize_name(m.name_space);
    std::string norm_full = norm_ns + norm_class + norm_method;

    std::vector<std::string> name_tokens;
    tokenize_identifier(m.class_name, name_tokens);
    tokenize_identifier(m.method_name, name_tokens);
    tokenize_identifier(m.name_space, name_tokens);

    bool has_ad_token = has_exact_token(name_tokens, "reward") || has_exact_token(name_tokens, "rewarded") ||
                        has_exact_token(name_tokens, "rv") || has_exact_token(name_tokens, "ad") ||
                        has_exact_token(name_tokens, "ads") ||
                        norm_full.find("maxsdk") != std::string::npos || norm_full.find("applovin") != std::string::npos ||
                        norm_full.find("googlemobileads") != std::string::npos || norm_full.find("admob") != std::string::npos ||
                        norm_full.find("ironsource") != std::string::npos || norm_full.find("unityads") != std::string::npos ||
                        norm_full.find("voodoosauce") != std::string::npos || norm_full.find("yandexmobileads") != std::string::npos;

    // Исключение нерелевантных системных подсистем (IAP, Audio, Physics, Scene, Analytics) при отсутствии рекламных токенов
    bool is_non_ad_system = has_exact_token(name_tokens, "purchase") || has_exact_token(name_tokens, "shop") ||
                            has_exact_token(name_tokens, "iap") || has_exact_token(name_tokens, "billing") ||
                            norm_method.find("restoretransactions") != std::string::npos ||
                            has_exact_token(name_tokens, "audio") || has_exact_token(name_tokens, "sound") ||
                            has_exact_token(name_tokens, "scene") || has_exact_token(name_tokens, "physics") ||
                            has_exact_token(name_tokens, "camera");

    if (is_non_ad_system && !has_ad_token) {
        m.total_score = 0;
        m.confidence_tier = ConfidenceTier::HeuristicOnly;
        return;
    }

    // 1. Строгая проверка на известные официальные рекламные SDK (Tier 1: SDK-Confirmed)
    bool is_sdk = false;
    if (norm_full.find("maxsdk") != std::string::npos || norm_full.find("applovin") != std::string::npos ||
        has_token_pair(name_tokens, "max", "sdk")) {
        is_sdk = true;
        m.sdk_score += 45;
    } else if (norm_full.find("googlemobileads") != std::string::npos || norm_full.find("admob") != std::string::npos ||
               has_token_triple(name_tokens, "google", "mobile", "ads") || has_token_pair(name_tokens, "google", "admob")) {
        is_sdk = true;
        m.sdk_score += 45;
    } else if (norm_full.find("unityads") != std::string::npos ||
               (has_exact_token(name_tokens, "unity") && (has_exact_token(name_tokens, "ads") || has_exact_token(name_tokens, "advertisements")))) {
        is_sdk = true;
        m.sdk_score += 45;
    } else if (norm_full.find("ironsource") != std::string::npos || has_token_pair(name_tokens, "iron", "source")) {
        is_sdk = true;
        m.sdk_score += 45;
    } else if (norm_full.find("voodoosauce") != std::string::npos || has_token_pair(name_tokens, "voodoo", "sauce")) {
        is_sdk = true;
        m.sdk_score += 45;
    } else if (norm_full.find("yandexmobileads") != std::string::npos ||
               (has_exact_token(name_tokens, "yandex") && (has_exact_token(name_tokens, "ads") || has_exact_token(name_tokens, "mobile")))) {
        is_sdk = true;
        m.sdk_score += 45;
    }

    for (const auto &sdk : sdks) {
        std::string norm_sdk = normalize_name(sdk);
        if (!norm_sdk.empty() && norm_full.find(norm_sdk) != std::string::npos) {
            is_sdk = true;
            m.sdk_score += 35;
            break;
        }
    }

    // 2. Лексический скоринг по токенам и нормализованным последовательностям
    bool is_ready_pattern = (has_exact_token(name_tokens, "is") && has_exact_token(name_tokens, "ready")) ||
                            norm_method.find("isready") != std::string::npos;
    bool is_loaded_pattern = (has_exact_token(name_tokens, "is") && has_exact_token(name_tokens, "loaded")) ||
                             norm_method.find("isloaded") != std::string::npos;
    bool is_avail_pattern = (has_exact_token(name_tokens, "is") && has_exact_token(name_tokens, "available")) ||
                            norm_method.find("isavailable") != std::string::npos;
    bool can_show_pattern = (has_exact_token(name_tokens, "can") && has_exact_token(name_tokens, "show")) ||
                            norm_method.find("canshow") != std::string::npos;
    bool is_rv_ready = norm_method.find("isrewardedadready") != std::string::npos ||
                       norm_method.find("isrewardedready") != std::string::npos ||
                       norm_method.find("isrvready") != std::string::npos;

    if (is_rv_ready) {
        m.lexical_score += 55;
    } else if (has_exact_token(name_tokens, "reward") || has_exact_token(name_tokens, "rewarded")) {
        m.lexical_score += 45;
    } else if (has_exact_token(name_tokens, "rv")) {
        m.lexical_score += 40;
    } else if (has_exact_token(name_tokens, "ad") || has_exact_token(name_tokens, "ads")) {
        m.lexical_score += 25;
    }

    if (is_ready_pattern || is_loaded_pattern || is_avail_pattern || can_show_pattern) {
        m.lexical_score += (has_ad_token ? 30 : 10);
    }

    // 3. Сигнатурный структурный скоринг
    bool has_callback = false;
    bool has_bool_callback = false;
    size_t string_count = 0;

    for (const auto &ptype : m.param_types) {
        if (ptype.find("Action") != std::string::npos ||
            ptype.find("Delegate") != std::string::npos ||
            ptype.find("Callback") != std::string::npos) {
            has_callback = true;
            if (ptype.find("Boolean") != std::string::npos || ptype.find("bool") != std::string::npos) {
                has_bool_callback = true;
            }
        }
        if (ptype.find("String") != std::string::npos || ptype.find("string") != std::string::npos) {
            string_count++;
        }
    }

    if (string_count == 1) {
        m.signature_score += 10;
    } else if (string_count >= 2) {
        m.signature_score += 15;
    }

    if (has_bool_callback) {
        m.signature_score += 40;
    } else if (has_callback) {
        m.signature_score += 20;
    }

    if (has_bool_callback && (m.return_type.find("Void") != std::string::npos || m.return_type.find("void") != std::string::npos)) {
        m.signature_score += 30;
    }

    if ((m.return_type.find("Boolean") != std::string::npos || m.return_type.find("bool") != std::string::npos) && m.param_count <= 2) {
        m.signature_score += 25;
    }

    m.total_score = m.lexical_score + m.signature_score + m.sdk_score;

    // 4. Определение уровня уверенности (Confidence Tier)
    if (is_sdk && (m.lexical_score > 0 || m.signature_score > 0)) {
        m.confidence_tier = ConfidenceTier::SdkConfirmed;
    } else if (has_ad_token && m.total_score >= 50) {
        m.confidence_tier = ConfidenceTier::AdSemantic;
    } else {
        m.confidence_tier = ConfidenceTier::HeuristicOnly;
        if (m.total_score > 35) m.total_score = 35;
    }
}

GameFingerprint FingerprintCollector::build_from_index(
        const std::string &package_name,
        size_t assemblies_count,
        const std::vector<std::string> &sdks,
        MetadataIndex &index) {

    GameFingerprint fp;
    fp.package_name = package_name;
    fp.abi = CURRENT_ABI;
    fp.assemblies_count = assemblies_count;
    fp.methods_seen = index.get_methods_seen();
    fp.total_methods_indexed = index.get_methods_indexed();
    fp.scan_truncated = index.is_scan_truncated();
    fp.detected_sdks = sdks;

    auto &all_methods = index.get_mutable_methods();
    fp.candidates.reserve(128);

    for (auto &m : all_methods) {
        score_method(m, sdks);

        // Отбираем в отчет кандидатов Tier 1, Tier 2 или высоковероятные Tier 3
        if (m.confidence_tier == ConfidenceTier::SdkConfirmed ||
            m.confidence_tier == ConfidenceTier::AdSemantic ||
            (m.confidence_tier == ConfidenceTier::HeuristicOnly && m.total_score >= 30)) {
            fp.candidates.push_back(m);
        }
    }

    // Сортировка кандидатов: сначала по Tier (SdkConfirmed -> AdSemantic -> HeuristicOnly), затем по total_score
    std::sort(fp.candidates.begin(), fp.candidates.end(),
              [](const MethodDescriptor &a, const MethodDescriptor &b) {
                  if (static_cast<int>(a.confidence_tier) != static_cast<int>(b.confidence_tier)) {
                      return static_cast<int>(a.confidence_tier) < static_cast<int>(b.confidence_tier);
                  }
                  return a.total_score > b.total_score;
              });

    LOGI("[DISCOVERY] Evaluated %zu indexed methods (seen %zu, budget=%zu, truncated=%d) -> found %zu high-confidence candidates for %s",
         fp.total_methods_indexed, fp.methods_seen, index.get_index_budget(), fp.scan_truncated, fp.candidates.size(), package_name.c_str());

    return fp;
}

} // namespace smartreward
