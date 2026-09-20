#include "il2cpp_api.hpp"
#include "inline_hook.hpp"
#include "../runtimes/il2cpp/managed_invoker.hpp"
#include "engine_probe.hpp"
#include "log.hpp"
#include "strings.hpp"
#include "../adapters/applovin_adapter.hpp"
#include "../adapters/admob_adapter.hpp"
#include "../adapters/unity_ads_adapter.hpp"
#include "../adapters/ironsource_adapter.hpp"
#include "../adapters/yandex_adapter.hpp"
#include "../discovery/auto_rule_engine.hpp"

#include <dlfcn.h>
#include <unistd.h>
#include <vector>
#include <unordered_map>
#include <jni.h>
#include <cstring>
#include <algorithm>

#include "reward_trace.hpp"
#include <atomic>
#include <cstdint>
#include <mutex>

namespace smartreward {

// Разделяемое состояние захвата рекламного блока.
// ВНЕШНЯЯ линковка обязательна: applovin_adapter.cpp обращается к этим объектам
// через extern-объявления. Если поместить их в анонимное пространство имён,
// символы не экспортируются, и динамический загрузчик отвергает всю библиотеку
// целиком с ошибкой "cannot locate symbol" — модуль не стартует вообще.
std::mutex g_state_mutex;
std::string g_captured_ad_unit_id;

namespace {

const MethodInfo *g_rogue_purchase_in_game = nullptr;
std::atomic<uint64_t> g_rogue_purchase_redirect_calls{0};

extern "C" Il2CppObject *hook_rogue_purchase_with_rewarded_video(
        void *self, void *purchase_info, const MethodInfo *) {
    g_rogue_purchase_redirect_calls.fetch_add(1, std::memory_order_relaxed);

    void *params[1] = {purchase_info};
    bool success = false;
    Il2CppObject *task = ManagedInvoker::instance().invoke_object(
        g_rogue_purchase_in_game, self, params, &success);
    if (!success || !task) {
        LOGE("[ROGUE_PURCHASE] Не удалось перенаправить RV-покупку в штатную серверную логику");
        return nullptr;
    }

    LOGI("[ROGUE_PURCHASE] RV-покупка перенаправлена в PurchaseWithInGameLogic (calls=%llu)",
         static_cast<unsigned long long>(
             g_rogue_purchase_redirect_calls.load(std::memory_order_relaxed)));
    return task;
}

bool install_rogue_purchase_redirect(const std::string &package_name) {
    if (package_name != "com.pockethaven.roguelegend") return false;

    const auto sources = MetadataIndex::instance().find_methods(
        "Assembly-CSharp.dll", "MainMenu.Purchasing", "PurchasingManager",
        "PurchaseWithRewardedVideo", 1);
    const auto targets = MetadataIndex::instance().find_methods(
        "Assembly-CSharp.dll", "MainMenu.Purchasing", "PurchasingManager",
        "PurchaseWithInGameLogic", 1);

    const MethodDescriptor *source = sources.empty() ? nullptr : sources.front();
    const MethodDescriptor *target = targets.empty() ? nullptr : targets.front();
    if (!source || !target || !source->method_ptr || !target->method_ptr) {
        LOGW("[ROGUE_PURCHASE] Перенаправление не установлено: целевые методы не найдены");
        return false;
    }
    if (source->is_static || target->is_static ||
        source->param_types != target->param_types ||
        source->return_type != target->return_type) {
        LOGW("[ROGUE_PURCHASE] Перенаправление не установлено: сигнатуры методов различаются");
        return false;
    }

    g_rogue_purchase_in_game = target->method_ptr;
    const DetourStatus status = install_detour(
        reinterpret_cast<void *>(source->method_ptr->methodPointer),
        reinterpret_cast<void *>(&hook_rogue_purchase_with_rewarded_video));
    if (status != DetourStatus::Ok && status != DetourStatus::AlreadyHooked) {
        g_rogue_purchase_in_game = nullptr;
        LOGW("[ROGUE_PURCHASE] Перенаправление не установлено: %s", to_string(status));
        return false;
    }

    LOGI("[ROGUE_PURCHASE] PurchaseWithRewardedVideo -> PurchaseWithInGameLogic установлен");
    return true;
}

} // namespace

namespace {

static size_t g_last_assembly_count = 0;

// Выдержка с момента появления домена IL2CPP до первого обращения к рантайму.
static constexpr uint64_t kRuntimeSettleMs = 5000;
// Время, в течение которого число загруженных сборок должно оставаться неизменным.
static constexpr uint64_t kAssemblyStableMs = 2000;

class Il2CppThreadScope {
public:
    Il2CppThreadScope(il2cpp_thread_attach_t attach_fn, il2cpp_thread_detach_t detach_fn, Il2CppDomain *domain)
        : detach_fn_(detach_fn), thread_(nullptr) {
        if (attach_fn && domain) {
            thread_ = attach_fn(domain);
        }
    }
    ~Il2CppThreadScope() {
        if (detach_fn_ && thread_) {
            detach_fn_(thread_);
        }
    }
private:
    il2cpp_thread_detach_t detach_fn_ = nullptr;
    Il2CppThread *thread_ = nullptr;
};

// Чистые ассемблерные naked/leaf-стабы (ABI-safe for Boolean leaf replacement)
#if defined(__aarch64__)
extern "C" __attribute__((naked)) uint64_t stub_return_true() {
    __asm__ volatile(
        "mov w0, #1\n"
        "ret\n"
    );
}
extern "C" __attribute__((naked)) uint64_t stub_return_two() {
    __asm__ volatile(
        "mov w0, #2\n"
        "ret\n"
    );
}
extern "C" __attribute__((naked)) void stub_void_return() {
    __asm__ volatile(
        "ret\n"
    );
}
#elif defined(__arm__)
extern "C" __attribute__((naked)) uint32_t stub_return_true() {
    __asm__ volatile(
        "movs r0, #1\n"
        "bx lr\n"
    );
}
extern "C" __attribute__((naked)) uint32_t stub_return_two() {
    __asm__ volatile(
        "movs r0, #2\n"
        "bx lr\n"
    );
}
extern "C" __attribute__((naked)) void stub_void_return() {
    __asm__ volatile(
        "bx lr\n"
    );
}
#elif defined(__x86_64__)
extern "C" __attribute__((naked)) uint64_t stub_return_true() {
    __asm__ volatile(
        "movl $1, %eax\n"
        "ret\n"
    );
}
extern "C" __attribute__((naked)) uint64_t stub_return_two() {
    __asm__ volatile(
        "movl $2, %eax\n"
        "ret\n"
    );
}
extern "C" __attribute__((naked)) void stub_void_return() {
    __asm__ volatile(
        "ret\n"
    );
}
#elif defined(__i386__)
extern "C" __attribute__((naked)) uint32_t stub_return_true() {
    __asm__ volatile(
        "movl $1, %eax\n"
        "ret\n"
    );
}
extern "C" __attribute__((naked)) uint32_t stub_return_two() {
    __asm__ volatile(
        "movl $2, %eax\n"
        "ret\n"
    );
}
extern "C" __attribute__((naked)) void stub_void_return() {
    __asm__ volatile(
        "ret\n"
    );
}
#else
static uint64_t stub_return_true() { return 1; }
static uint64_t stub_return_two() { return 2; }
static void stub_void_return() {}
#endif

// Метод показа и метод загрузки перехватываются одним и тем же трамплином,
// но означают разное: показ выдаёт награду, загрузка лишь подтверждает
// готовность рекламы. Вид определяется по имени метода при установке хука.
enum class ShowHookKind { Show, Load };

struct ShowHookDescriptor {
    const MethodInfo *method = nullptr;
    ShowHookKind kind = ShowHookKind::Show;
    std::string sdk_name;
    std::string class_name;
    std::string method_name;
    int cpp_args = 0;
    bool is_static = false;
    ISdkAdapter *target_adapter = nullptr;
};

static std::vector<ShowHookDescriptor> g_registered_show_hooks;

// ---------------------------------------------------------------------------
// Телеметрия фактических вызовов перехватов.
//
// Установка перехвата и его срабатывание — разные события. Счётчики ниже
// инкрементируются непосредственно в теле трамплина (единственная операция на
// горячем пути) и дают достоверный ответ на вопрос «перехват реально
// выполнился?» вместо предположения «патч записан, значит работает».
// ---------------------------------------------------------------------------

static constexpr size_t MAX_READY_HOOKS = 128;

struct HookCallStat {
    std::atomic<uint64_t> calls{0};
};

static HookCallStat g_ready_stats[MAX_READY_HOOKS];
static HookCallStat g_show_stats[Il2CppResolver::MAX_SHOW_HOOKS];
static std::vector<std::string> g_registered_ready_hooks;

template <size_t Index>
struct ReadyTrampoline {
    // Полная замена метода проверки готовности рекламы. Аргументы не читаются,
    // поэтому соглашение о вызове сохраняется при любой сигнатуре метода.
    static uint64_t ret_true() {
        g_ready_stats[Index].calls.fetch_add(1, std::memory_order_relaxed);
        return 1;
    }
};

// Безопасное извлечение UTF-8 строки
static std::string extract_il2cpp_string_safe(void *ptr) {
    if (!ptr) return "";
    if (!Il2CppResolver::instance().is_string_object(ptr)) return "";
    return Il2CppTypeTraits::extract_utf8_string(
        ptr,
        Il2CppResolver::instance().string_chars_api(),
        Il2CppResolver::instance().string_length_api());
}

template <size_t Index>
struct ShowTrampoline {
    // IL2CPP добавляет скрытый последний аргумент `const MethodInfo*` в каждую
    // сгенерированную функцию. Он НЕ является аргументом C#-метода, и попытка
    // разобрать его как строку или делегат приводит к чтению кода как данных
    // и к SIGSEGV. Поэтому последний аргумент исключён из анализа.
    static void handle(size_t argc, void *const *args) {
        g_show_stats[Index].calls.fetch_add(1, std::memory_order_relaxed);

        std::string unit;
        for (size_t i = 0; i < argc; ++i) {
            if (!args[i]) continue;
            unit = extract_il2cpp_string_safe(args[i]);
            if (!unit.empty()) break;
        }
        if (unit.empty()) unit = "default_rewarded";

        Il2CppResolver::instance().dispatch_hook_index(Index, unit, args, argc);
    }

