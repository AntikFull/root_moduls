#pragma once

#include "sdk_adapter.hpp"

namespace smartreward {

class YandexAdsAdapter : public ISdkAdapter {
public:
    const char *get_name() const override { return "YandexMobileAds"; }

    bool probe_and_attach(const Il2CppImage *image,
                          il2cpp_class_from_name_t class_from_name_fn,
                          il2cpp_class_get_method_from_name_t class_get_method_fn) override;

    void on_reward_granted(const std::string &ad_unit_id, UnitySendMessage_t send_msg_fn) override;
};

} // namespace smartreward
