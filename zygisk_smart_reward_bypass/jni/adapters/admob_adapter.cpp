#include "admob_adapter.hpp"
#include "../core/log.hpp"

namespace smartreward {

bool GoogleAdMobAdapter::probe_and_attach(const Il2CppImage *image,
                                          il2cpp_class_from_name_t class_from_name_fn,
                                          il2cpp_class_get_method_from_name_t class_get_method_fn) {
    if (!image || !class_from_name_fn) return false;

    Il2CppClass *admob_cls = class_from_name_fn(image, "GoogleMobileAds.Api", "RewardedAd");
    if (!admob_cls) {
        admob_cls = class_from_name_fn(image, "GoogleMobileAds.Api", "MobileAds");
    }

    if (admob_cls) {
        LOGI("[SDK_ADAPTER] [GoogleMobileAds] Found AdMob class in image %p", image);
        return true;
    }
    return false;
}

void GoogleAdMobAdapter::on_reward_granted(const std::string &ad_unit_id, UnitySendMessage_t send_msg_fn) {
    if (!send_msg_fn) return;

    send_msg_fn("GoogleMobileAdsCallbacks", "onRewardedAdLoaded", "");
    send_msg_fn("GoogleMobileAdsCallbacks", "onAdShowedFullScreenContent", "");
    send_msg_fn("GoogleMobileAdsCallbacks", "onUserEarnedReward", "1");
    send_msg_fn("GoogleMobileAdsCallbacks", "onAdDismissedFullScreenContent", "");
    send_msg_fn("GoogleMobileAdsCallbacks", "onRewardedAdLoaded", "");
}

} // namespace smartreward
