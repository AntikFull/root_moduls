#include "config.hpp"
#include "log.hpp"
#include "strings.hpp"

#include <fstream>
#include <algorithm>
#include <stdexcept>
#include <unordered_set>

namespace smartreward {

HookAction parse_action(const std::string &raw_action) {
    std::string s = to_lower(trim(raw_action));
    if (s == "observe" || s == "resolve" || s == "log") {
        return HookAction::Observe;
    }
    if (s == "always_true" || s == "ready" || s == "true" || s == "return_true") {
        return HookAction::AlwaysTrue;
    }
    if (s == "show_and_reward" || s == "bypass" || s == "show" || s == "reward" || s == "fast_pass" || s == "callback") {
        return HookAction::ShowAndReward;
    }
    if (s == "reachability" || s == "online" || s == "network_online" || s == "network_reachability") {
        return HookAction::Reachability;
    }
    if (s == "forward_interceptor" || s == "intercept_events" || s == "max_forward" || s == "forward_event") {
        return HookAction::ForwardInterceptor;
    }
    return HookAction::Invalid;
}

bool is_valid_action(const std::string &action) {
    return parse_action(action) != HookAction::Invalid;
}

bool wildcard_match(const char *pattern, const char *text) {
    if (!pattern || !text) return false;
    if (strcmp(pattern, "*") == 0 || strcmp(pattern, "") == 0) return true;

    while (*pattern && *text) {
        if (*pattern == '*') {
            while (*pattern == '*') pattern++;
            if (!*pattern) return true;
            while (*text) {
                if (wildcard_match(pattern, text)) return true;
                text++;
            }
            return false;
        } else if (*pattern == '?' || *pattern == *text) {
            pattern++;
            text++;
        } else {
            return false;
        }
    }
    while (*pattern == '*') pattern++;
    return !*pattern && !*text;
}

bool parse_rule_line(const std::string &raw, int line_no, HookRule &out) {
    std::string line = trim(raw);
    if (line.empty() || line[0] == '#') return false;

    if (line.size() > 256) {
        LOGW("[CONF] line %d ignored: line exceeds maximum length of 256 characters", line_no);
        return false;
    }

    // Проверяем наличие префикса assembly: "Assembly-CSharp.dll|Namespace.Class::Method|..."
    std::string assembly;
    std::string rest = line;
    
    const auto first_pipe = line.find('|');
    const auto first_sep = line.find("::");
    if (first_pipe != std::string::npos && first_sep != std::string::npos && first_pipe < first_sep) {
        assembly = trim(line.substr(0, first_pipe));
        rest = trim(line.substr(first_pipe + 1));
    }

    const auto sep1 = rest.find("::");
    const auto sep2 = rest.find('|', sep1 == std::string::npos ? 0 : sep1 + 2);
    const auto sep3 = rest.find('|', sep2 == std::string::npos ? 0 : sep2 + 1);
    if (sep1 == std::string::npos || sep2 == std::string::npos || sep3 == std::string::npos) {
        LOGW("[CONF] line %d ignored: expected [Assembly.dll|]Namespace.Class::Method|action|arg_count", line_no);
        return false;
    }

    const std::string owner = trim(rest.substr(0, sep1));
    out.assembly = assembly;
    out.method_name = trim(rest.substr(sep1 + 2, sep2 - (sep1 + 2)));
    out.action = trim(rest.substr(sep2 + 1, sep3 - (sep2 + 1)));
    const std::string argc_str = trim(rest.substr(sep3 + 1));
    out.line_no = line_no;

    if (owner.empty() || out.method_name.empty() || argc_str.empty()) {
        LOGW("[CONF] line %d ignored: empty owner/method/arg_count", line_no);
        return false;
    }

    // Парсим Namespace и ClassName
    const auto dot = owner.find_last_of('.');
    if (dot == std::string::npos) {
        out.name_space.clear();
        out.class_name = owner;
    } else {
        out.name_space = owner.substr(0, dot);
        out.class_name = owner.substr(dot + 1);
    }
    // Ведущая точка означает класс в глобальном namespace: .MaxSdk -> namespace="", class="MaxSdk"
    if (out.class_name.empty() && !out.name_space.empty()) {
        out.class_name = out.name_space;
        out.name_space.clear();
    }

    if (argc_str == "*" || argc_str == "-1") {
        out.arg_count = -1;
    } else {
        try {
            size_t used = 0;
            out.arg_count = std::stoi(argc_str, &used, 10);
            if (used != argc_str.size() || out.arg_count < -1 || out.arg_count > 32) {
                throw std::invalid_argument("arg_count out of range -1..32");
            }
        } catch (...) {
            LOGW("[CONF] line %d ignored: invalid arg_count '%s'", line_no, argc_str.c_str());
            return false;
        }
    }

    HookAction act = parse_action(out.action);
    if (act == HookAction::Invalid) {
        LOGW("[CONF] line %d warning: unknown action '%s'. Falling back to 'observe'", line_no, out.action.c_str());
        out.action_type = HookAction::Observe;
        out.action = "observe";
    } else {
        out.action_type = act;
        switch (act) {
            case HookAction::Observe: out.action = "observe"; break;
            case HookAction::AlwaysTrue: out.action = "always_true"; break;
            case HookAction::ShowAndReward: out.action = "show_and_reward"; break;
            case HookAction::Reachability: out.action = "reachability"; break;
            case HookAction::ForwardInterceptor: out.action = "forward_interceptor"; break;
            default: out.action = "observe"; break;
        }
    }

    return true;
}

std::vector<HookRule> load_hook_rules(const char *path) {
    std::vector<HookRule> rules;
    std::ifstream in(path);
    if (!in.is_open()) {
        in.open("/data/adb/modules/zygisk_smart_reward_bypass/il2cpp_hooks.conf");
    }
    if (!in.is_open()) {
        LOGW("[CONF] il2cpp_hooks.conf not found; IL2CPP method resolution disabled");
        return rules;
    }

    std::string line;
    int line_no = 0;
    while (std::getline(in, line)) {
        ++line_no;
        if (rules.size() >= 512) {
            LOGW("[CONF] limit of 512 hook rules reached; remaining lines ignored");
            break;
        }

        HookRule rule;
        if (parse_rule_line(line, line_no, rule)) {
            // Проверка на дубликаты
            if (std::find(rules.begin(), rules.end(), rule) == rules.end()) {
                rules.push_back(std::move(rule));
            } else {
                LOGW("[CONF] line %d: duplicate rule ignored (%s%s::%s action=%s argc=%d)",
                     line_no, rule.name_space.empty() ? "" : (rule.name_space + ".").c_str(),
                     rule.class_name.c_str(), rule.method_name.c_str(), rule.action.c_str(), rule.arg_count);
            }
        }
    }

    LOGI("[CONF] loaded %zu rule(s) from %s", rules.size(), path);
    return rules;
}

std::vector<HookRule> g_cached_rules;

} // namespace smartreward
