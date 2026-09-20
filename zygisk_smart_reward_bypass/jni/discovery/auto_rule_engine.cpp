#include "auto_rule_engine.hpp"
#include "../core/log.hpp"
#include "../core/strings.hpp"
#include "../core/page_protect.hpp"
#include "../core/reward_trace.hpp"
#include "../core/il2cpp_api.hpp"
#include <fstream>
#include <algorithm>

namespace smartreward {

namespace {

std::string normalize_lower(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (std::isalnum(static_cast<unsigned char>(c))) {
            out.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
        }
    }
    return out;
}

bool is_explicit_non_ad_class(const MethodDescriptor &m) {
    std::string norm_cls = normalize_lower(m.class_name);
    std::string norm_ns = normalize_lower(m.name_space);
    std::string combined = norm_ns + norm_cls;

    const char *non_ad_tokens[] = {
        "crashlytics", "analytics", "performance", "firebase", "fabric",
        "sentry", "adjust", "singular", "appsflyer", "bugsnag", "logger",
        "telemetry", "profiler", "remoteconfig", "pushnotification",
        "notification", "iap", "billing", "store", "purchasing", "login",
        "auth", "user", "device", "audio", "sound", "graphics", "camera"
    };

    for (const char *t : non_ad_tokens) {
        if (combined.find(t) != std::string::npos) return true;
    }
    return false;
}

bool has_ad_context(const MethodDescriptor &m) {
    if (is_explicit_non_ad_class(m)) return false;

    std::string norm_cls = normalize_lower(m.class_name);
    std::string norm_ns = normalize_lower(m.name_space);
    std::string combined = norm_ns + norm_cls;

    // Do not use the bare token "ad" as a substring marker.  It matches many
    // unrelated words (for example "load") and was a major source of false
    // positives.  Keep only advertising-specific class/namespace markers.
    const char *tokens[] = {
        "ads", "admanager", "adhandler", "adservice", "adcontroller",
        "rewarded", "rewardedvideo", "rewardedad", "rvad", "monetiz",
        "placement", "interstitial", "bannerad", "nativead", "appopenad",
        "applovin", "maxsdk", "admob", "googlemobileads",
        "ironsource", "levelplay", "unityads", "yandexmobileads",
        "vungle", "pangle", "mintegral", "chartboost", "fyber", "adcolony",
        "voodoo", "voodoosauce", "adn", "adnsdk", "adcontainer", "adbridge",
        "adshow", "showrv", "rvready", "rewardpopup", "adpop", "fakead",
        "adunit", "adshowoperation", "mobileads", "pockethaven"
    };

    for (const char *t : tokens) {
        if (combined.find(t) != std::string::npos) return true;
    }
    return false;
}

bool is_manually_covered(const MethodDescriptor &m, const std::vector<HookRule> &rules) {
    for (const auto &r : rules) {
        bool asm_match = (r.assembly.empty() || r.assembly == "*" || wildcard_match(r.assembly.c_str(), m.assembly.c_str()));
        bool ns_match = (r.name_space.empty() || r.name_space == "*" || wildcard_match(r.name_space.c_str(), m.name_space.c_str()));
        bool class_match = (r.class_name.empty() || r.class_name == "*" || wildcard_match(r.class_name.c_str(), m.class_name.c_str()));
        bool method_match = (r.method_name.empty() || r.method_name == "*" || wildcard_match(r.method_name.c_str(), m.method_name.c_str()));
        bool argc_match = (r.arg_count == -1 || r.arg_count == static_cast<int>(m.param_count));

        if (asm_match && ns_match && class_match && method_match && argc_match) {
            return true;
        }
    }
    return false;
}

} // namespace