    // Возвращаемое значение 1 трактуется игрой как «показ начат» / «объект не null».
    // Методы с плавающей точкой и структурными возвратами отсеиваются до установки хука.
    static void *show_0_arg(void *) {
        handle(0, nullptr);
        return reinterpret_cast<void *>(1);
    }
    static void *show_1_arg(void *p0, void *) {
        void *args[] = {p0};
        handle(1, args);
        return reinterpret_cast<void *>(1);
    }
    static void *show_2_arg(void *p0, void *p1, void *) {
        void *args[] = {p0, p1};
        handle(2, args);
        return reinterpret_cast<void *>(1);
    }
    static void *show_3_arg(void *p0, void *p1, void *p2, void *) {
        void *args[] = {p0, p1, p2};
        handle(3, args);
        return reinterpret_cast<void *>(1);
    }
    static void *show_4_arg(void *p0, void *p1, void *p2, void *p3, void *) {
        void *args[] = {p0, p1, p2, p3};
        handle(4, args);
        return reinterpret_cast<void *>(1);
    }
    static void *show_5_arg(void *p0, void *p1, void *p2, void *p3, void *p4, void *) {
        void *args[] = {p0, p1, p2, p3, p4};
        handle(5, args);
        return reinterpret_cast<void *>(1);
    }
};

#define TRAMP_0(N) reinterpret_cast<Il2CppMethodPointer>(&ShowTrampoline<N>::show_0_arg)
#define TRAMP_1(N) reinterpret_cast<Il2CppMethodPointer>(&ShowTrampoline<N>::show_1_arg)
#define TRAMP_2(N) reinterpret_cast<Il2CppMethodPointer>(&ShowTrampoline<N>::show_2_arg)
#define TRAMP_3(N) reinterpret_cast<Il2CppMethodPointer>(&ShowTrampoline<N>::show_3_arg)
#define TRAMP_4(N) reinterpret_cast<Il2CppMethodPointer>(&ShowTrampoline<N>::show_4_arg)
#define TRAMP_5(N) reinterpret_cast<Il2CppMethodPointer>(&ShowTrampoline<N>::show_5_arg)

#define EXPAND_32_TABLE(M) \
    M(0), M(1), M(2), M(3), M(4), M(5), M(6), M(7), \
    M(8), M(9), M(10), M(11), M(12), M(13), M(14), M(15), \
    M(16), M(17), M(18), M(19), M(20), M(21), M(22), M(23), \
    M(24), M(25), M(26), M(27), M(28), M(29), M(30), M(31)

static const Il2CppMethodPointer s_trampolines_0[32] = { EXPAND_32_TABLE(TRAMP_0) };
static const Il2CppMethodPointer s_trampolines_1[32] = { EXPAND_32_TABLE(TRAMP_1) };
static const Il2CppMethodPointer s_trampolines_2[32] = { EXPAND_32_TABLE(TRAMP_2) };
static const Il2CppMethodPointer s_trampolines_3[32] = { EXPAND_32_TABLE(TRAMP_3) };
static const Il2CppMethodPointer s_trampolines_4[32] = { EXPAND_32_TABLE(TRAMP_4) };
static const Il2CppMethodPointer s_trampolines_5[32] = { EXPAND_32_TABLE(TRAMP_5) };

#define READY_TRAMP(N) reinterpret_cast<Il2CppMethodPointer>(&ReadyTrampoline<N>::ret_true)

#define EXPAND_32_OFFSET(M, B)     M(B + 0), M(B + 1), M(B + 2), M(B + 3), M(B + 4), M(B + 5), M(B + 6), M(B + 7),     M(B + 8), M(B + 9), M(B + 10), M(B + 11), M(B + 12), M(B + 13), M(B + 14), M(B + 15),     M(B + 16), M(B + 17), M(B + 18), M(B + 19), M(B + 20), M(B + 21), M(B + 22), M(B + 23),     M(B + 24), M(B + 25), M(B + 26), M(B + 27), M(B + 28), M(B + 29), M(B + 30), M(B + 31)

static const Il2CppMethodPointer s_ready_trampolines[MAX_READY_HOOKS] = {
    EXPAND_32_OFFSET(READY_TRAMP, 0),
    EXPAND_32_OFFSET(READY_TRAMP, 32),
    EXPAND_32_OFFSET(READY_TRAMP, 64),
    EXPAND_32_OFFSET(READY_TRAMP, 96)
};

// Проверка наличия активной Hosts-блокировки для конкретного SDK
bool is_sdk_hosts_blocked(const std::string &sdk_name) {
    const char *paths[] = {
        "/system/etc/hosts",
        "/data/adb/hosts",
        "/etc/hosts"
    };
    std::string s = sdk_name;
    std::transform(s.begin(), s.end(), s.begin(), ::tolower);

    std::vector<std::string> patterns;
    if (s.find("applovin") != std::string::npos || s.find("max") != std::string::npos) {
        patterns = {"applovin.com", "applvn.com"};
    } else if (s.find("admob") != std::string::npos || s.find("google") != std::string::npos) {
        patterns = {"googleads.g.doubleclick.net", "pagead2.googlesyndication.com", "admob.com"};
    } else if (s.find("unity") != std::string::npos) {
        patterns = {"unityads.unity3d.com", "auction.unityads.unity3d.com"};
    } else if (s.find("ironsource") != std::string::npos) {
        patterns = {"ironsrc.mobi", "ironsource.com"};
    } else if (s.find("yandex") != std::string::npos) {
        patterns = {"ads.yandex.ru", "mobile.yandex.net", "yandex.net", "an.yandex.ru"};
    } else {
        patterns = {"applovin.com", "googleads", "admob", "unityads", "ironsource", "yandex"};
    }

    for (const char *path : paths) {
        FILE *f = fopen(path, "r");
        if (!f) continue;
        char line[2048];
        while (fgets(line, sizeof(line), f)) {
            char *p = line;
            while (*p == ' ' || *p == '\t') p++;
            if (*p == '#' || *p == '\n' || *p == '\r' || *p == '\0') continue;

            bool is_loopback = (strncmp(p, "0.0.0.0", 7) == 0 && (p[7] == ' ' || p[7] == '\t')) ||
                               (strncmp(p, "127.0.0.1", 9) == 0 && (p[9] == ' ' || p[9] == '\t'));
            if (is_loopback) {
                for (const auto &pat : patterns) {
                    if (strstr(p, pat.c_str())) {
                        fclose(f);
                        LOGI("[HOSTS_PROBE] [NATIVE] Detected hosts block for SDK '%s' (pattern: %s in %s)",
                             sdk_name.c_str(), pat.c_str(), path);
                        return true;
                    }
                }
            }
        }
        fclose(f);
    }
    return false;
}

bool is_ad_hosts_blocked() {
    return is_sdk_hosts_blocked("all");
}

} // namespace

static Il2CppMethodPointer s_orig_forward_event = nullptr;

// Обработка и фильтрация событий AppLovin MAX ForwardEvent
// Возвращает true, если событие ошибки было перехвачено и подавлено
static bool process_max_forward_event_payload(const std::string &s) {
    if (s.empty()) return false;
    LOGI("[MAX_FORWARD_EVENT] Intercepted event JSON (%zu bytes): %s", s.size(), s.c_str());

    // Универсальный динамический поиск любого ID рекламного блока в JSON
    std::string adUnitId;
    const char *patterns[] = {
        "\"adUnitId\":\"", "\"adUnitIdentifier\":\"", "\"ad_unit_id\":\"",
        "\"placement_id\":\"", "\"placementId\":\"", "\"adUnit\":\"", "\"unit_id\":\""
    };
    for (const char *pat : patterns) {
        auto pos = s.find(pat);
        if (pos != std::string::npos) {
            size_t start = pos + strlen(pat);
            auto end = s.find("\"", start);
            if (end != std::string::npos && end > start) {
                adUnitId = s.substr(start, end - start);
                break;
            }
        }
    }

    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        if (!adUnitId.empty()) {
            g_captured_ad_unit_id = adUnitId;
        } else {
            adUnitId = g_captured_ad_unit_id.empty() ? "default_rewarded" : g_captured_ad_unit_id;
        }
    }

    // 1. При сбое показа (FailedToDisplay / DisplayFailed) -> подавляем ошибку и выдаем полную цепочку наград
    if (s.find("OnRewardedAdFailedToDisplayEvent") != std::string::npos ||
        s.find("OnRewardedAdDisplayFailedEvent") != std::string::npos ||
        s.find("FailedToDisplay") != std::string::npos ||
        s.find("DisplayFailed") != std::string::npos) {

        LOGI("[MAX_FORWARD_EVENT] DisplayFailed detected -> Synthesizing full reward chain (adUnitId=%s)!", adUnitId.c_str());

        std::string reward_json = "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + adUnitId + "\",\"rewardLabel\":\"coins\",\"rewardAmount\":1,\"reward\":{\"label\":\"coins\",\"amount\":1},\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";
        std::string hidden_json = "{\"name\":\"OnRewardedAdHiddenEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";
        std::string loaded_json = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";

        Il2CppResolver::instance().notify_unity_reward("MaxSdkCallbacks", "ForwardEvent", reward_json.c_str());
        Il2CppResolver::instance().notify_unity_reward("MaxSdkCallbacks", "ForwardEvent", hidden_json.c_str());
        Il2CppResolver::instance().notify_unity_reward("MaxSdkCallbacks", "ForwardEvent", loaded_json.c_str());
        return true; // Подавляем сбой в оригинальном C# методе
    }

    // 2. Если пришла ошибка сети / загрузки -> динамически подменяем на OnRewardedAdLoadedEvent и подавляем ошибку
    if (s.find("OnRewardedAdLoadFailedEvent") != std::string::npos ||
        s.find("OnInterstitialLoadFailedEvent") != std::string::npos ||
        s.find("OnAdLoadFailedEvent") != std::string::npos ||
        s.find("LoadFailed") != std::string::npos) {

        LOGI("[MAX_FORWARD_EVENT] LoadFailed detected -> Rewriting to OnRewardedAdLoadedEvent (adUnitId=%s)!", adUnitId.c_str());

        std::string init_json = "{\"name\":\"OnSdkInitializedEvent\",\"hasUserConsent\":true,\"isAgeRestrictedUser\":false,\"isDoNotSell\":false,\"countryCode\":\"US\"}";
        std::string loaded_json = "{\"name\":\"OnRewardedAdLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";
        std::string loaded_inter_json = "{\"name\":\"OnInterstitialLoadedEvent\",\"adUnitId\":\"" + adUnitId + "\",\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"INTERSTITIAL\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";

        Il2CppResolver::instance().notify_unity_reward("MaxSdkCallbacks", "ForwardEvent", init_json.c_str());
        Il2CppResolver::instance().notify_unity_reward("MaxSdkCallbacks", "ForwardEvent", loaded_json.c_str());
        Il2CppResolver::instance().notify_unity_reward("MaxSdkCallbacks", "ForwardEvent", loaded_inter_json.c_str());
        return true; // Подавляем сбой в оригинальном C# методе
    }

