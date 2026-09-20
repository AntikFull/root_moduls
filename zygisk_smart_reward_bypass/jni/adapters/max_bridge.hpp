#pragma once

#include "../runtimes/il2cpp/il2cpp_symbols.hpp"

#include <mutex>
#include <string>
#include <vector>

namespace smartreward {

// ---------------------------------------------------------------------------
// Нативный мост к AppLovin MAX (Unity).
//
// Плагин MAX доставляет события в C# НЕ через UnitySendMessage, а через
// AndroidJavaProxy (MaxUnityAdManager$BackgroundCallback -> MaxSdkAndroid ->
// MaxSdkBase.HandleBackgroundCallback -> MaxSdkCallbacks.ForwardEvent).
// Поэтому единственная надёжная точка подачи событий из нативного кода —
// прямой вызов C#-метода MaxSdkCallbacks::ForwardEvent(string).
//
// Формат события взят из штатной заглушки плагина MaxSdkUnityEditor.cs:
//   {"name":"<Событие>","adUnitId":"<id>","placement":""}
// Поля reward-события дополняются rewardLabel/rewardAmount.
// ---------------------------------------------------------------------------
class MaxBridge {
public:
    static MaxBridge &instance();

    // Привязка к C#-точке входа. Вызывается после построения индекса метаданных.
    void bind(const MethodInfo *forward_event, il2cpp_string_new_t string_new);
    bool ready() const;

    // Запоминает реальный идентификатор рекламного блока, который игра
    // передала в Load/Show. Без него события уходят «в никуда»: игра слушает
    // строго свой adUnitId.
    void remember_unit(const std::string &unit);
    bool has_unit() const;

    // Подтверждение загрузки: игра считает рекламу готовой к показу.
    void emit_loaded(const std::string &unit, bool rewarded);

    // Полный цикл показа с начислением награды.
    void emit_reward_sequence(const std::string &unit);

    // Подтверждение загрузки для всех ранее замеченных блоков.
    void refresh_all_loaded();

private:
    MaxBridge() = default;
    void forward(const std::string &json);

    mutable std::mutex mutex_;
    const MethodInfo *forward_event_ = nullptr;
    il2cpp_string_new_t string_new_ = nullptr;
    std::vector<std::string> known_units_;
};

} // namespace smartreward
