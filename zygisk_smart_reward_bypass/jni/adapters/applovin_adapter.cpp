#include "applovin_adapter.hpp"
#include "../core/log.hpp"
#include "../core/page_protect.hpp"

namespace smartreward {

extern std::string g_captured_ad_unit_id;
extern std::mutex g_state_mutex;

bool AppLovinMaxAdapter::probe_and_attach(const Il2CppImage *image,
                                          il2cpp_class_from_name_t class_from_name_fn,
                                          il2cpp_class_get_method_from_name_t class_get_method_fn) {
    if (!image || !class_from_name_fn) return false;

    Il2CppClass *max_sdk = class_from_name_fn(image, "", "MaxSdk");
    if (!max_sdk) {
        max_sdk = class_from_name_fn(image, "", "MaxSdkAndroid");
    }

    if (max_sdk) {
        LOGI("[SDK_ADAPTER] [AppLovin.MAX] Found MaxSdk class in image %p", image);
        return true;
    }
    return false;
}

void AppLovinMaxAdapter::on_reward_granted(const std::string &ad_unit_id, UnitySendMessage_t send_msg_fn) {
    if (!send_msg_fn) return;

    std::string unit = ad_unit_id;
    if (unit.empty() || unit == "default_rewarded") {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        unit = g_captured_ad_unit_id.empty() ? "default_rewarded" : g_captured_ad_unit_id;
    }

    LOGI("[SDK_ADAPTER] [AppLovin.MAX] Granting virtual reward for adUnitId=%s", unit.c_str());

    std::string init_json = "{\"name\":\"OnSdkInitializedEvent\",\"hasUserConsent\":true,\"isAgeRestrictedUser\":false,\"isDoNotSell\":false,\"countryCode\":\"US\"}";
    std::string loaded_json = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + unit + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + unit + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";
    std::string displayed_json = "{\"name\":\"OnRewardedAdDisplayedEvent\",\"adUnitId\":\"" + unit + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + unit + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";
    std::string revenue_json = "{\"name\":\"OnRewardedAdRevenuePaidEvent\",\"adUnitId\":\"" + unit + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + unit + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";
    std::string reward_json = "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + unit + "\",\"rewardLabel\":\"coins\",\"rewardAmount\":1,\"reward\":{\"label\":\"coins\",\"amount\":1},\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + unit + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";
    std::string hidden_json = "{\"name\":\"OnRewardedAdHiddenEvent\",\"adUnitId\":\"" + unit + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + unit + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";

    send_msg_fn("MaxSdkCallbacks", "ForwardEvent", init_json.c_str());
    send_msg_fn("MaxSdkCallbacks", "ForwardEvent", loaded_json.c_str());
    send_msg_fn("MaxSdkCallbacks", "ForwardEvent", displayed_json.c_str());
    send_msg_fn("MaxSdkCallbacks", "ForwardEvent", revenue_json.c_str());
    send_msg_fn("MaxSdkCallbacks", "ForwardEvent", reward_json.c_str());
    send_msg_fn("MaxSdkCallbacks", "ForwardEvent", hidden_json.c_str());
    send_msg_fn("MaxSdkCallbacks", "ForwardEvent", loaded_json.c_str());
}

} // namespace smartreward