    // 3. При закрытии рекламы (HiddenEvent) -> ГАРАНТИРУЕМ отправку RewardEvent ПЕРЕД HiddenEvent!
    if (s.find("OnRewardedAdHiddenEvent") != std::string::npos ||
        s.find("OnRewardedInterstitialAdHiddenEvent") != std::string::npos) {

        LOGI("[MAX_FORWARD_EVENT] HiddenEvent detected -> Injecting OnRewardedAdReceivedRewardEvent first (adUnitId=%s)!", adUnitId.c_str());
        std::string reward_json = "{\"name\":\"OnRewardedAdReceivedRewardEvent\",\"adUnitId\":\"" + adUnitId + "\",\"rewardLabel\":\"coins\",\"rewardAmount\":1,\"reward\":{\"label\":\"coins\",\"amount\":1},\"networkName\":\"AppLovin\",\"adInfo\":{\"adUnitIdentifier\":\"" + adUnitId + "\",\"adFormat\":\"REWARDED\",\"networkName\":\"AppLovin\",\"networkPlacement\":\"\",\"placement\":\"\",\"creativeIdentifier\":\"1039005561\",\"revenue\":0.0787555084228516,\"revenuePrecision\":\"exact\"}}";

        Il2CppResolver::instance().notify_unity_reward("MaxSdkCallbacks", "ForwardEvent", reward_json.c_str());
        return false;
    }

    return false;
}

// Нативный перехватчик для static методов (MaxSdkBase::HandleBackgroundCallback)
void hook_forward_event_static(void *str_obj, const MethodInfo *method) {
    if (str_obj) {
        std::string s = Il2CppTypeTraits::extract_utf8_string(
            str_obj,
            Il2CppResolver::instance().string_chars_api(),
            Il2CppResolver::instance().string_length_api());
        bool handled = process_max_forward_event_payload(s);
        if (handled) {
            return; // Ошибка подменена на успех, подавляем вызов оригинального метода с объектом ошибки
        }
    }
    if (s_orig_forward_event) {
        reinterpret_cast<void(*)(void*, const MethodInfo*)>(s_orig_forward_event)(str_obj, method);
    }
}

// Нативный перехватчик для instance методов (MaxSdkCallbacks::ForwardEvent)
void hook_forward_event_instance(void *self, void *str_obj, const MethodInfo *method) {
    if (str_obj) {
        std::string s = Il2CppTypeTraits::extract_utf8_string(
            str_obj,
            Il2CppResolver::instance().string_chars_api(),
            Il2CppResolver::instance().string_length_api());
        bool handled = process_max_forward_event_payload(s);
        if (handled) {
            return; // Ошибка подменена на успех, подавляем вызов оригинального метода с объектом ошибки
        }
    }
    if (s_orig_forward_event) {
        reinterpret_cast<void(*)(void*, void*, const MethodInfo*)>(s_orig_forward_event)(self, str_obj, method);
    }
}

Il2CppResolver &Il2CppResolver::instance() {
    static Il2CppResolver s_instance;
    return s_instance;
}

Il2CppResolver::Il2CppResolver() {
    register_sdk_adapters();
}

void Il2CppResolver::register_sdk_adapters() {
    sdk_adapters_.push_back(std::make_unique<AppLovinMaxAdapter>());
    sdk_adapters_.push_back(std::make_unique<GoogleAdMobAdapter>());
    sdk_adapters_.push_back(std::make_unique<UnityAdsAdapter>());
    sdk_adapters_.push_back(std::make_unique<IronSourceAdapter>());
    sdk_adapters_.push_back(std::make_unique<YandexAdsAdapter>());
}

bool Il2CppResolver::init() {
    if (il2cpp_handle_ && caps_.is_ready()) return true;

    void *handle = wait_for_loaded_library("libil2cpp.so", 10, 100000);
    if (!handle) {
        LOGI("[ENGINE] libil2cpp.so is not loaded; IL2CPP runtime not active in this process");
        il2cpp_handle_ = nullptr;
        return false;
    }

    domain_get_ = reinterpret_cast<il2cpp_domain_get_t>(dlsym(handle, "il2cpp_domain_get"));
    domain_get_assemblies_ = reinterpret_cast<il2cpp_domain_get_assemblies_t>(dlsym(handle, "il2cpp_domain_get_assemblies"));
    thread_attach_ = reinterpret_cast<il2cpp_thread_attach_t>(dlsym(handle, "il2cpp_thread_attach"));
    thread_detach_ = reinterpret_cast<il2cpp_thread_detach_t>(dlsym(handle, "il2cpp_thread_detach"));
    thread_current_ = reinterpret_cast<il2cpp_thread_current_t>(dlsym(handle, "il2cpp_thread_current"));
    assembly_get_image_ = reinterpret_cast<il2cpp_assembly_get_image_t>(dlsym(handle, "il2cpp_assembly_get_image"));
    image_get_name_ = reinterpret_cast<il2cpp_image_get_name_t>(dlsym(handle, "il2cpp_image_get_name"));
    image_get_class_count_ = reinterpret_cast<il2cpp_image_get_class_count_t>(dlsym(handle, "il2cpp_image_get_class_count"));
    image_get_class_ = reinterpret_cast<il2cpp_image_get_class_t>(dlsym(handle, "il2cpp_image_get_class"));
    class_get_name_ = reinterpret_cast<il2cpp_class_get_name_t>(dlsym(handle, "il2cpp_class_get_name"));
    class_get_namespace_ = reinterpret_cast<il2cpp_class_get_namespace_t>(dlsym(handle, "il2cpp_class_get_namespace"));
    class_from_name_ = reinterpret_cast<il2cpp_class_from_name_t>(dlsym(handle, "il2cpp_class_from_name"));
    class_get_methods_ = reinterpret_cast<il2cpp_class_get_methods_t>(dlsym(handle, "il2cpp_class_get_methods"));
    class_get_method_from_name_ = reinterpret_cast<il2cpp_class_get_method_from_name_t>(dlsym(handle, "il2cpp_class_get_method_from_name"));
    class_get_parent_ = reinterpret_cast<il2cpp_class_get_parent_t>(dlsym(handle, "il2cpp_class_get_parent"));
    class_is_subclass_of_ = reinterpret_cast<il2cpp_class_is_subclass_of_t>(dlsym(handle, "il2cpp_class_is_subclass_of"));

    method_get_name_ = reinterpret_cast<il2cpp_method_get_name_t>(dlsym(handle, "il2cpp_method_get_name"));
    method_get_param_count_ = reinterpret_cast<il2cpp_method_get_param_count_t>(dlsym(handle, "il2cpp_method_get_param_count"));
    method_get_param_ = reinterpret_cast<il2cpp_method_get_param_t>(dlsym(handle, "il2cpp_method_get_param"));
    method_get_return_type_ = reinterpret_cast<il2cpp_method_get_return_type_t>(dlsym(handle, "il2cpp_method_get_return_type"));
    method_get_flags_ = reinterpret_cast<il2cpp_method_get_flags_t>(dlsym(handle, "il2cpp_method_get_flags"));

    type_get_type_ = reinterpret_cast<il2cpp_type_get_type_t>(dlsym(handle, "il2cpp_type_get_type"));
    type_get_name_ = reinterpret_cast<il2cpp_type_get_name_t>(dlsym(handle, "il2cpp_type_get_name"));
    il2cpp_free_ = reinterpret_cast<il2cpp_free_t>(dlsym(handle, "il2cpp_free"));

    string_chars_ = reinterpret_cast<il2cpp_string_chars_t>(dlsym(handle, "il2cpp_string_chars"));
    string_new_ = reinterpret_cast<il2cpp_string_new_t>(dlsym(handle, "il2cpp_string_new"));
    string_length_ = reinterpret_cast<il2cpp_string_length_t>(dlsym(handle, "il2cpp_string_length"));
    object_get_class_ = reinterpret_cast<il2cpp_object_get_class_t>(dlsym(handle, "il2cpp_object_get_class"));

    // Заполнение матрицы возможностей
    caps_.has_domain_get = (domain_get_ != nullptr);
    caps_.has_domain_assemblies = (domain_get_assemblies_ != nullptr);
    caps_.has_assembly_image = (assembly_get_image_ != nullptr);
    caps_.has_class_from_name = (class_from_name_ != nullptr);
    caps_.has_method_from_name = (class_get_method_from_name_ != nullptr);
    caps_.has_class_iter = (image_get_class_count_ != nullptr && image_get_class_ != nullptr);
    caps_.has_method_iter = (class_get_methods_ != nullptr);
    caps_.has_method_flags = (method_get_flags_ != nullptr);
    caps_.has_method_params = (method_get_param_ != nullptr && type_get_name_ != nullptr);
    caps_.has_string_api = (string_chars_ != nullptr && string_length_ != nullptr);
    caps_.has_parent_api = (class_get_parent_ != nullptr);
    caps_.has_free = (il2cpp_free_ != nullptr);

    LOGI("[IL2CPP_CAPS] domain=%d assemblies=%d image=%d class=%d method=%d (flags=%d params=%d string_api=%d parent=%d free=%d)",
         caps_.has_domain_get, caps_.has_domain_assemblies, caps_.has_assembly_image,
         caps_.has_class_from_name, caps_.has_method_from_name,
         caps_.has_method_flags, caps_.has_method_params, caps_.has_string_api, caps_.has_parent_api, caps_.has_free);

    if (!caps_.is_ready()) {
        LOGW("[IL2CPP] required exported API is incomplete; safe method resolution disabled");
        il2cpp_handle_ = nullptr;
        return false;
    }

    il2cpp_handle_ = handle;
    ManagedInvoker::instance().bind(handle);
    ensure_unity_bridge();
    return true;
}

bool Il2CppResolver::is_method_static(const MethodInfo *method) const {
    if (!method) return false;
    if (method_get_flags_) {
        uint32_t iflags = 0;
        uint32_t flags = method_get_flags_(method, &iflags);
        return (flags & 0x0010) != 0;
    }
    return false;
}

