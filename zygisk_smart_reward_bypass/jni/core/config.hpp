#pragma once

#include <string>
#include <vector>

namespace smartreward {

enum class HookAction {
    Observe,
    AlwaysTrue,
    ShowAndReward,
    Reachability,
    ForwardInterceptor,
    Invalid
};

struct HookRule {
    std::string assembly;
    std::string name_space;
    std::string class_name;
    std::string method_name;
    std::string action = "observe";
    HookAction action_type = HookAction::Observe;
    int arg_count = -1;
    int line_no = 0;

    bool operator==(const HookRule &other) const {
        return assembly == other.assembly &&
               name_space == other.name_space &&
               class_name == other.class_name &&
               method_name == other.method_name &&
               action_type == other.action_type &&
               arg_count == other.arg_count;
    }
};

HookAction parse_action(const std::string &raw_action);
bool is_valid_action(const std::string &action);
bool parse_rule_line(const std::string &raw, int line_no, HookRule &out);
bool wildcard_match(const char *pattern, const char *text);
std::vector<HookRule> load_hook_rules(const char *path = "/data/adb/zygisk_smart_reward_bypass/il2cpp_hooks.conf");

extern std::vector<HookRule> g_cached_rules;

} // namespace smartreward
