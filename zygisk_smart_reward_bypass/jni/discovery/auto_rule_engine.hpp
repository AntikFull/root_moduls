#pragma once

#include <string>
#include <vector>
#include "fingerprint.hpp"
#include "../core/config.hpp"
#include "../runtimes/il2cpp/il2cpp_catalog.hpp"

namespace smartreward {

struct InferredRule {
    MethodDescriptor method;
    HookAction action_type = HookAction::Invalid;
    std::string action_str;
    std::string reason;
};

class AutoRuleEngine {
public:
    // Анализирует метаданные игры и выводит безопасные правила инъекций
    static std::vector<InferredRule> infer_rules(
        const GameFingerprint &fingerprint,
        const std::vector<HookRule> &manual_rules);

    // Применяет выведенные правила в runtime
    static size_t apply_rules(const std::vector<InferredRule> &rules);

    // Сохраняет выведенные правила в файл отчета
    static void export_inferred_rules(
        const std::string &package_name,
        const std::vector<InferredRule> &rules);
};

} // namespace smartreward