int Il2CppResolver::get_method_cpp_args(const MethodInfo *method) const {
    if (!method) return 0;
    int param_count = method_get_param_count_ ? static_cast<int>(method_get_param_count_(method)) : 0;
    bool is_static = is_method_static(method);
    return is_static ? param_count : (param_count + 1);
}

bool Il2CppResolver::is_string_object(void *ptr) const {
    return Il2CppTypeTraits::is_string_object(ptr, class_get_name_, string_length_);
}

bool Il2CppResolver::is_delegate_object(void *ptr) const {
    return Il2CppTypeTraits::is_delegate_object(ptr, class_get_name_, class_get_parent_);
}

bool Il2CppResolver::invoke_direct_delegate(void *candidate_delegate) const {
    if (!candidate_delegate) return false;
    return Il2CppTypeTraits::invoke_delegate_auto(candidate_delegate, class_get_name_,
                                                  method_get_param_count_, method_get_param_,
                                                  type_get_type_);
}

std::string Il2CppResolver::get_package_name() const {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    return package_name_;
}

std::string Il2CppResolver::get_process_name() const {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    return process_name_;
}

void Il2CppResolver::ensure_unity_bridge() {
    std::lock_guard<std::mutex> lock(g_state_mutex);
    if (!unity_send_message_) {
        void *u = dlopen("libunity.so", RTLD_NOW | RTLD_NOLOAD);
        if (u) {
            unity_send_message_ = reinterpret_cast<UnitySendMessage_t>(dlsym(u, "UnitySendMessage"));
            if (unity_send_message_) {
                LOGI("[UNITY_ATTACH] UnitySendMessage bridge successfully attached!");
            }
        }
    }
}

void Il2CppResolver::notify_unity_reward(const char *game_object, const char *method, const char *message) {
    ensure_unity_bridge();
    UnitySendMessage_t sender = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        sender = unity_send_message_;
    }
    if (sender && game_object && method && message) {
        LOGI("[UNITY_EVENT] Sending '%s.%s(%s)'", game_object, method, message);
        sender(game_object, method, message);
    }
}

ISdkAdapter *Il2CppResolver::find_adapter_by_name(const std::string &name) const {
    if (name.empty() || name == "AutoDetect") return nullptr;
    std::string query = name;
    std::transform(query.begin(), query.end(), query.begin(), ::tolower);

    for (const auto &adapter : sdk_adapters_) {
        if (adapter) {
            std::string aname = adapter->get_name();
            std::string lower_aname = aname;
            std::transform(lower_aname.begin(), lower_aname.end(), lower_aname.begin(), ::tolower);
            if (lower_aname.find(query) != std::string::npos || query.find(lower_aname) != std::string::npos) {
                return adapter.get();
            }
        }
    }
    return nullptr;
}

void Il2CppResolver::dispatch_hook_index(size_t index, const std::string &placement,
                                         void *const *args, size_t argc) {
    ShowHookDescriptor hook_desc;
    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        if (index >= g_registered_show_hooks.size()) {
            LOGE("[IL2CPP_EVENT] Invalid hook index %zu (total=%zu)", index, g_registered_show_hooks.size());
            return;
        }
        hook_desc = g_registered_show_hooks[index];
    }

    ensure_unity_bridge();
    UnitySendMessage_t sender = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        sender = unity_send_message_;
    }

    std::string unit = placement.empty() ? g_captured_ad_unit_id : placement;
    const uintptr_t obj_ptr = reinterpret_cast<uintptr_t>(argc > 0 ? args[0] : nullptr);
    uint64_t tid = RewardTraceManager::instance().start_trace(
        get_package_name(), get_process_name(), "Unity IL2CPP", hook_desc.sdk_name, unit, obj_ptr, 100);

    std::string detail_msg = "intercepted " + hook_desc.class_name + "::" + hook_desc.method_name;
    RewardTraceManager::instance().record_stage(
        tid, RewardStage::ShowObserved, RewardFailure::None, detail_msg);

    // Профильный канал сети: доставка награды тем же путём, каким её доставил
    // бы сам рекламный SDK.
    ShowContext ctx;
    ctx.sdk = hook_desc.sdk_name;
    ctx.class_name = hook_desc.class_name;
    ctx.method_name = hook_desc.method_name;
    ctx.unit = unit;
    ctx.is_load = (hook_desc.kind == ShowHookKind::Load);
    ctx.argc = (argc > 6) ? 6 : argc;
    for (size_t i = 0; i < ctx.argc; ++i) ctx.args[i] = args[i];

    if (RewardChannels::instance().deliver(ctx)) {
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::RewardCallbackObserved, RewardFailure::None, "delivered via SDK channel");
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "reward channel completed");
        return;
    }

    if (ctx.is_load) {
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "load intercepted");
        return;
    }

    const bool delegate_invoked = false;
    if (!sender && !delegate_invoked) {
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::ShowObserved, RewardFailure::BackendUnavailable, "UnitySendMessage bridge unavailable");
        LOGW("[IL2CPP_EVENT] UnitySendMessage bridge unavailable for %s::%s",
             hook_desc.class_name.c_str(), hook_desc.method_name.c_str());
        return;
    }

    ISdkAdapter *target = hook_desc.target_adapter;
    if (!target && !hook_desc.sdk_name.empty()) {
        target = find_adapter_by_name(hook_desc.sdk_name);
    }

    if (target && sender) {
        LOGI("[IL2CPP_EVENT] Exact SDK dispatch to adapter '%s' for method %s::%s (trace_id=%llu)",
             target->get_name(), hook_desc.class_name.c_str(), hook_desc.method_name.c_str(),
             static_cast<unsigned long long>(tid));
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::AdDisplayed, RewardFailure::None, target->get_name());

        target->on_reward_granted(unit, sender);

        RewardTraceManager::instance().record_stage(
            tid, RewardStage::CompletionObserved, RewardFailure::None, "ad playback completed");
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::RewardCallbackObserved, RewardFailure::None, "virtual reward granted");
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "reward sequence completed");
    } else if (sender && !active_adapters_.empty()) {
        LOGI("[IL2CPP_EVENT] App-level game method %s::%s -> dispatching virtual reward to all %zu active SDK adapter(s)",
             hook_desc.class_name.c_str(), hook_desc.method_name.c_str(), active_adapters_.size());
        for (auto *adapter : active_adapters_) {
            if (adapter) {
                adapter->on_reward_granted(unit, sender);
            }
        }
        notify_all_unity_rewards();
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "multi-adapter reward sequence completed");
    } else if (delegate_invoked) {
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "delegate reward sequence completed");
    } else {
        LOGW("[IL2CPP_EVENT] No matching SDK adapter confirmed for %s::%s (sdk=%s); attempting universal Unity broadcast",
             hook_desc.class_name.c_str(), hook_desc.method_name.c_str(), hook_desc.sdk_name.c_str());
        notify_all_unity_rewards();
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "fallback broadcast completed");
    }
}

void Il2CppResolver::dispatch_targeted_reward(const std::string &sdk_name, const std::string &placement,
                                             uintptr_t obj_ptr, ISdkAdapter *adapter) {
    ensure_unity_bridge();
    UnitySendMessage_t sender = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        sender = unity_send_message_;
    }

    std::string unit = placement.empty() ? g_captured_ad_unit_id : placement;
    uint64_t tid = RewardTraceManager::instance().start_trace(
        get_package_name(), get_process_name(), "Unity IL2CPP", sdk_name, unit, obj_ptr, 100);

    RewardTraceManager::instance().record_stage(
        tid, RewardStage::ShowObserved, RewardFailure::None, "intercepted show call; targeting confirmed SDK adapter");

    if (!sender) {
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::ShowObserved, RewardFailure::BackendUnavailable, "UnitySendMessage bridge unavailable");
        LOGW("[IL2CPP_EVENT] UnitySendMessage bridge unavailable; cannot dispatch synthetic reward callbacks");
        return;
    }

    ISdkAdapter *target = adapter;
    if (!target && !sdk_name.empty() && sdk_name != "AutoDetect") {
        target = find_adapter_by_name(sdk_name);
    }

    if (target) {
        LOGI("[IL2CPP_EVENT] Dispatching reward to target SDK adapter: %s (trace_id=%llu)",
             target->get_name(), static_cast<unsigned long long>(tid));
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::AdDisplayed, RewardFailure::None, target->get_name());

        target->on_reward_granted(unit, sender);

        RewardTraceManager::instance().record_stage(
            tid, RewardStage::CompletionObserved, RewardFailure::None, "ad playback completed");
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::RewardCallbackObserved, RewardFailure::None, "virtual reward granted");
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "reward sequence completed");
    } else {
        LOGI("[IL2CPP_EVENT] Broadcasting virtual reward to all SDK adapter(s) and universal fallback channels (trace_id=%llu)",
             static_cast<unsigned long long>(tid));
        for (const auto &adp : sdk_adapters_) {
            if (adp) {
                adp->on_reward_granted(unit, sender);
            }
        }
        if (sender) {
            // Facebook Audience Network
            sender("RewardedVideoAdBridge", "onRewardedVideoCompleted", "");
            sender("RewardedVideoAdBridge", "onRewardServerSuccess", "");
            sender("RewardedVideoAdBridge", "onRewardedVideoClosed", "");
            sender("AudienceNetworkCallbackAndroid", "onRewardedVideoCompleted", "");
            sender("AudienceNetworkCallbackAndroid", "onRewardServerSuccess", "");
            sender("AudienceNetworkCallbackAndroid", "onRewardedVideoClosed", "");

            // Google Mobile Ads (AdMob)
            sender("GoogleMobileAdsCallbacks", "onRewardedAdLoaded", "");
            sender("GoogleMobileAdsCallbacks", "onAdShowedFullScreenContent", "");
            sender("GoogleMobileAdsCallbacks", "onUserEarnedReward", "1");
            sender("GoogleMobileAdsCallbacks", "onAdDismissedFullScreenContent", "");
            sender("GoogleMobileAdsRewardedAdClient", "onUserEarnedReward", "1");

            // Unity Ads
            sender("UnityAdsCallbacks", "onUnityAdsAdLoaded", unit.c_str());
            sender("UnityAdsCallbacks", "onUnityAdsShowStart", unit.c_str());
            sender("UnityAdsCallbacks", "onUnityAdsShowComplete", "{\"placementId\":\"rewardedVideo\",\"showCompletionState\":\"COMPLETED\"}");
            sender("UnityAdsCallbacks", "onUnityAdsFinish", "rewardedVideo;COMPLETED");

            // IronSource (LevelPlay)
            sender("IronSourceEvents", "onRewardedVideoAvailabilityChanged", "{\"available\":\"true\"}");
            sender("IronSourceEvents", "onRewardedVideoAdOpened", "");
            std::string ironJson = "{\"placement_name\":\"" + unit + "\",\"reward_name\":\"coins\",\"reward_amount\":\"1\"}";
            sender("IronSourceEvents", "onRewardedVideoAdRewarded", ironJson.c_str());
            sender("IronSourceEvents", "onRewardedVideoAdClosed", "");
            sender("IronSourceEvents", "onRewardedVideoAvailabilityChanged", "{\"available\":\"true\"}");

            // Yandex Mobile Ads
            sender("YandexMobileAdsRewardCallback", "OnRewarded", "1");
            sender("YandexMobileAdsCallback", "OnAdDismissed", "");
            sender("YandexMobileAdsCallback", "OnAdLoaded", "");

            // Mintegral (MBridge), Vungle, Pangle
            sender("MBridgeRewardCallbacks", "onVideoComplete", "");
            sender("MBridgeRewardCallbacks", "onAdCloseWithReward", "{\"rewardName\":\"coins\",\"rewardAmount\":1}");
            sender("VungleCallbacks", "onAdReward", unit.c_str());
            sender("VungleCallbacks", "onAdEnd", unit.c_str());
            sender("PAGRewardedAdCallbacks", "onUserEarnedReward", "");
            sender("PAGRewardedAdCallbacks", "onAdDismissed", "");
        }
        RewardTraceManager::instance().record_stage(
            tid, RewardStage::Finished, RewardFailure::None, "broadcast reward sequence completed");
    }
}

