#pragma once

#include <string>
#include <vector>

namespace smartreward {

struct TargetRule {
    std::string pattern;
    bool is_exclude = false;
    bool is_exact = false;
};

bool is_protected_process(const char *name, int uid);
bool is_target_process(const char *process_name);

std::vector<TargetRule> load_target_rules(const char *path = "/data/adb/zygisk_smart_reward_bypass/smart_reward.list");
bool match_process_rules(const std::string &process_name, const std::vector<TargetRule> &rules);

} // namespace smartreward
