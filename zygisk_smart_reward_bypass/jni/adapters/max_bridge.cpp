#include "max_bridge.hpp"
#include "../core/log.hpp"

#include <algorithm>

namespace smartreward {

namespace {

// Событие MAX в том виде, в каком его формирует штатная заглушка плагина
// (MaxSdkUnityEditor.cs -> CreateBaseEventPropsDictionary).
std::string base_event(const std::string &name, const std::string &unit) {
    return "{\"name\":\"" + name + "\",\"adUnitId\":\"" + unit + "\",\"placement\":\"\"}";
}

std::string reward_event(const std::string &unit) {
    return "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + unit +
           "\",\"placement\":\"\",\"rewardLabel\":\"coins\",\"rewardAmount\":\"5\"}";
}

} // namespace

MaxBridge &MaxBridge::instance() {
    static MaxBridge s_instance;
    return s_instance;
}

void MaxBridge::bind(const MethodInfo *forward_event, il2cpp_string_new_t string_new) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!forward_event || !forward_event->methodPointer || !string_new) {
        LOGW("[MAX_BRIDGE] Не удалось привязаться: ForwardEvent=%p string_new=%p",
             reinterpret_cast<const void *>(forward_event), reinterpret_cast<void *>(string_new));
        return;
    }
    forward_event_ = forward_event;
    string_new_ = string_new;
    LOGI("[MAX_BRIDGE] Привязан к MaxSdkCallbacks::ForwardEvent (addr=%p)",
         reinterpret_cast<void *>(forward_event->methodPointer));
}

bool MaxBridge::ready() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return forward_event_ != nullptr && string_new_ != nullptr;
}

void MaxBridge::remember_unit(const std::string &unit) {
    if (unit.empty() || unit == "default_rewarded") return;
    std::lock_guard<std::mutex> lock(mutex_);
    if (std::find(known_units_.begin(), known_units_.end(), unit) == known_units_.end()) {
        known_units_.push_back(unit);
        LOGI("[MAX_BRIDGE] Зафиксирован реальный рекламный блок: %s", unit.c_str());
    }
}

bool MaxBridge::has_unit() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !known_units_.empty();
}

void MaxBridge::forward(const std::string &json) {
    const MethodInfo *method = nullptr;
    il2cpp_string_new_t new_string = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        method = forward_event_;
        new_string = string_new_;
    }
    if (!method || !new_string) return;

    Il2CppString *managed = new_string(json.c_str());
    if (!managed) return;

    // ForwardEvent — статический метод с одним параметром: в сгенерированном
    // коде IL2CPP это void(Il2CppString*, const MethodInfo*).
    using ForwardFn = void (*)(Il2CppString *, const MethodInfo *);
    auto fn = reinterpret_cast<ForwardFn>(method->methodPointer);
    fn(managed, method);
}

void MaxBridge::emit_loaded(const std::string &unit, bool rewarded) {
    if (unit.empty()) return;
    forward(base_event(rewarded ? "OnRewardedAdLoadedEvent" : "OnInterstitialLoadedEvent", unit));
    LOGI("[MAX_BRIDGE] Отправлено подтверждение загрузки (%s) для %s",
         rewarded ? "rewarded" : "interstitial", unit.c_str());
}

void MaxBridge::emit_reward_sequence(const std::string &unit) {
    if (unit.empty()) return;

    // Порядок в точности повторяет реальный показ рекламы в плагине MAX:
    // показан -> награда начислена -> закрыт. Игра обрабатывает эти события
    // своими штатными обработчиками, поэтому её внутреннее состояние остаётся
    // согласованным.
    forward(base_event("OnRewardedAdDisplayedEvent", unit));
    forward(reward_event(unit));
    forward(base_event("OnRewardedAdHiddenEvent", unit));

    // Немедленная перезарядка: следующий показ доступен сразу.
    forward(base_event("OnRewardedAdLoadedEvent", unit));

    LOGI("[MAX_BRIDGE] Выдана награда и выполнена перезарядка для %s", unit.c_str());
}

void MaxBridge::refresh_all_loaded() {
    std::vector<std::string> units;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        units = known_units_;
    }
    for (const auto &unit : units) {
        forward(base_event("OnRewardedAdLoadedEvent", unit));
        forward(base_event("OnInterstitialLoadedEvent", unit));
    }
}

} // namespace smartreward