void Il2CppResolver::notify_active_sdk_rewards(uint64_t trace_id) {
    dispatch_targeted_reward("AutoDetect", g_captured_ad_unit_id, 0, nullptr);
}

void Il2CppResolver::notify_all_unity_rewards() {
    notify_active_sdk_rewards(0);
}

bool Il2CppResolver::hook_method_always_true(const MethodInfo *method, const char *desc) {
    if (!method) return false;

    // Пересекающиеся правила конфигурации часто указывают на один и тот же
    // метод. Повторная установка заняла бы ещё один слот трамплина и вытеснила
    // бы реальные цели, поэтому дубликаты отсекаются до резервирования слота.
    if (!method->methodPointer) {
        LOGW("[HOOK-SKIP] target=%s reason=METHOD_NOT_COMPILED", desc ? desc : "?");
        return false;
    }
    if (is_detoured(reinterpret_cast<void *>(method->methodPointer))) {
        return true;
    }

    // Строгая проверка типа возврата: разрешено ТОЛЬКО для System.Boolean (fail-closed)
    if (!method_get_return_type_) {
        LOGW("[HOOK-SKIP] target=%s reason=RETURN_TYPE_UNAVAILABLE detail=method_get_return_type is null",
             desc ? desc : "?");
        return false;
    }

    const Il2CppType *ret_t = method_get_return_type_(method);
    std::string ret_name = safe_type_get_name(ret_t, type_get_name_, il2cpp_free_, type_get_type_);
    if (ret_name != "System.Boolean" && ret_name != "bool") {
        LOGW("[HOOK-SKIP] target=%s reason=RETURN_TYPE_MISMATCH expected=System.Boolean actual=%s",
             desc ? desc : "?", ret_name.c_str());
        return false;
    }

    // Индивидуальный трамплин даёт счётчик реальных вызовов для этого метода.
    // При исчерпании слотов используется общий ассемблерный стаб без телеметрии.
    size_t ready_idx = SIZE_MAX;
    Il2CppMethodPointer stub = reinterpret_cast<Il2CppMethodPointer>(&stub_return_true);
    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        if (g_registered_ready_hooks.size() < MAX_READY_HOOKS) {
            ready_idx = g_registered_ready_hooks.size();
            g_registered_ready_hooks.push_back(desc ? desc : "?");
            stub = s_ready_trampolines[ready_idx];
        }
    }

    DetourStatus detour = install_detour(reinterpret_cast<void *>(method->methodPointer),
                                         reinterpret_cast<void *>(stub));
    if (detour == DetourStatus::Ok || detour == DetourStatus::AlreadyHooked) {
        LOGI("[IL2CPP_HOOK] [SUCCESS] Inline detour -> always_true (%s, is_static=%d, addr=%p, slot=%zu)",
             desc ? desc : "?", is_method_static(method),
             reinterpret_cast<void *>(method->methodPointer), ready_idx);

        // Фиксация в канале Readiness (как примененный Override/Patch, без подделки original_value)
        ReadyTrace ready;
        ready.sdk = "IL2CPP";
        ready.format = "Rewarded";
        ready.placement = "method_hook";
        ready.class_name = desc ? desc : "UnknownClass";
        ready.method_name = "always_true_stub";
        ready.event_type = ReadyEventType::OverrideApplied;
        ready.origin = ReadyOrigin::Sdk;
        ready.transport = ReadyTransport::Il2Cpp;
        ready.observed_value = -1; // Not observed.
        // A successful methodPointer write proves only that the patch was installed;
        // it does not prove that every runtime call path subsequently returned true.
        ready.effective_value = -1; // Unknown until an actual post-install call is observed.
        ready.reason = NotReadyReason::Unknown;
        ready.confidence = 100;
        RewardTraceManager::instance().record_ready_check(ready);
        return true;
    }

    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        if (ready_idx != SIZE_MAX && g_registered_ready_hooks.size() == ready_idx + 1) {
            g_registered_ready_hooks.pop_back();
        }
    }
    LOGW("[HOOK-SKIP] target=%s reason=DETOUR_FAILED status=%s addr=%p",
         desc ? desc : "?", to_string(detour), reinterpret_cast<void *>(method->methodPointer));
    return false;
}

bool Il2CppResolver::hook_method_network_reachability(const MethodInfo *method, const char *desc) {
    if (!method) return false;

    Il2CppMethodPointer stub = reinterpret_cast<Il2CppMethodPointer>(&stub_return_two);

    DetourStatus detour = install_detour(reinterpret_cast<void *>(method->methodPointer),
                                         reinterpret_cast<void *>(stub));
    if (detour == DetourStatus::Ok || detour == DetourStatus::AlreadyHooked) {
        LOGI("[IL2CPP_HOOK] [SUCCESS] Inline detour -> reachability=LAN (%s)", desc ? desc : "?");

        ReadyTrace ready;
        ready.sdk = "Unity";
        ready.format = "Reachability";
        ready.placement = "network_spoofer";
        ready.class_name = desc ? desc : "UnityEngine.Application";
        ready.method_name = "get_internetReachability";
        ready.event_type = ReadyEventType::OverrideApplied;
        ready.origin = ReadyOrigin::Sdk;
        ready.transport = ReadyTransport::Il2Cpp;
        ready.observed_value = 2;
        ready.effective_value = 2;
        ready.reason = NotReadyReason::Unknown;
        ready.confidence = 100;
        RewardTraceManager::instance().record_ready_check(ready);
        return true;
    }
    LOGW("[HOOK-SKIP] target=%s reason=DETOUR_FAILED status=%s", desc ? desc : "?", to_string(detour));
    return false;
}

bool Il2CppResolver::hook_method_forward_interceptor(const MethodInfo *method, const char *desc) {
    if (!method) return false;

    // ForwardEvent требует перехвата С ВЫЗОВОМ ОРИГИНАЛА (событие переписывается и
    // передаётся дальше). Движок inline-перехвата рассчитан на полную подмену и
    // оригинал не сохраняет, поэтому такой хук не устанавливается.
    //
    // Функциональной потери нет: при работающем перехвате готовности и показа SDK
    // вообще не доходит до сетевых запросов, а значит не порождает событий отказа,
    // которые этот перехватчик переписывал. Подстраховка на стороне Java
    // (прокси backgroundCallback у MaxUnityPlugin) остаётся активной.
    LOGI("[IL2CPP_HOOK] [SKIP] ForwardInterceptor не требуется при активном inline-перехвате (%s)",
         desc ? desc : "?");
    return false;
}

// Делегат завершения, который модуль умеет вызвать корректно.
//
// Значение аргумента синтезируется только для простых значимых типов. Делегат с
// параметром-ссылкой (Action<Reward>, Action<AdInfo>) вызвать нечем: подстановка
// константы означала бы передачу невалидного указателя.
static bool is_simple_completion_delegate(const std::string &type_name) {
    if (type_name == "System.Action") return true;
    static const char *const kSimple[] = {
        "System.Action<System.Boolean>", "System.Action<System.Int32>",
        "System.Action<System.UInt32>",  "System.Action<System.Byte>",
        "System.Action<System.SByte>",   "System.Action<System.Int16>",
        "System.Action<System.UInt16>"
    };
    for (const char *known : kSimple) {
        if (type_name == known) return true;
    }
    return false;
}

// Разрешение на полную подмену метода показа.
//
// Методы показа делятся на два принципиально разных класса:
//   * точки входа рекламного SDK (MaxSdk, GoogleMobileAds, AudienceNetwork...) —
//     это тонкие мосты к нативному SDK, их безопасно заменять целиком;
//   * внутренние обёртки самой игры (Assembly-CSharp) — они помимо вызова SDK
//     готовят собственное состояние: сохраняют коллбэк, ставят флаги, открывают
//     UI. Их подмена оставляет игру с неинициализированными полями, и она падает
//     уже после возврата из перехвата.
//
// Поэтому подмена показа применяется строго к точкам входа SDK. Готовность
// (always_true) при этом остаётся разрешённой везде: это чистый запрос без
// побочных эффектов, и именно он делает кнопки наград активными.
static bool is_sdk_show_entry_point(const std::string &assembly, const std::string &class_name) {
    const std::string lasm = to_lower(assembly);
    const bool game_assembly = lasm.empty() || lasm.rfind("assembly-csharp", 0) == 0;
    if (!game_assembly) return true;

    // SDK, вкомпилированный прямо в код игры: допускаются только строгие имена.
    // Сравнение по полному имени и по суффиксу, поскольку в описании метода
    // присутствует пространство имён (например GoogleMobileAds.Api.RewardedAd).
    static const char *const kSdkClasses[] = {
        "MaxSdk", "MaxSdkAndroid", "MaxSdkBase", "MaxSdkCallbacks",
        "GoogleMobileAds.Api.RewardedAd", "GoogleMobileAds.Api.InterstitialAd",
        "GoogleMobileAds.Api.RewardedInterstitialAd", "GoogleMobileAds", "MobileAds",
        "IronSource", "IronSourceEvents", "LevelPlay",
        "UnityEngine.Advertisements.Advertisement", "Advertisement", "UnityAds",
        "YandexMobileAds.RewardedAd", "YandexMobileAds.Interstitial", "YandexMobileAds",
        "AudienceNetworkAds", "RewardedVideoAdBridge", "RewardedVideoAdBridgeAndroid",
        "InterstitialAdBridge", "InterstitialAdBridgeAndroid"
    };
    for (const char *known : kSdkClasses) {
        const std::string k(known);
        if (class_name == k) return true;
        if (class_name.size() > k.size() &&
            class_name.compare(class_name.size() - k.size(), k.size(), k) == 0 &&
            class_name[class_name.size() - k.size() - 1] == '.') {
            return true;
        }
    }
    return false;
}

