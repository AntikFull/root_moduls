#include "unity_ads_adapter.hpp"
#include "../core/log.hpp"

namespace smartreward {

bool UnityAdsAdapter::probe_and_attach(const Il2CppImage *image,
                                       il2cpp_class_from_name_t class_from_name_fn,
                                       il2cpp_class_get_method_from_name_t class_get_method_fn) {
    if (!image || !class_from_name_fn) return false;

    Il2CppClass *uads_cls = class_from_name_fn(image, "UnityEngine.Advertisements", "Advertisement");
    if (uads_cls) {
        LOGI("[SDK_ADAPTER] [UnityAds] Found Advertisement class in image %p", image);
        return true;
    }
    return false;
}

void UnityAdsAdapter::on_reward_granted(const std::string &ad_unit_id, UnitySendMessage_t send_msg_fn) {
    if (!send_msg_fn) return;

    std::string unit = ad_unit_id.empty() ? "rewardedVideo" : ad_unit_id;
    send_msg_fn("UnityAdsCallbacks", "onUnityAdsAdLoaded", unit.c_str());
    send_msg_fn("UnityAdsCallbacks", "onUnityAdsShowStart", unit.c_str());
    send_msg_fn("UnityAdsCallbacks", "onUnityAdsShowComplete", unit.c_str());
    send_msg_fn("UnityAdsCallbacks", "onUnityAdsFinish", unit.c_str());
    send_msg_fn("UnityAdsCallbacks", "onUnityAdsAdLoaded", unit.c_str());
}

} // namespace smartreward