std::vector<InferredRule> AutoRuleEngine::infer_rules(
        const GameFingerprint &fingerprint,
        const std::vector<HookRule> &manual_rules) {

    std::vector<InferredRule> result;
    result.reserve(64);

    for (const auto &candidate : fingerprint.candidates) {
        if (!candidate.method_ptr) continue;

        // Исключаем методы с неподдерживаемым ABI (>5 аргументов)
        if (candidate.param_count > 5) continue;

        // Строгий запрет на крашлитику, аналитику и нерекламные подсистемы
        if (is_explicit_non_ad_class(candidate)) continue;

        // Если правило уже явно задано в ручном конфиге (с поддержкой wildcard), пропускаем
        if (is_manually_covered(candidate, manual_rules)) continue;

        std::string norm_method = normalize_lower(candidate.method_name);
        std::string norm_class = normalize_lower(candidate.class_name);
        bool ad_ctx = has_ad_context(candidate);

        // --- 0. Категория: Проверка доступности сети (UnityEngine.Application::get_internetReachability) ---
        if ((norm_method == "get_internetreachability" || norm_method == "getinternetreachability") &&
            candidate.param_count == 0) {
            InferredRule r;
            r.method = candidate;
            r.action_type = HookAction::Reachability;
            r.action_str = "reachability";
            r.reason = "Auto-Inferred Unity Internet Reachability Spoofer";
            result.push_back(r);
            continue;
        }

        // --- 1. Категория: Проверка готовности рекламы (IsReady, IsLoaded, IsAvailable, CanShow) ---
        if (candidate.return_type == "System.Boolean" && candidate.param_count <= 2) {
            bool is_ready_name = norm_method.find("isready") != std::string::npos ||
                                 norm_method.find("isloaded") != std::string::npos ||
                                 norm_method.find("isavailable") != std::string::npos ||
                                 norm_method.find("canshow") != std::string::npos ||
                                 norm_method.find("isrvready") != std::string::npos ||
                                 norm_method.find("isrewardedadready") != std::string::npos ||
                                 norm_method.find("isrewardedavailable") != std::string::npos ||
                                 norm_method.find("isrewardedvideoavailable") != std::string::npos ||
                                 norm_method.find("isinterstitialavailable") != std::string::npos ||
                                 norm_method.find("isinterstitialready") != std::string::npos ||
                                 norm_method.find("getisrvready") != std::string::npos ||
                                 norm_method.find("getisready") != std::string::npos ||
                                 norm_method.find("isvideoavailable") != std::string::npos ||
                                 norm_method.find("hasvideo") != std::string::npos ||
                                 norm_method.find("get_rewardreceived") != std::string::npos ||
                                 norm_method.find("get_iscompleted") != std::string::npos ||
                                 norm_method.find("get_success") != std::string::npos;

            // Требуется обязательный рекламный контекст (ad_ctx); SdkConfirmed сам по себе недостаточен!
            if (is_ready_name && ad_ctx) {
                InferredRule r;
                r.method = candidate;
                r.action_type = HookAction::AlwaysTrue;
                r.action_str = "always_true";
                r.reason = "Auto-Inferred Ad Readiness Boolean Method";
                result.push_back(r);
                continue;
            }

            bool is_load_name = norm_method.find("loadrv") != std::string::npos ||
                                norm_method.find("loadrewarded") != std::string::npos ||
                                norm_method.find("loadinterstitial") != std::string::npos ||
                                norm_method.find("requestrewarded") != std::string::npos;
            if (is_load_name && ad_ctx) {
                InferredRule r;
                r.method = candidate;
                r.action_type = HookAction::AlwaysTrue;
                r.action_str = "always_true";
                r.reason = "Auto-Inferred Ad Load Suppressor Method";
                result.push_back(r);
                continue;
            }
        }

        // --- 2. Категория: Показ рекламы через рекламные SDK (ShowRV, ShowRewarded, ShowInterstitial) ---
        bool is_show_name = norm_method.find("showrv") != std::string::npos ||
                            norm_method.find("showrewarded") != std::string::npos ||
                            norm_method.find("showinterstitial") != std::string::npos ||
                            norm_method.find("confirmshowrewarded") != std::string::npos;

        if (is_show_name && (ad_ctx || candidate.confidence_tier == ConfidenceTier::SdkConfirmed)) {
            // Строго System.Void для предотвращения повреждения стека возврата структур на ARM64
            if (candidate.return_type == "System.Void") {
                InferredRule r;
                r.method = candidate;
                r.action_type = HookAction::ShowAndReward;
                r.action_str = "show_and_reward";
                r.reason = "Auto-Inferred Ad Show Trigger";
                result.push_back(r);
                continue;
            }
        }

        // --- 3. Категория: Фоновые коллбэки SDK (HandleBackgroundCallback, ForwardEvent) ---
        if (norm_method.find("handlebackgroundcallback") != std::string::npos ||
            norm_method == "forwardevent") {
            InferredRule r;
            r.method = candidate;
            r.action_type = HookAction::ForwardInterceptor;
            r.action_str = "forward_interceptor";
            r.reason = "Auto-Inferred SDK Background Callback Interceptor";
            result.push_back(r);
            continue;
        }
    }

    LOGI("[AUTO_RULE] Inferred %zu dynamic hook rule(s) from metadata index", result.size());
    return result;
}