bool Il2CppResolver::hook_method_show_and_reward(const MethodInfo *method, const char *desc,
                                                 const char *assembly) {
    if (!method) return false;

    // Пересекающиеся правила конфигурации часто указывают на один и тот же
    // метод. Повторная установка заняла бы ещё один слот трамплина и вытеснила
    // бы реальные цели, поэтому дубликаты отсекаются до резервирования слота.
    if (!method->methodPointer) {
        LOGW("[HOOK-SKIP] target=%s reason=METHOD_NOT_COMPILED", desc ? desc : "?");
        return false;
    }
    if (is_detoured(reinterpret_cast<void *>(method->methodPointer))) {
        return true;
    }

    // Строгая проверка полного количества C++ аргументов (включая скрытый this)
    int cpp_args = get_method_cpp_args(method);
    if (cpp_args > 5) {
        LOGW("[HOOK-SKIP] target=%s reason=CPP_ARG_COUNT_EXCEEDED actual=%d max=5 (is_static=%d)",
             desc ? desc : "?", cpp_args, is_method_static(method));
        return false;
    }

    if (g_registered_show_hooks.size() >= MAX_SHOW_HOOKS) {
        LOGW("[HOOK-SKIP] target=%s reason=MAX_SHOW_HOOKS_EXCEEDED max=%zu",
             desc ? desc : "?", MAX_SHOW_HOOKS);
        return false;
    }

    // Строгая проверка типов параметров для предотвращения ABI mismatches (FPR/ValueType registers)
    // и одновременно поиск коллбэка завершения среди аргументов.
    bool has_completion_delegate = false;
    if (method_get_param_ && type_get_type_) {
        uint32_t pcount = method_get_param_count_ ? method_get_param_count_(method) : 0;
        for (uint32_t p = 0; p < pcount; ++p) {
            const Il2CppType *pt = method_get_param_(method, p);
            if (pt) {
                int ttype = type_get_type_(pt);
                // Запрещены типы с плавающей точкой (R4=0x0c, R8=0x0d) и непримитивные ValueType структуры (0x11)
                if (ttype == 0x0c || ttype == 0x0d || ttype == 0x11) {
                    LOGW("[HOOK-SKIP] target=%s reason=NON_POINTER_PARAM_ABI_UNSAFE param=%u type=0x%02x",
                         desc ? desc : "?", p, ttype);
                    return false;
                }
                if (is_simple_completion_delegate(
                        safe_type_get_name(pt, type_get_name_, il2cpp_free_, type_get_type_))) {
                    has_completion_delegate = true;
                }
            }
        }
    }

    // Проверка типа возврата: ShowAndReward безопасно поддерживает System.Void, System.Boolean, System.Int32, System.UInt32, System.Int64 и ссылки на объекты.
    // Запрещены только UniTask, Task и непримитивные ValueType структуры (rtype == 0x11).
    if (!method_get_return_type_) {
        LOGW("[HOOK-SKIP] target=%s reason=RETURN_TYPE_UNAVAILABLE detail=method_get_return_type is null",
             desc ? desc : "?");
        return false;
    }

    const Il2CppType *ret_t = method_get_return_type_(method);
    std::string ret_name = safe_type_get_name(ret_t, type_get_name_, il2cpp_free_, type_get_type_);

    // Запрет на асинхронные структуры и сопрограммы (UniTask / Task / IEnumerator)
    if (ret_name.find("UniTask") != std::string::npos || ret_name.find("Task`") != std::string::npos ||
        ret_name.find("YieldInstruction") != std::string::npos || ret_name.find("IEnumerator") != std::string::npos) {
        LOGW("[HOOK-SKIP] target=%s reason=ASYNC_STRUCT_RETURN_UNSAFE name=%s",
             desc ? desc : "?", ret_name.c_str());
        return false;
    }

    if (type_get_type_) {
        int rtype = type_get_type_(ret_t);
        // Запрещены непримитивные ValueType структуры (0x11), кроме базовых скалярных типов
        if (rtype == 0x11 && ret_name != "System.Boolean" && ret_name != "bool" &&
            ret_name != "System.Int32" && ret_name != "int" && ret_name != "System.UInt32" &&
            ret_name != "uint" && ret_name != "System.Int64" && ret_name != "long" &&
            ret_name != "System.Byte" && ret_name != "byte") {
            LOGW("[HOOK-SKIP] target=%s reason=NON_SCALAR_VALUETYPE_RETURN_UNSAFE rtype=0x%02x name=%s",
                 desc ? desc : "?", rtype, ret_name.c_str());
            return false;
        }
    }

    // Извлечение имени класса и метода
    std::string desc_str = desc ? desc : "UnknownClass::UnknownMethod";
    std::string class_name = "UnknownClass";
    std::string method_name = "Show";
    auto delim = desc_str.find("::");
    if (delim != std::string::npos) {
        class_name = desc_str.substr(0, delim);
        method_name = desc_str.substr(delim + 2);
    }

    // Обёртку приложения допустимо подменять только тогда, когда продолжение
    // игры приходит аргументом вызова: тогда модуль вызывает его сам, и
    // состояние не теряется. Без такого коллбэка подмена оставляет игру с
    // неинициализированными полями (подтверждено падением Rogue Legend).
    if (!is_sdk_show_entry_point(assembly ? assembly : "", class_name) && !has_completion_delegate) {
        LOGW("[HOOK-SKIP] target=%s reason=GAME_WRAPPER_WITHOUT_CALLBACK assembly=%s "
             "detail=подмена обёртки без коллбэка завершения ломает состояние игры",
             desc_str.c_str(), assembly ? assembly : "?");
        return false;
    }
    if (has_completion_delegate && !is_sdk_show_entry_point(assembly ? assembly : "", class_name)) {
        LOGI("[IL2CPP_HOOK] Обёртка игры %s принимает коллбэк завершения — подмена безопасна",
             desc_str.c_str());
    }

    // Определение точного SDK для этого метода
    std::string sdk_name = "GenericGameEngine";
    if (class_name.find("MaxSdk") != std::string::npos || class_name.find("AppLovin") != std::string::npos) {
        sdk_name = "AppLovin.MAX";
    } else if (class_name.find("GoogleMobileAds") != std::string::npos || class_name.find("AdMob") != std::string::npos) {
        sdk_name = "GoogleMobileAds";
    } else if (class_name.find("IronSource") != std::string::npos ||
               class_name.find("LevelPlay") != std::string::npos) {
        sdk_name = "IronSource";
    } else if (class_name.find("UnityAds") != std::string::npos ||
               class_name.find("Advertisement") != std::string::npos) {
        sdk_name = "UnityAds";
    } else if (class_name.find("Yandex") != std::string::npos) {
        sdk_name = "YandexMobileAds";
    } else if (desc_str.find("Voodoo") != std::string::npos) {
        sdk_name = "VoodooSauce";
    }

    ISdkAdapter *target_adapter = find_adapter_by_name(sdk_name);

    size_t idx = 0;
    ShowHookDescriptor hook_desc;
    hook_desc.method = method;
    hook_desc.sdk_name = sdk_name;
    hook_desc.class_name = class_name;
    hook_desc.method_name = method_name;
    hook_desc.cpp_args = cpp_args;
    hook_desc.is_static = is_method_static(method);
    hook_desc.target_adapter = target_adapter;
    hook_desc.kind = (to_lower(method_name).find("load") != std::string::npos)
                         ? ShowHookKind::Load
                         : ShowHookKind::Show;

    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        idx = g_registered_show_hooks.size();
        g_registered_show_hooks.push_back(hook_desc);
    }

    Il2CppMethodPointer stub = nullptr;
    if (cpp_args == 0) {
        stub = s_trampolines_0[idx];
    } else if (cpp_args == 1) {
        stub = s_trampolines_1[idx];
    } else if (cpp_args == 2) {
        stub = s_trampolines_2[idx];
    } else if (cpp_args == 3) {
        stub = s_trampolines_3[idx];
    } else if (cpp_args == 4) {
        stub = s_trampolines_4[idx];
    } else {
        stub = s_trampolines_5[idx];
    }

    DetourStatus detour = install_detour(reinterpret_cast<void *>(method->methodPointer),
                                         reinterpret_cast<void *>(stub));
    if (detour == DetourStatus::Ok || detour == DetourStatus::AlreadyHooked) {
        LOGI("[IL2CPP_HOOK] [SUCCESS] Inline detour -> show hook #%zu %s::%s (sdk=%s, is_static=%d, cpp_args=%d, addr=%p)",
             idx, class_name.c_str(), method_name.c_str(), sdk_name.c_str(),
             is_method_static(method), cpp_args, reinterpret_cast<void *>(method->methodPointer));
        return true;
    }

    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        if (g_registered_show_hooks.size() == idx + 1) {
            g_registered_show_hooks.pop_back();
        }
    }
    LOGW("[HOOK-SKIP] target=%s reason=DETOUR_FAILED status=%s addr=%p",
         desc ? desc : "?", to_string(detour), reinterpret_cast<void *>(method->methodPointer));
    return false;
}

