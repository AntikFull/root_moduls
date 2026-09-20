#include "yandex_adapter.hpp"
#include "../core/log.hpp"

namespace smartreward {

bool YandexAdsAdapter::probe_and_attach(const Il2CppImage *image,
                                        il2cpp_class_from_name_t class_from_name_fn,
                                        il2cpp_class_get_method_from_name_t class_get_method_fn) {
    if (!image || !class_from_name_fn) return false;

    Il2CppClass *ya_cls = class_from_name_fn(image, "YandexMobileAds", "RewardedAd");
    if (ya_cls) {
        LOGI("[SDK_ADAPTER] [YandexMobileAds] Found Yandex Mobile Ads class in image %p", image);
        return true;
    }
    return false;
}

void YandexAdsAdapter::on_reward_granted(const std::string &ad_unit_id, UnitySendMessage_t send_msg_fn) {
    if (!send_msg_fn) return;

    send_msg_fn("YandexMobileAdsRewardCallback", "OnRewarded", "1");
    send_msg_fn("YandexMobileAdsCallback", "OnAdDismissed", "");
    send_msg_fn("YandexMobileAdsCallback", "OnAdLoaded", "");
}

} // namespace smartreward