size_t AutoRuleEngine::apply_rules(const std::vector<InferredRule> &rules) {
    size_t applied = 0;
    for (const auto &r : rules) {
        if (!r.method.method_ptr) continue;

        std::string desc_str = (r.method.name_space.empty()
                                    ? r.method.class_name
                                    : r.method.name_space + "." + r.method.class_name) +
                               "::" + r.method.method_name;

        switch (r.action_type) {
            case HookAction::AlwaysTrue: {
                const bool ok = Il2CppResolver::instance().hook_method_always_true(r.method.method_ptr, desc_str.c_str());
                if (ok) {
                    LOGI("[AUTO_RULE_APPLY] [ALWAYS_TRUE] success target=%s args=%d ret=%s tier=%d reason=%s",
                         desc_str.c_str(), r.method.param_count, r.method.return_type.c_str(),
                         static_cast<int>(r.method.confidence_tier), r.reason.c_str());
                    applied++;
                } else {
                    LOGW("[AUTO_RULE_APPLY] [ALWAYS_TRUE] failed target=%s; not counted as applied", desc_str.c_str());
                }
                break;
            }
            case HookAction::ShowAndReward: {
                const bool ok = Il2CppResolver::instance().hook_method_show_and_reward(
                    r.method.method_ptr, desc_str.c_str(), r.method.assembly.c_str());
                if (ok) {
                    LOGI("[AUTO_RULE_APPLY] [SHOW_AND_REWARD] success target=%s args=%d ret=%s tier=%d reason=%s",
                         desc_str.c_str(), r.method.param_count, r.method.return_type.c_str(),
                         static_cast<int>(r.method.confidence_tier), r.reason.c_str());
                    applied++;
                } else {
                    LOGW("[AUTO_RULE_APPLY] [SHOW_AND_REWARD] failed target=%s; not counted as applied", desc_str.c_str());
                }
                break;
            }
            case HookAction::Reachability: {
                const bool ok = Il2CppResolver::instance().hook_method_network_reachability(r.method.method_ptr, desc_str.c_str());
                if (ok) {
                    LOGI("[AUTO_RULE_APPLY] [REACHABILITY] success target=%s args=%d ret=%s tier=%d reason=%s",
                         desc_str.c_str(), r.method.param_count, r.method.return_type.c_str(),
                         static_cast<int>(r.method.confidence_tier), r.reason.c_str());
                    applied++;
                } else {
                    LOGW("[AUTO_RULE_APPLY] [REACHABILITY] failed target=%s; not counted as applied", desc_str.c_str());
                }
                break;
            }
            case HookAction::ForwardInterceptor: {
                const bool ok = Il2CppResolver::instance().hook_method_forward_interceptor(r.method.method_ptr, desc_str.c_str());
                if (ok) {
                    LOGI("[AUTO_RULE_APPLY] [FORWARD_INTERCEPTOR] success target=%s args=%d ret=%s tier=%d reason=%s",
                         desc_str.c_str(), r.method.param_count, r.method.return_type.c_str(),
                         static_cast<int>(r.method.confidence_tier), r.reason.c_str());
                    applied++;
                } else {
                    LOGW("[AUTO_RULE_APPLY] [FORWARD_INTERCEPTOR] failed target=%s; not counted as applied", desc_str.c_str());
                }
                break;
            }
            case HookAction::Observe:
                // v3.9.1 replaced the original callback pointer with a stub and never
                // called the original method. That is destructive, not observation.
                // Keep the candidate in exported diagnostics, but do not mutate runtime
                // until a real trampoline that preserves the original callback exists.
                LOGW("[AUTO_RULE_APPLY] [OBSERVE_SKIPPED] target=%s reason=destructive_observer_not_safe",
                     desc_str.c_str());
                break;
            default:
                break;
        }
    }
    return applied;
}

void AutoRuleEngine::export_inferred_rules(
        const std::string &package_name,
        const std::vector<InferredRule> &rules) {

    std::vector<std::string> paths = {
        "/data/user/0/" + package_name + "/files/zygisk_smart_reward_bypass/" + package_name + "_auto_rules.conf",
        "/data/data/" + package_name + "/files/zygisk_smart_reward_bypass/" + package_name + "_auto_rules.conf",
        "/data/data/" + package_name + "/cache/smart_reward_auto_rules.conf"
    };

    std::string content;
    content.reserve(2048);
    content += "# ============================================================\n";
    content += "# Smart Reward Auto-Inferred Rules (AutoRuleEngine)\n";
    content += "# Package: " + package_name + "\n";
    content += "# Total Inferred Rules: " + std::to_string(rules.size()) + "\n";
    content += "# ============================================================\n\n";

    for (const auto &r : rules) {
        content += "# Reason: " + r.reason + " (Tier=" + std::to_string(static_cast<int>(r.method.confidence_tier))
                 + ", Score=" + std::to_string(r.method.total_score) + ")\n";
        content += r.method.assembly + "|" + r.method.class_name + "::" + r.method.method_name
                 + "|" + r.action_str + "|" + std::to_string(r.method.param_count) + "\n\n";
    }

    for (const auto &path : paths) {
        std::ofstream out(path);
        if (out.is_open()) {
            out << content;
            out.flush();
            LOGI("[AUTO_RULE] Exported %zu inferred rules to %s", rules.size(), path.c_str());
            break;
        }
    }
}

} // namespace smartreward
