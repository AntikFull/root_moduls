#include "ironsource_adapter.hpp"
#include "../core/log.hpp"

namespace smartreward {

bool IronSourceAdapter::probe_and_attach(const Il2CppImage *image,
                                         il2cpp_class_from_name_t class_from_name_fn,
                                         il2cpp_class_get_method_from_name_t class_get_method_fn) {
    if (!image || !class_from_name_fn) return false;

    Il2CppClass *iron_cls = class_from_name_fn(image, "", "IronSource");
    if (iron_cls) {
        LOGI("[SDK_ADAPTER] [IronSource] Found IronSource class in image %p", image);
        return true;
    }
    return false;
}

void IronSourceAdapter::on_reward_granted(const std::string &ad_unit_id, UnitySendMessage_t send_msg_fn) {
    if (!send_msg_fn) return;

    std::string unit = ad_unit_id.empty() ? "DefaultRewardedVideo" : ad_unit_id;
    const char *availJson = "{\"available\":\"true\"}";
    std::string ironJson = "{\"placement_name\":\"" + unit + "\",\"reward_name\":\"coins\",\"reward_amount\":\"1\"}";

    send_msg_fn("IronSourceEvents", "onRewardedVideoAvailabilityChanged", availJson);
    send_msg_fn("IronSourceEvents", "onRewardedVideoAdOpened", "");
    send_msg_fn("IronSourceEvents", "onRewardedVideoAdRewarded", ironJson.c_str());
    send_msg_fn("IronSourceEvents", "onRewardedVideoAdClosed", "");
    send_msg_fn("IronSourceEvents", "onRewardedVideoAvailabilityChanged", availJson);
}

} // namespace smartreward