ResolveStatus Il2CppResolver::probe_and_resolve(const std::string &package_name) {
    if (!init()) return ResolveStatus::NotIl2Cpp;

    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        std::string full_proc = package_name.empty() ? "unknown_pkg" : package_name;
        process_name_ = full_proc;
        auto colon_pos = full_proc.find(':');
        if (colon_pos != std::string::npos) {
            package_name_ = full_proc.substr(0, colon_pos);
        } else {
            package_name_ = full_proc;
        }
    }

    // -----------------------------------------------------------------------
    // Выдержка ДО первого обращения к рантайму.
    //
    // Небезопасен не только обход метаданных, но и сам il2cpp_domain_get():
    // пока выполняется il2cpp_init, он разыменовывает ещё не созданные
    // внутренние структуры. Подтверждено на устройстве: падение с
    // SIGSEGV по адресу 0x135 внутри libil2cpp через 246 мс после появления
    // библиотеки, вызов пришёл именно из этой строки.
    //
    // Поэтому отсчёт ведётся от момента, когда libil2cpp.so впервые оказалась
    // доступна для dlsym (операция безопасная), и до истечения выдержки в
    // рантайм не делается ни одного вызова.
    // -----------------------------------------------------------------------
    {
        static uint64_t s_runtime_seen_ms = 0;
        struct timespec ts{};
        clock_gettime(CLOCK_MONOTONIC, &ts);
        const uint64_t now_ms = static_cast<uint64_t>(ts.tv_sec) * 1000ull +
                                static_cast<uint64_t>(ts.tv_nsec) / 1000000ull;
        if (s_runtime_seen_ms == 0) {
            s_runtime_seen_ms = now_ms;
            LOGI("[IL2CPP] libil2cpp обнаружена; выдержка %llu мс до первого обращения к рантайму",
                 static_cast<unsigned long long>(kRuntimeSettleMs));
            return ResolveStatus::RuntimeNotReady;
        }
        if (now_ms - s_runtime_seen_ms < kRuntimeSettleMs) {
            return ResolveStatus::RuntimeNotReady;
        }
    }

    Il2CppDomain *domain = domain_get_ ? domain_get_() : nullptr;
    if (!domain) {
        LOGW("[IL2CPP] domain is null (runtime may still be initializing)");
        return ResolveStatus::RuntimeNotReady;
    }

    // -----------------------------------------------------------------------
    // Барьер готовности рантайма.
    //
    // il2cpp_domain_get() начинает возвращать ненулевой домен ЗАДОЛГО до
    // завершения il2cpp_init. Присоединение стороннего потока к сборщику мусора
    // или обход метаданных в этот момент приводит к abort() внутри libil2cpp
    // прямо на этапе инициализации — игра падает на старте.
    //
    // Поэтому прикрепление потока выполняется только после того, как:
    //   1) прошла выдержка с момента появления домена;
    //   2) количество загруженных сборок перестало меняться.
    // -----------------------------------------------------------------------
    {
        static size_t   s_last_assembly_probe = 0;
        static uint64_t s_last_change_ms = 0;

        struct timespec ts{};
        clock_gettime(CLOCK_MONOTONIC, &ts);
        const uint64_t now_ms = static_cast<uint64_t>(ts.tv_sec) * 1000ull +
                                static_cast<uint64_t>(ts.tv_nsec) / 1000000ull;

        size_t probe_count = 0;
        const Il2CppAssembly **probe = domain_get_assemblies_(domain, &probe_count);
        if (!probe || probe_count < 4) {
            s_last_change_ms = 0;
            return ResolveStatus::RuntimeNotReady;
        }
        if (probe_count != s_last_assembly_probe) {
            s_last_assembly_probe = probe_count;
            s_last_change_ms = now_ms;
            return ResolveStatus::RuntimeNotReady;
        }
        if (s_last_change_ms == 0) {
            s_last_change_ms = now_ms;
            return ResolveStatus::RuntimeNotReady;
        }
        if (now_ms - s_last_change_ms < kAssemblyStableMs) {
            return ResolveStatus::RuntimeNotReady;
        }
    }

    // Прикрепляем текущий поток к рантайму IL2CPP и GC
    Il2CppThreadScope thread_scope(thread_attach_, thread_detach_, domain);

    size_t assembly_count = 0;
    const Il2CppAssembly **assemblies = domain_get_assemblies_(domain, &assembly_count);
    if (!assemblies || assembly_count < 2) {
        LOGW("[IL2CPP] runtime assemblies not fully loaded yet (count=%zu; still initializing)", assembly_count);
        return ResolveStatus::RuntimeNotReady;
    }

    // 1. Построение карты сборок
    std::unordered_map<std::string, const Il2CppImage *> images_by_name;
    std::vector<const Il2CppImage *> all_images;
    all_images.reserve(assembly_count);

    bool core_ready = false;
    for (size_t i = 0; i < assembly_count; ++i) {
        const Il2CppImage *image = assembly_get_image_(assemblies[i]);
        if (!image) continue;
        all_images.push_back(image);
        if (image_get_name_) {
            const char *name = image_get_name_(image);
            if (name) {
                images_by_name[name] = image;
                if (strstr(name, "mscorlib") || strstr(name, "System") ||
                    strstr(name, "UnityEngine") || strstr(name, "Assembly-CSharp")) {
                    core_ready = true;
                }
            }
        }
    }

    if (!core_ready) {
        LOGW("[IL2CPP] core assemblies not yet ready; waiting for il2cpp_init completion");
        return ResolveStatus::RuntimeNotReady;
    }

    if (g_last_assembly_count > 0 && assembly_count != g_last_assembly_count) {
        LOGI("[IL2CPP] assemblies_changed old=%zu new=%zu", g_last_assembly_count, assembly_count);
    }
    g_last_assembly_count = assembly_count;

    // 2. Детектирование подключенных SDK через зарегистрированные адаптеры
    std::vector<ISdkAdapter *> new_active;
    std::vector<std::string> detected_sdks;
    for (const auto &adapter : sdk_adapters_) {
        for (const Il2CppImage *image : all_images) {
            if (adapter->probe_and_attach(image, class_from_name_, class_get_method_from_name_)) {
                std::string sname = adapter->get_name();
                detected_sdks.push_back(sname);
                new_active.push_back(adapter.get());
                bool is_blocked = is_sdk_hosts_blocked(sname);
                LOGI("[SDK_DETECT] Found active SDK '%s' (Hosts-blocked: %s)",
                     sname.c_str(), is_blocked ? "YES" : "NO");
                break;
            }
        }
    }

    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        active_adapters_ = std::move(new_active);
    }

    // 3. Построение единого метадата-индекса (Single-pass MetadataIndex)
    MetadataIndex::instance().build(
        all_images,
        image_get_name_,
        image_get_class_count_,
        image_get_class_,
        class_get_name_,
        class_get_namespace_,
        class_get_methods_,
        method_get_name_,
        method_get_param_count_,
        method_get_param_,
        method_get_return_type_,
        method_get_flags_,
        type_get_name_,
        type_get_type_,
        il2cpp_free_);

    // Rogue Legend выдаёт RV-покупку сервером уже после рекламного ожидания.
    // Перенаправление сохраняет штатную выдачу, исключая таймаут ShowRV.
    install_rogue_purchase_redirect(package_name_);

    // 3.1 Привязка нативного моста к каналу событий AppLovin MAX.
    //
    // Общий интерфейс адаптеров остаётся прежним; меняется только способ
    // доставки события для конкретной сети. Для MAX это прямой вызов
    // C#-метода, так как плагин не использует UnitySendMessage.
    if (!MaxBridge::instance().ready()) {
        auto forward_matches = MetadataIndex::instance().query_wildcard(
            "*", "*", "MaxSdkCallbacks", "ForwardEvent", 1);
        if (!forward_matches.empty()) {
            MaxBridge::instance().bind(forward_matches[0]->method_ptr, string_new_);
        }
    }

    // 4. Формирование фингерпринта и запись runtime_report.json
    GameFingerprint fp = FingerprintCollector::build_from_index(
        package_name.empty() ? "unknown_game" : package_name,
        assembly_count,
        detected_sdks,
        MetadataIndex::instance());

    ReportWriter::write_json_report(fp);

    // 4b. Проверка и логирование статуса Hosts-блокировки для подтвержденных SDK
    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        for (const auto *adapter : active_adapters_) {
            if (!adapter) continue;
            bool is_blocked = is_sdk_hosts_blocked(adapter->get_name());
            LOGI("[IL2CPP] SDK '%s' Hosts status: %s (failure pipeline safely managed at Java/SDK source level)",
                 adapter->get_name(), is_blocked ? "BLOCKED" : "ONLINE");
        }
    }

    // 5. Применение правил из конфигурации с поддержкой Wildcard через MetadataIndex
    const auto &rules = g_cached_rules;
    LOGI("[IL2CPP] Runtime ready: %zu assemblies, %zu methods indexed (%zu SDKs detected, %zu active); applying %zu hook rule(s)",
         assembly_count, MetadataIndex::instance().get_all_methods().size(), detected_sdks.size(), active_adapters_.size(), rules.size());

    for (const auto &rule : rules) {
        auto matches = MetadataIndex::instance().query_wildcard(
            rule.assembly, rule.name_space, rule.class_name, rule.method_name, rule.arg_count
        );

        if (matches.empty()) {
            LOGW("[IL2CPP_MISS] rule line=%d %s%s%s::%s argc=%d action=%s",
                 rule.line_no,
                 rule.name_space.empty() ? "" : rule.name_space.c_str(),
                 rule.name_space.empty() ? "" : ".",
                 rule.class_name.c_str(), rule.method_name.c_str(), rule.arg_count, rule.action.c_str());
            continue;
        }

        for (const auto *desc : matches) {
            if (!desc || !desc->method_ptr) continue;
            // Пространство имён входит в описание: по нему определяется
            // принадлежность метода конкретной рекламной сети.
            std::string desc_str = (desc->name_space.empty() ? desc->class_name
                                                             : desc->name_space + "." + desc->class_name) +
                                   "::" + desc->method_name;

            switch (rule.action_type) {
                case HookAction::Observe: {
                    LOGI("[IL2CPP_RESOLVE] [OBSERVE_ONLY] %s assembly=%s static=%d argc=%d return=%s tier=%d",
                         desc_str.c_str(), desc->assembly.c_str(), desc->is_static, desc->param_count,
                         desc->return_type.c_str(), static_cast<int>(desc->confidence_tier));
                    // v3.9.1 used to replace HandleBackgroundCallback::methodPointer here.
                    // That swallowed the original callback and therefore corrupted both
                    // application behavior and telemetry.  Observe is now strictly
                    // non-mutating until a trampoline that calls the original exists.
                    break;
                }
                case HookAction::AlwaysTrue:
                    // Guardrail: Запрещено применять always_true к Tier-3 Heuristic методам при wildcard правилах!
                    if (rule.assembly == "*" && rule.class_name.find('*') != std::string::npos &&
                        desc->confidence_tier == ConfidenceTier::HeuristicOnly) {
                        LOGW("[HOOK-SKIP] class=%s method=%s reason=LOW_CONFIDENCE_WILDCARD tier=HeuristicOnly",
                             desc->class_name.c_str(), desc->method_name.c_str());
                        continue;
                    }
                    hook_method_always_true(desc->method_ptr, desc_str.c_str());
                    break;
                case HookAction::ShowAndReward:
                    if (rule.assembly == "*" && rule.class_name.find('*') != std::string::npos &&
                        desc->confidence_tier == ConfidenceTier::HeuristicOnly) {
                        LOGW("[HOOK-SKIP] class=%s method=%s reason=LOW_CONFIDENCE_WILDCARD tier=HeuristicOnly",
                             desc->class_name.c_str(), desc->method_name.c_str());
                        continue;
                    }
                    hook_method_show_and_reward(desc->method_ptr, desc_str.c_str(), desc->assembly.c_str());
                    break;
                case HookAction::Reachability:
                    hook_method_network_reachability(desc->method_ptr, desc_str.c_str());
                    break;
                case HookAction::ForwardInterceptor:
                    hook_method_forward_interceptor(desc->method_ptr, desc_str.c_str());
                    break;
                default:
                    LOGW("[HOOK-SKIP] class=%s method=%s reason=UNKNOWN_ACTION action=%s",
                         desc->class_name.c_str(), desc->method_name.c_str(), rule.action.c_str());
                    break;
            }
        }
    }

    // 6. Автоматический вывод и применение семантических правил (AutoRuleEngine)
    auto inferred_rules = AutoRuleEngine::infer_rules(fp, rules);
    size_t applied_inferred = AutoRuleEngine::apply_rules(inferred_rules);
    AutoRuleEngine::export_inferred_rules(package_name, inferred_rules);
    LOGI("[IL2CPP] AutoRuleEngine applied %zu dynamic rule(s) (total candidates inferred=%zu)",
         applied_inferred, inferred_rules.size());

    return ResolveStatus::Success;
}

