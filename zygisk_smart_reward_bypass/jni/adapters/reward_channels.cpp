#include "reward_channels.hpp"
#include "max_bridge.hpp"
#include "../core/log.hpp"
#include "../core/strings.hpp"
#include "../runtimes/il2cpp/il2cpp_catalog.hpp"
#include "../runtimes/il2cpp/managed_invoker.hpp"

namespace smartreward {

namespace {

// Значения по умолчанию для синтезированной награды. Игры почти всегда
// начисляют собственную, заранее сконфигурированную награду и используют эти
// поля лишь как метку, поэтому величина намеренно скромная.
constexpr int32_t kRewardAmountInt = 1;
constexpr double  kRewardAmountDouble = 1.0;
const char *const kRewardType = "coins";

const MethodInfo *find_ctor(const std::string &namespace_pat,
                            const std::string &class_pat,
                            int argc) {
    auto matches = MetadataIndex::instance().query_wildcard("*", namespace_pat, class_pat, ".ctor", argc);
    return matches.empty() ? nullptr : matches[0]->method_ptr;
}

} // namespace

RewardChannels &RewardChannels::instance() {
    static RewardChannels s_instance;
    return s_instance;
}

void RewardChannels::bind() {
    if (bound_) return;
    ManagedInvoker &mi = ManagedInvoker::instance();
    if (!mi.ready()) return;

    // --- Google Mobile Ads: GoogleMobileAds.Api.Reward { string Type; double Amount; }
    google_reward_ctor_ = find_ctor("GoogleMobileAds.Api", "Reward", 0);
    if (google_reward_ctor_) {
        google_reward_class_ = google_reward_ctor_->klass;
        LOGI("[CHANNELS] Найден класс награды Google Mobile Ads");
    }

    // --- Yandex: YandexMobileAds.Base.Reward(int amount, string type)
    yandex_reward_ctor_ = find_ctor("YandexMobileAds.Base", "Reward", 2);
    if (yandex_reward_ctor_) {
        yandex_reward_class_ = yandex_reward_ctor_->klass;
        LOGI("[CHANNELS] Найден класс награды Yandex Mobile Ads");
    }

    // --- Unity Ads: значение перечисления UnityAdsShowCompletionState.COMPLETED
    //     читается из метаданных игры, а не зашивается числом.
    auto listeners = MetadataIndex::instance().query_wildcard(
        "*", "*", "*", "OnUnityAdsShowComplete", 2);
    for (const auto *desc : listeners) {
        if (!desc || !desc->method_ptr) continue;
        const MethodInfo *m = desc->method_ptr;
        // Второй параметр — перечисление состояния завершения показа.
        const Il2CppType *param_type = mi.param_type(m, 1);
        if (!param_type) continue;
        Il2CppClass *enum_class = mi.class_from_type(param_type);
        if (!enum_class) continue;
        int32_t value = 0;
        if (mi.read_enum_constant(enum_class, "COMPLETED", &value)) {
            unity_ads_completed_ = value;
            LOGI("[CHANNELS] Unity Ads: COMPLETED = %d (прочитано из метаданных игры)", value);
            break;
        }
    }

    bound_ = true;
}

void *RewardChannels::make_google_reward() {
    ManagedInvoker &mi = ManagedInvoker::instance();
    if (!google_reward_class_ || !google_reward_ctor_) return nullptr;

    Il2CppObject *reward = mi.new_object(google_reward_class_);
    if (!reward) return nullptr;
    mi.invoke(google_reward_ctor_, reward, nullptr);

    Il2CppString *type = mi.make_string(kRewardType);
    if (type) mi.write_field(reward, "Type", &type);
    double amount = kRewardAmountDouble;
    mi.write_field(reward, "Amount", &amount);
    return reward;
}

void *RewardChannels::make_yandex_reward() {
    ManagedInvoker &mi = ManagedInvoker::instance();
    if (!yandex_reward_class_ || !yandex_reward_ctor_) return nullptr;

    Il2CppObject *reward = mi.new_object(yandex_reward_class_);
    if (!reward) return nullptr;

    // Поля amount/type объявлены readonly, поэтому значение задаётся строго
    // через конструктор Reward(int amount, string type).
    int32_t amount = kRewardAmountInt;
    Il2CppString *type = mi.make_string(kRewardType);
    void *params[2] = {&amount, type};
    if (!mi.invoke(yandex_reward_ctor_, reward, params)) return nullptr;
    return reward;
}

bool RewardChannels::deliver_yandex(const ShowContext &ctx) {
    ManagedInvoker &mi = ManagedInvoker::instance();
    void *self = ctx.arg(0);
    if (!self) return false;

    void *reward = make_yandex_reward();
    if (!reward) {
        LOGW("[CHANNELS] Yandex: не удалось создать объект награды");
        return false;
    }

    // Reward наследуется от System.EventArgs, поэтому один и тот же объект
    // подходит и для событий вида EventHandler<EventArgs>.
    void *shown = mi.read_object_field(self, "OnAdShown");
    void *rewarded = mi.read_object_field(self, "OnRewarded");
    void *dismissed = mi.read_object_field(self, "OnAdDismissed");

    void *params[2] = {self, reward};
    bool delivered = false;

    if (shown) mi.invoke_delegate(shown, params, 2);
    if (rewarded) {
        delivered = mi.invoke_delegate(rewarded, params, 2);
    }
    if (dismissed) mi.invoke_delegate(dismissed, params, 2);

    if (delivered) {
        LOGI("[CHANNELS] Yandex: награда выдана через событие RewardedAd.OnRewarded");
    } else {
        LOGW("[CHANNELS] Yandex: подписчик OnRewarded не найден");
    }
    return delivered;
}

bool RewardChannels::deliver_google(const ShowContext &ctx) {
    ManagedInvoker &mi = ManagedInvoker::instance();

    // GoogleMobileAds.Api.RewardedAd.Show(Action<Reward> userRewardEarnedCallback)
    // Коллбэк приходит аргументом, поэтому его достаточно вызвать напрямую.
    void *callback = nullptr;
    for (size_t i = 1; i < ctx.argc; ++i) {
        Il2CppClass *klass = mi.class_of(ctx.args[i]);
        if (!klass) continue;
        if (mi.find_method(klass, "Invoke", 1) != nullptr) {
            callback = ctx.args[i];
            break;
        }
    }
    if (!callback) return false;

    void *reward = make_google_reward();
    if (!reward) {
        LOGW("[CHANNELS] Google Mobile Ads: не удалось создать объект награды");
        return false;
    }

    void *self = ctx.arg(0);

    // Полный цикл показа: игра часто закрывает свой интерфейс именно по
    // событию OnAdFullScreenContentClosed, поэтому оно тоже поднимается.
    void *opened = self ? mi.read_object_field(self, "OnAdFullScreenContentOpened") : nullptr;
    if (opened) mi.invoke_delegate(opened, nullptr, 0);

    void *params[1] = {reward};
    const bool ok = mi.invoke_delegate(callback, params, 1);

    void *closed = self ? mi.read_object_field(self, "OnAdFullScreenContentClosed") : nullptr;
    if (closed) mi.invoke_delegate(closed, nullptr, 0);

    if (ok) {
        LOGI("[CHANNELS] Google Mobile Ads: награда выдана через Action<Reward>");
    }
    return ok;
}

bool RewardChannels::deliver_unity_ads(const ShowContext &ctx) {
    ManagedInvoker &mi = ManagedInvoker::instance();
    if (unity_ads_completed_ < 0) return false;

    // UnityEngine.Advertisements.Advertisement.Show(string placementId,
    //                                               IUnityAdsShowListener listener)
    for (size_t i = 0; i < ctx.argc; ++i) {
        Il2CppClass *klass = mi.class_of(ctx.args[i]);
        if (!klass) continue;
        const MethodInfo *complete = mi.find_method(klass, "OnUnityAdsShowComplete", 2);
        if (!complete) continue;

        Il2CppString *placement = mi.make_string(ctx.unit);
        int32_t state = unity_ads_completed_;
        void *params[2] = {placement, &state};
        if (mi.invoke(complete, ctx.args[i], params)) {
            LOGI("[CHANNELS] Unity Ads: показ завершён с состоянием COMPLETED (%d)", state);
            return true;
        }
    }
    return false;
}

bool RewardChannels::deliver_argument_delegates(const ShowContext &ctx) {
    ManagedInvoker &mi = ManagedInvoker::instance();
    bool delivered = false;

    // Универсальный запасной путь: игровые обёртки часто принимают коллбэк
    // завершения как Action или Action<bool>. Такой делегат безопасно вызвать,
    // потому что все его аргументы — простые значимые типы.
    for (size_t i = 0; i < ctx.argc; ++i) {
        Il2CppClass *klass = mi.class_of(ctx.args[i]);
        if (!klass) continue;

        if (mi.find_method(klass, "Invoke", 0) != nullptr) {
            if (mi.invoke_delegate(ctx.args[i], nullptr, 0)) delivered = true;
            continue;
        }
        const MethodInfo *invoke1 = mi.find_method(klass, "Invoke", 1);
        if (invoke1) {
            int32_t success = 1;
            void *params[1] = {&success};
            if (mi.invoke_delegate(ctx.args[i], params, 1)) delivered = true;
        }
    }
    if (delivered) {
        LOGI("[CHANNELS] Награда выдана через делегат завершения в аргументах вызова");
    }
    return delivered;
}

bool RewardChannels::deliver(const ShowContext &ctx) {
    bind();

    // AppLovin MAX: собственная статическая шина событий.
    if (ctx.sdk == "AppLovin.MAX" && MaxBridge::instance().ready()) {
        MaxBridge::instance().remember_unit(ctx.unit);
        if (ctx.is_load) {
            const bool rewarded = to_lower(ctx.method_name).find("reward") != std::string::npos;
            MaxBridge::instance().emit_loaded(ctx.unit, rewarded);
        } else {
            MaxBridge::instance().emit_reward_sequence(ctx.unit);
        }
        return true;
    }

    if (ctx.is_load) {
        // Для остальных сетей подтверждение загрузки отдельного канала не
        // требует: готовность обеспечивается перехватом проверок готовности.
        return false;
    }

    const std::string lclass = to_lower(ctx.class_name);

    if (ctx.sdk == "YandexMobileAds" || lclass.find("yandex") != std::string::npos) {
        if (deliver_yandex(ctx)) return true;
    }
    if (ctx.sdk == "GoogleMobileAds" || lclass.find("googlemobileads") != std::string::npos) {
        if (deliver_google(ctx)) return true;
    }
    if (ctx.sdk == "UnityAds" || lclass.find("advertisement") != std::string::npos) {
        if (deliver_unity_ads(ctx)) return true;
    }

    return deliver_argument_delegates(ctx);
}

} // namespace smartreward
