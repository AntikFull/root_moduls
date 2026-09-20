#pragma once

#include <string>
#include <vector>
#include "../runtimes/il2cpp/il2cpp_symbols.hpp"

namespace smartreward {

struct SdkDetectionResult {
    bool is_present = false;
    std::string sdk_name;
    std::string detected_version;
    std::vector<std::string> hooked_methods;
};

class ISdkAdapter {
public:
    virtual ~ISdkAdapter() = default;
    virtual const char *get_name() const = 0;
    virtual bool probe_and_attach(const Il2CppImage *image,
                                  il2cpp_class_from_name_t class_from_name_fn,
                                  il2cpp_class_get_method_from_name_t class_get_method_fn) = 0;
    virtual void on_reward_granted(const std::string &ad_unit_id, UnitySendMessage_t send_msg_fn) = 0;
};

} // namespace smartreward