static uint64_t g_last_assembly_fingerprint = 0;

static uint64_t compute_assembly_fingerprint(const Il2CppAssembly **assemblies, size_t count,
                                             il2cpp_assembly_get_image_t get_image,
                                             il2cpp_image_get_name_t get_name) {
    uint64_t hash = count * 31;
    for (size_t i = 0; i < count; ++i) {
        const Il2CppAssembly *ass = assemblies[i];
        hash = hash * 33 + reinterpret_cast<uintptr_t>(ass);
        if (get_image) {
            const Il2CppImage *img = get_image(ass);
            if (img) {
                hash = hash * 33 + reinterpret_cast<uintptr_t>(img);
                if (get_name) {
                    const char *name = get_name(img);
                    if (name) {
                        for (const char *p = name; *p; ++p) {
                            hash = hash * 31 + static_cast<unsigned char>(*p);
                        }
                    }
                }
            }
        }
    }
    return hash;
}

bool Il2CppResolver::check_and_rescan_assemblies(const std::string &package_name) {
    if (!domain_get_ || !domain_get_assemblies_) return false;
    Il2CppDomain *domain = domain_get_();
    if (!domain) return false;

    Il2CppThreadScope thread_scope(thread_attach_, thread_detach_, domain);

    size_t assembly_count = 0;
    const Il2CppAssembly **assemblies = domain_get_assemblies_(domain, &assembly_count);
    if (!assemblies || assembly_count < 2) return false;

    uint64_t fingerprint = compute_assembly_fingerprint(assemblies, assembly_count, assembly_get_image_, image_get_name_);
    if (g_last_assembly_fingerprint > 0 && fingerprint != g_last_assembly_fingerprint) {
        LOGI("[IL2CPP] Dynamic assembly fingerprint changed (old=0x%llx new=0x%llx) -> re-executing probe_and_resolve",
             static_cast<unsigned long long>(g_last_assembly_fingerprint),
             static_cast<unsigned long long>(fingerprint));
        g_last_assembly_fingerprint = fingerprint;
        ResolveStatus status = probe_and_resolve(package_name);
        return (status == ResolveStatus::Success);
    }
    g_last_assembly_fingerprint = fingerprint;
    return false;
}


// Сводка фактических срабатываний перехватов. Вызывается только из фонового
// потока: на горячем пути остаётся единственный атомарный инкремент.
void log_hook_activity(bool force) {
    static std::mutex s_report_mutex;
    static uint64_t s_last_total = UINT64_MAX;
    std::lock_guard<std::mutex> report_lock(s_report_mutex);

    std::vector<std::string> ready_names;
    std::vector<std::string> show_names;
    {
        std::lock_guard<std::mutex> lock(g_state_mutex);
        ready_names = g_registered_ready_hooks;
        for (const auto &h : g_registered_show_hooks) {
            show_names.push_back(h.class_name + "::" + h.method_name);
        }
    }

    uint64_t ready_calls = 0;
    uint64_t show_calls = 0;
    for (size_t i = 0; i < ready_names.size() && i < MAX_READY_HOOKS; ++i) {
        ready_calls += g_ready_stats[i].calls.load(std::memory_order_relaxed);
    }
    for (size_t i = 0; i < show_names.size() && i < Il2CppResolver::MAX_SHOW_HOOKS; ++i) {
        show_calls += g_show_stats[i].calls.load(std::memory_order_relaxed);
    }

    const uint64_t total = ready_calls + show_calls;
    if (!force && total == s_last_total) return;
    s_last_total = total;

    size_t islands = 0;
    size_t slots = 0;
    detour_island_stats(&islands, &slots);

    LOGI("[HOOK_ACTIVITY] detours=%zu islands=%zu slots=%zu | ready: hooks=%zu calls=%" PRIu64
         " | show: hooks=%zu calls=%" PRIu64,
         detour_count(), islands, slots, ready_names.size(), ready_calls,
         show_names.size(), show_calls);

    for (size_t i = 0; i < ready_names.size() && i < MAX_READY_HOOKS; ++i) {
        uint64_t c = g_ready_stats[i].calls.load(std::memory_order_relaxed);
        if (c > 0) {
            LOGI("[HOOK_ACTIVITY]   READY  %s calls=%" PRIu64, ready_names[i].c_str(), c);
        }
    }
    for (size_t i = 0; i < show_names.size() && i < Il2CppResolver::MAX_SHOW_HOOKS; ++i) {
        uint64_t c = g_show_stats[i].calls.load(std::memory_order_relaxed);
        if (c > 0) {
            LOGI("[HOOK_ACTIVITY]   SHOW   %s calls=%" PRIu64, show_names[i].c_str(), c);
        }
    }
}

} // namespace smartreward

namespace {

struct ScopedJniString {
    JNIEnv *env = nullptr;
    jstring js = nullptr;
    const char *chars = nullptr;

    ScopedJniString(JNIEnv *e, jstring s) : env(e), js(s), chars(nullptr) {
        if (env && js) {
            chars = env->GetStringUTFChars(js, nullptr);
        }
    }

    ~ScopedJniString() {
        if (env && js && chars) {
            env->ReleaseStringUTFChars(js, chars);
        }
    }

    std::string to_string(const char *default_val = "") const {
        return (chars && *chars) ? std::string(chars) : std::string(default_val);
    }

    const char *c_str() const {
        return chars ? chars : "";
    }
};

} // namespace

// JNI Экспорт для прямого вызова из Java ядра
extern "C" JNIEXPORT void JNICALL
Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeNotifyUnityReward(
        JNIEnv *env, jclass, jstring j_obj, jstring j_meth, jstring j_msg) {
    if (!env) return;
    ScopedJniString obj(env, j_obj);
    ScopedJniString meth(env, j_meth);
    ScopedJniString msg(env, j_msg);

    if (obj.chars && meth.chars && msg.chars) {
        smartreward::Il2CppResolver::instance().notify_unity_reward(obj.c_str(), meth.c_str(), msg.c_str());
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeStartRewardTrace(
        JNIEnv *env, jclass, jstring j_pkg, jstring j_proc, jstring j_eng, jstring j_sdk, jstring j_plc, jint conf) {
    if (!env) return 0;
    ScopedJniString pkg(env, j_pkg);
    ScopedJniString proc(env, j_proc);
    ScopedJniString eng(env, j_eng);
    ScopedJniString sdk(env, j_sdk);
    ScopedJniString plc(env, j_plc);

    uint64_t tid = smartreward::RewardTraceManager::instance().start_trace(
        pkg.to_string(), proc.to_string(), eng.to_string("Java"), sdk.to_string("AutoDetect"), plc.to_string("rewarded_ad"), 0, conf);
    return static_cast<jlong>(tid);
}

extern "C" JNIEXPORT void JNICALL
Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeRecordRewardStage(
        JNIEnv *env, jclass, jlong j_tid, jint j_stage, jint j_fail, jstring j_detail) {
    if (!env) return;
    ScopedJniString detail(env, j_detail);
    smartreward::RewardTraceManager::instance().record_stage(
        static_cast<uint64_t>(j_tid),
        static_cast<smartreward::RewardStage>(j_stage),
        static_cast<smartreward::RewardFailure>(j_fail),
        detail.to_string());
}

extern "C" JNIEXPORT void JNICALL
Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeRecordReadyCheck(
        JNIEnv *env, jclass, jstring j_sdk, jstring j_fmt, jstring j_plc,
        jstring j_cls, jstring j_mth, jboolean j_val, jint j_reason) {
    if (!env) return;
    ScopedJniString sdk(env, j_sdk);
    ScopedJniString fmt(env, j_fmt);
    ScopedJniString plc(env, j_plc);
    ScopedJniString cls(env, j_cls);
    ScopedJniString mth(env, j_mth);

    smartreward::ReadyTrace r;
    r.sdk = sdk.to_string("UnknownSDK");
    r.format = fmt.to_string("Rewarded");
    r.placement = plc.to_string("default_placement");
    r.class_name = cls.to_string("UnknownClass");
    r.method_name = mth.to_string("isReady");
    r.event_type = smartreward::ReadyEventType::Observed;
    r.origin = smartreward::ReadyOrigin::Sdk;
    r.transport = smartreward::ReadyTransport::Java;
    r.observed_value = (j_val == JNI_TRUE) ? 1 : 0;
    r.effective_value = (j_val == JNI_TRUE) ? 1 : 0;
    r.reason = static_cast<smartreward::NotReadyReason>(j_reason);
    r.confidence = 100;

    smartreward::RewardTraceManager::instance().record_ready_check(r);
}
