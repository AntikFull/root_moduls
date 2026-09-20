#pragma once

#include "../runtimes/il2cpp/il2cpp_symbols.hpp"

#include <cstdint>
#include <string>

namespace smartreward {

// Контекст перехваченного вызова показа или загрузки рекламы.
struct ShowContext {
    std::string sdk;          // определённая сеть, например "AppLovin.MAX"
    std::string class_name;   // класс перехваченного метода
    std::string method_name;  // имя перехваченного метода
    std::string unit;         // идентификатор рекламного блока / площадки
    bool        is_load = false;

    // Аргументы вызова БЕЗ скрытого MethodInfo. Для методов экземпляра
    // args[0] — это this.
    void  *args[6] = {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr};
    size_t argc = 0;

    void *arg(size_t i) const { return i < argc ? args[i] : nullptr; }
};

// ---------------------------------------------------------------------------
// Доставка награды в игру.
//
// Единого способа не существует: каждая рекламная сеть уведомляет игру
// по-своему. Поддерживаются три семейства:
//
//   1. Статическая шина сообщений — AppLovin MAX (прямой вызов C#-метода
//      MaxSdkCallbacks.ForwardEvent), IronSource (UnitySendMessage).
//   2. События на объекте — Yandex (RewardedAd.OnRewarded).
//   3. Слушатель или делегат в аргументах вызова — Unity Ads
//      (IUnityAdsShowListener), Google Mobile Ads (Action<Reward>).
//
// Числовые константы SDK (значения перечислений) не зашиваются в модуль,
// а читаются из метаданных той версии сборки, которая загружена в процесс.
// ---------------------------------------------------------------------------
class RewardChannels {
public:
    static RewardChannels &instance();

    // Однократный поиск классов наград и констант. Безопасно вызывать повторно.
    void bind();

    // Возвращает true, если награда доставлена профильным каналом сети.
    bool deliver(const ShowContext &ctx);

private:
    RewardChannels() = default;

    bool deliver_yandex(const ShowContext &ctx);
    bool deliver_google(const ShowContext &ctx);
    bool deliver_unity_ads(const ShowContext &ctx);
    bool deliver_argument_delegates(const ShowContext &ctx);

    void *make_google_reward();
    void *make_yandex_reward();

    bool bound_ = false;

    Il2CppClass      *google_reward_class_ = nullptr;
    const MethodInfo *google_reward_ctor_ = nullptr;

    Il2CppClass      *yandex_reward_class_ = nullptr;
    const MethodInfo *yandex_reward_ctor_ = nullptr;

    int32_t unity_ads_completed_ = -1;
};

} // namespace smartreward
