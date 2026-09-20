#include "jni_bridge_hook.hpp"
#include "log.hpp"
#include "strings.hpp"
#include "java_loader.hpp"

#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <initializer_list>
#include <mutex>
#include <string>
#include <vector>

namespace smartreward {

namespace {

// ---------------------------------------------------------------------------
// Классификация Java-методов приложения.
//
// Имя метода разбирается на токены (по подчёркиванию и смене регистра), и
// решение принимается по составу токенов, а не по вхождению подстроки.
// Подстрочный поиск давал грубые ошибки: слово "ready" содержит "ad", из-за
// чего под правило попадал любой метод со словом ready.
//
// Разбор по токенам построен на реальных обёртках двух игр:
//
//   com.notdoppler.advertising.MAXHelper                (Cocos2d-x, модель уведомлений)
//     on_rewarded_video_availability_changed(boolean)   -> уведомление о доступности
//     on_rewarded_video_ad_rewarded()                   -> начисление награды
//     on_rewarded_video_ad_closed()                     -> закрытие экрана
//     showRewardedVideo(String)                         -> показ, void
//
//   com.ironhidegames.android.kr.act_game.KRGameActivity (LOVE 2D, модель запросов)
//     hasVideoAd(int, String)                           -> запрос готовности, boolean
//     createRequestShowVideoAd(int, String)             -> показ, возвращает номер запроса
//     getRequestStatus(int)                             -> опрос результата, 0 = успех
//
// Обратите внимание: в первой игре есть и `..._ad_rewarded`, и `..._ad_closed`,
// оба содержат слово "rewarded". Различить их можно только по ПОСЛЕДНЕМУ токену.
// ---------------------------------------------------------------------------

enum class Kind : int {
    Unresolved = 0,
    Pass,          // обычный метод, пропускаем как есть
    ReadyQuery,    // запрос готовности -> отвечаем «да»
    ShowVoid,      // показ без возвращаемого значения
    ShowInt,       // показ, возвращающий номер запроса
    StatusQuery    // опрос результата запроса
};

// Номер запроса, возвращаемый вместо настоящего. Значение заведомо не
// пересекается с номерами игры: они выдаются последовательно от нуля.
constexpr jint kSentinelRequestId = 0x5EED0001;

// Признак успешно завершённого запроса. Ноль как код успеха — устоявшееся
// соглашение, подтверждено в разобранной реализации Kingdom Rush.
constexpr jint kRequestStatusDone = 0;

std::vector<std::string> tokenize(const std::string &name) {
    std::vector<std::string> out;
    std::string cur;
    for (char c : name) {
        if (c == '_' || c == '-') {
            if (!cur.empty()) { out.push_back(cur); cur.clear(); }
            continue;
        }
        const bool upper = (c >= 'A' && c <= 'Z');
        if (upper && !cur.empty()) { out.push_back(cur); cur.clear(); }
        cur.push_back(upper ? static_cast<char>(c - 'A' + 'a') : c);
    }
    if (!cur.empty()) out.push_back(cur);
    return out;
}

bool has_token(const std::vector<std::string> &t, const char *what) {
    for (const auto &s : t) if (s == what) return true;
    return false;
}

bool has_any(const std::vector<std::string> &t, std::initializer_list<const char *> list) {
    for (const char *w : list) if (has_token(t, w)) return true;
    return false;
}

bool ad_context(const std::vector<std::string> &t) {
    return has_any(t, {"ad", "ads", "reward", "rewarded", "video", "rv", "interstitial"});
}

bool asks_readiness(const std::vector<std::string> &t) {
    return has_any(t, {"has", "is", "can", "ready", "available", "availability", "loaded", "cached"});
}

bool is_show(const std::vector<std::string> &t) {
    return has_any(t, {"show", "play", "display", "present"});
}

// Уведомление о доступности рекламы (модель «наталкивания»).
bool is_availability_notification(const std::vector<std::string> &t) {
    if (!ad_context(t)) return false;
    if (has_any(t, {"fail", "failed", "error", "expired"})) return false;
    return has_any(t, {"availability", "available", "ready", "loaded", "cached", "fill"});
}

bool is_reward_grant(const std::vector<std::string> &t) {
    if (t.empty() || !ad_context(t)) return false;
    const std::string &last = t.back();
    return last == "rewarded" || last == "reward" || last == "earned" || last == "granted" ||
           last == "completed" || last == "complete" || last == "success" ||
           last == "succeeded" || last == "finished" || last == "received";
}

bool is_reward_close(const std::vector<std::string> &t) {
    if (t.empty() || !ad_context(t)) return false;
    const std::string &last = t.back();
    return last == "closed" || last == "close" || last == "dismissed" || last == "hidden" ||
           last == "ended";
}

bool is_status_query(const std::vector<std::string> &t) {
    return has_token(t, "status") && has_any(t, {"request", "req"});
}

// ---------------------------------------------------------------------------

struct CacheEntry {
    std::atomic<uintptr_t> mid{0};
    std::atomic<int>       kind{0};
};

constexpr size_t kCacheSize = 4096;
CacheEntry g_cache[kCacheSize];

JNINativeInterface    g_orig{};
bool                  g_installed = false;
std::string           g_package;
std::string           g_vendor_prefix;

std::atomic<jclass>   g_helper_class{nullptr};
std::atomic<uint64_t> g_last_pulse_ms{0};
std::atomic<uint64_t> g_ready_hits{0};
std::atomic<uint64_t> g_show_hits{0};
std::atomic<uint64_t> g_resolved{0};

thread_local bool t_in_resolver = false;

uint64_t now_ms() {
    struct timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<uint64_t>(ts.tv_sec) * 1000ull + static_cast<uint64_t>(ts.tv_nsec) / 1000000ull;
}

size_t cache_slot(jmethodID mid) {
    return (reinterpret_cast<uintptr_t>(mid) >> 4) % kCacheSize;
}

bool contains(const std::string &h, const char *n) { return h.find(n) != std::string::npos; }

// Область действия ограничена собственным кодом приложения: рекламная обёртка
// всегда лежит в пространстве имён самого приложения. Внутренние вызовы
// рекламных SDK и системных библиотек проходят без изменений.
bool belongs_to_app(const std::string &cls) {
    return !g_vendor_prefix.empty() && cls.rfind(g_vendor_prefix, 0) == 0;
}

bool looks_like_ad_helper(const std::string &lcls) {
    return contains(lcls, "advertis") || contains(lcls, "adhelper") ||
           contains(lcls, "adsmanager") || contains(lcls, "admanager") ||
           contains(lcls, "maxhelper") || contains(lcls, "ironsourcehelper") ||
           contains(lcls, "admobhelper") || contains(lcls, ".ads.") ||
           contains(lcls, "adsutils");
}

// Имя метода и его класса через рефлексию. Используются только те функции JNI,
// которые не перехватываются, иначе разбор ушёл бы в рекурсию.
bool describe_method(JNIEnv *env, jclass declaring, jobject instance, jmethodID mid,
                     bool is_static, std::string *class_out, std::string *method_out) {
    jclass cls = declaring;
    jobject local_cls = nullptr;
    if (!cls && instance) {
        local_cls = env->GetObjectClass(instance);
        cls = reinterpret_cast<jclass>(local_cls);
    }
    if (!cls) return false;

    jobject reflected = env->ToReflectedMethod(cls, mid, is_static ? JNI_TRUE : JNI_FALSE);
    if (env->ExceptionCheck()) { env->ExceptionClear(); reflected = nullptr; }
    if (!reflected) {
        if (local_cls) env->DeleteLocalRef(local_cls);
        return false;
    }

    bool ok = false;
    jclass member_cls = env->GetObjectClass(reflected);
    jmethodID get_name = env->GetMethodID(member_cls, "getName", "()Ljava/lang/String;");
    jmethodID get_owner = env->GetMethodID(member_cls, "getDeclaringClass", "()Ljava/lang/Class;");
    if (get_name && get_owner) {
        auto name_str = reinterpret_cast<jstring>(env->CallObjectMethod(reflected, get_name));
        jobject owner = env->CallObjectMethod(reflected, get_owner);
        if (owner) {
            jclass cls_cls = env->GetObjectClass(owner);
            jmethodID cls_name = env->GetMethodID(cls_cls, "getName", "()Ljava/lang/String;");
            auto owner_str = reinterpret_cast<jstring>(env->CallObjectMethod(owner, cls_name));
            if (name_str && owner_str) {
                const char *n = env->GetStringUTFChars(name_str, nullptr);
                const char *o = env->GetStringUTFChars(owner_str, nullptr);
                if (n && o) { *method_out = n; *class_out = o; ok = true; }
                if (n) env->ReleaseStringUTFChars(name_str, n);
                if (o) env->ReleaseStringUTFChars(owner_str, o);
            }
            env->DeleteLocalRef(cls_cls);
        }
    }
    env->DeleteLocalRef(member_cls);
    env->DeleteLocalRef(reflected);
    if (local_cls) env->DeleteLocalRef(local_cls);
    if (env->ExceptionCheck()) env->ExceptionClear();
    return ok;
}

void *ready_pulse_worker(void *);

void remember_ad_helper(JNIEnv *env, jclass declaring, jobject instance,
                        const std::string &lcls, const std::string &cls_name) {
    if (g_helper_class.load(std::memory_order_acquire) != nullptr) return;
    if (!looks_like_ad_helper(lcls)) return;

    jclass cls = declaring;
    jobject local = nullptr;
    if (!cls && instance) {
        local = env->GetObjectClass(instance);
        cls = reinterpret_cast<jclass>(local);
    }
    if (!cls) return;

    auto global = reinterpret_cast<jclass>(env->NewGlobalRef(cls));
    if (local) env->DeleteLocalRef(local);
    if (!global) return;

    g_helper_class.store(global, std::memory_order_release);
    LOGI("[JNI_BRIDGE] Рекламная обёртка игры: %s", cls_name.c_str());

    pthread_t th{};
    if (pthread_create(&th, nullptr, ready_pulse_worker, nullptr) == 0) pthread_detach(th);
}

Kind resolve_kind(JNIEnv *env, jclass declaring, jobject instance, jmethodID mid,
                  bool is_static, char ret_type) {
    if (t_in_resolver) return Kind::Pass;
    t_in_resolver = true;

    Kind kind = Kind::Pass;
    std::string cls, method;
    if (describe_method(env, declaring, instance, mid, is_static, &cls, &method)) {
        const std::string lcls = to_lower(cls);
        if (belongs_to_app(lcls)) {
            const auto t = tokenize(method);
            remember_ad_helper(env, declaring, instance, lcls, cls);

            if (ret_type == 'Z' && ad_context(t) && asks_readiness(t) && !is_show(t)) {
                kind = Kind::ReadyQuery;
                LOGI("[JNI_BRIDGE] Запрос готовности: %s.%s -> отвечаем «готово»",
                     cls.c_str(), method.c_str());
            } else if (is_show(t) && ad_context(t)) {
                kind = (ret_type == 'I') ? Kind::ShowInt : Kind::ShowVoid;
                LOGI("[JNI_BRIDGE] Показ рекламы: %s.%s -> подмена на выдачу награды",
                     cls.c_str(), method.c_str());
            } else if (ret_type == 'I' && is_status_query(t)) {
                kind = Kind::StatusQuery;
                LOGI("[JNI_BRIDGE] Опрос результата запроса: %s.%s", cls.c_str(), method.c_str());
            }
        }
        g_resolved.fetch_add(1, std::memory_order_relaxed);
    }

    t_in_resolver = false;
    return kind;
}

Kind kind_of(JNIEnv *env, jclass declaring, jobject instance, jmethodID mid,
             bool is_static, char ret_type) {
    const uintptr_t key = reinterpret_cast<uintptr_t>(mid);
    CacheEntry &slot = g_cache[cache_slot(mid)];
    if (slot.mid.load(std::memory_order_relaxed) == key) {
        return static_cast<Kind>(slot.kind.load(std::memory_order_relaxed));
    }
    const Kind kind = resolve_kind(env, declaring, instance, mid, is_static, ret_type);
    slot.kind.store(static_cast<int>(kind), std::memory_order_relaxed);
    slot.mid.store(key, std::memory_order_relaxed);
    return kind;
}

// Вызов методов класса, отобранных разбором имени.
//
// Поддерживаются методы без аргументов и с одним аргументом типа boolean:
// уведомление о доступности рекламы обычно принимает признак доступности
// (`on_rewarded_video_availability_changed(boolean)`). Методы с иными
// аргументами пропускаются: подставлять значение вслепую нельзя.
int invoke_selected(JNIEnv *env, jclass cls, jobject instance,
                    bool (*match)(const std::vector<std::string> &), const char *what) {
    if (!cls) return 0;
    int invoked = 0;

    jclass class_cls = env->GetObjectClass(cls);
    jmethodID get_methods = env->GetMethodID(class_cls, "getDeclaredMethods",
                                             "()[Ljava/lang/reflect/Method;");
    if (get_methods) {
        auto arr = reinterpret_cast<jobjectArray>(env->CallObjectMethod(cls, get_methods));
        if (env->ExceptionCheck()) { env->ExceptionClear(); arr = nullptr; }
        if (arr) {
            const jsize count = env->GetArrayLength(arr);
            for (jsize i = 0; i < count; ++i) {
                jobject m = env->GetObjectArrayElement(arr, i);
                if (!m) continue;
                jclass mcls = env->GetObjectClass(m);
                jmethodID get_name = env->GetMethodID(mcls, "getName", "()Ljava/lang/String;");
                jmethodID get_params = env->GetMethodID(mcls, "getParameterTypes",
                                                        "()[Ljava/lang/Class;");
                auto jname = reinterpret_cast<jstring>(env->CallObjectMethod(m, get_name));
                auto params = reinterpret_cast<jobjectArray>(env->CallObjectMethod(m, get_params));

                std::string name;
                const jsize argc = params ? env->GetArrayLength(params) : -1;
                bool wanted = false;
                if (jname && (argc == 0 || argc == 1)) {
                    const char *raw = env->GetStringUTFChars(jname, nullptr);
                    if (raw) {
                        name = raw;
                        wanted = match(tokenize(raw));
                        env->ReleaseStringUTFChars(jname, raw);
                    }
                }

                if (wanted) {
                    jmethodID setacc = env->GetMethodID(mcls, "setAccessible", "(Z)V");
                    if (setacc) env->CallVoidMethod(m, setacc, JNI_TRUE);
                    jmethodID invoke = env->GetMethodID(
                        mcls, "invoke", "(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;");
                    if (invoke) {
                        jclass obj_cls = env->FindClass("java/lang/Object");
                        jobjectArray args = env->NewObjectArray(argc, obj_cls, nullptr);
                        bool args_ready = true;
                        if (argc == 1) {
                            jclass bool_cls = env->FindClass("java/lang/Boolean");
                            jmethodID box = bool_cls ? env->GetStaticMethodID(
                                bool_cls, "valueOf", "(Z)Ljava/lang/Boolean;") : nullptr;
                            jobject boxed = box ? env->CallStaticObjectMethod(bool_cls, box, JNI_TRUE)
                                                : nullptr;
                            if (boxed) env->SetObjectArrayElement(args, 0, boxed);
                            else args_ready = false;
                            if (bool_cls) env->DeleteLocalRef(bool_cls);
                        }
                        if (args_ready) {
                            env->CallObjectMethod(m, invoke, instance, args);
                            if (env->ExceptionCheck()) {
                                env->ExceptionClear();
                            } else {
                                LOGI("[JNI_BRIDGE] %s: %s (аргументов: %d)", what, name.c_str(),
                                     static_cast<int>(argc));
                                invoked++;
                            }
                        }
                        env->DeleteLocalRef(args);
                        env->DeleteLocalRef(obj_cls);
                    }
                }
                env->DeleteLocalRef(mcls);
                env->DeleteLocalRef(m);
            }
            env->DeleteLocalRef(arr);
        }
    }
    env->DeleteLocalRef(class_cls);
    if (env->ExceptionCheck()) env->ExceptionClear();
    return invoked;
}

void pulse_ready(JNIEnv *env, jclass cls, bool force) {
    if (!cls) return;
    const uint64_t now = now_ms();
    const uint64_t last = g_last_pulse_ms.load(std::memory_order_relaxed);
    if (!force && last != 0 && now - last < 3000) return;
    g_last_pulse_ms.store(now, std::memory_order_relaxed);
    invoke_selected(env, cls, nullptr, is_availability_notification,
                    "Уведомление игры о доступности рекламы");
}

// Выдача награды: сначала начисление, затем закрытие экрана.
// Порядок обязателен: вызов только закрытия оставляет игрока без награды.
void deliver_reward(JNIEnv *env, jclass declaring, jobject instance) {
    jclass local = nullptr;
    jclass cls = declaring;
    if (!cls && instance) {
        local = reinterpret_cast<jclass>(env->GetObjectClass(instance));
        cls = local;
    }
    jclass helper = g_helper_class.load(std::memory_order_acquire);
    jclass target = cls ? cls : helper;
    if (target) {
        const int granted = invoke_selected(env, target, instance, is_reward_grant,
                                            "Начисление награды");
        invoke_selected(env, target, instance, is_reward_close, "Закрытие рекламного экрана");
        if (granted == 0) {
            LOGW("[JNI_BRIDGE] Коллбэк начисления награды в классе не найден");
        }
        pulse_ready(env, helper ? helper : target, true);
    }
    if (local) env->DeleteLocalRef(local);
}

void *ready_pulse_worker(void *) {
    JavaVM *vm = get_java_vm();
    if (!vm) return nullptr;
    JNIEnv *env = nullptr;
    if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK || !env) return nullptr;

    // Уведомление повторяется: к моменту первой попытки нативная часть игры
    // может быть ещё не готова его принять. Поток почти всё время спит.
    for (int i = 0; i < 720; ++i) {
        jclass cls = g_helper_class.load(std::memory_order_acquire);
        if (!cls) break;
        pulse_ready(env, cls, true);
        usleep(i < 12 ? 5000000 : 20000000);
    }
    vm->DetachCurrentThread();
    return nullptr;
}

bool app_has_ad_sdk(JNIEnv *env) {
    jclass at = env->FindClass("android/app/ActivityThread");
    if (!at) { env->ExceptionClear(); return false; }
    jmethodID cur = env->GetStaticMethodID(at, "currentApplication", "()Landroid/app/Application;");
    if (!cur) { env->ExceptionClear(); return false; }
    jobject app = env->CallStaticObjectMethod(at, cur);
    if (!app) { env->ExceptionClear(); return false; }

    jclass app_cls = env->GetObjectClass(app);
    jmethodID get_cl = env->GetMethodID(app_cls, "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject loader = get_cl ? env->CallObjectMethod(app, get_cl) : nullptr;
    if (!loader) { env->ExceptionClear(); return false; }

    jclass loader_cls = env->GetObjectClass(loader);
    jmethodID load = env->GetMethodID(loader_cls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    if (!load) { env->ExceptionClear(); return false; }

    static const char *const kMarkers[] = {
        "com.applovin.sdk.AppLovinSdk",
        "com.google.android.gms.ads.MobileAds",
        "com.ironsource.mediationsdk.IronSource",
        "com.unity3d.ads.UnityAds",
        "com.vungle.warren.Vungle",
        "com.vungle.ads.VungleAds",
        "com.mbridge.msdk.MBridgeSDK",
        "com.yandex.mobile.ads.common.MobileAds",
        "com.facebook.ads.AudienceNetworkAds",
        "com.chartboost.sdk.Chartboost"
    };
    bool found = false;
    for (const char *marker : kMarkers) {
        jstring name = env->NewStringUTF(marker);
        jobject cls = env->CallObjectMethod(loader, load, name);
        if (env->ExceptionCheck()) env->ExceptionClear();
        else if (cls) { LOGI("[JNI_BRIDGE] Обнаружен рекламный SDK: %s", marker); found = true; }
        if (cls) env->DeleteLocalRef(cls);
        env->DeleteLocalRef(name);
        if (found) break;
    }
    return found;
}

// --- Замещающие функции таблицы JNI -----------------------------------------
//
// Варианты с многоточием пересылаются в оригинальные варианты с va_list:
// восстановить «...» из va_list невозможно, а вариант с va_list в таблице есть.

jboolean call_static_boolean_v(JNIEnv *env, jclass cls, jmethodID mid, va_list args) {
    if (kind_of(env, cls, nullptr, mid, true, 'Z') == Kind::ReadyQuery) {
        g_ready_hits.fetch_add(1, std::memory_order_relaxed);
        return JNI_TRUE;
    }
    return g_orig.CallStaticBooleanMethodV(env, cls, mid, args);
}
jboolean call_static_boolean(JNIEnv *env, jclass cls, jmethodID mid, ...) {
    va_list a; va_start(a, mid);
    jboolean r = call_static_boolean_v(env, cls, mid, a);
    va_end(a);
    return r;
}
jboolean call_static_boolean_a(JNIEnv *env, jclass cls, jmethodID mid, const jvalue *args) {
    if (kind_of(env, cls, nullptr, mid, true, 'Z') == Kind::ReadyQuery) {
        g_ready_hits.fetch_add(1, std::memory_order_relaxed);
        return JNI_TRUE;
    }
    return g_orig.CallStaticBooleanMethodA(env, cls, mid, args);
}

jboolean call_boolean_v(JNIEnv *env, jobject obj, jmethodID mid, va_list args) {
    if (kind_of(env, nullptr, obj, mid, false, 'Z') == Kind::ReadyQuery) {
        g_ready_hits.fetch_add(1, std::memory_order_relaxed);
        return JNI_TRUE;
    }
    return g_orig.CallBooleanMethodV(env, obj, mid, args);
}
jboolean call_boolean(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    va_list a; va_start(a, mid);
    jboolean r = call_boolean_v(env, obj, mid, a);
    va_end(a);
    return r;
}
jboolean call_boolean_a(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *args) {
    if (kind_of(env, nullptr, obj, mid, false, 'Z') == Kind::ReadyQuery) {
        g_ready_hits.fetch_add(1, std::memory_order_relaxed);
        return JNI_TRUE;
    }
    return g_orig.CallBooleanMethodA(env, obj, mid, args);
}

void call_static_void_v(JNIEnv *env, jclass cls, jmethodID mid, va_list args) {
    if (kind_of(env, cls, nullptr, mid, true, 'V') == Kind::ShowVoid) {
        g_show_hits.fetch_add(1, std::memory_order_relaxed);
        deliver_reward(env, cls, nullptr);
        return;
    }
    g_orig.CallStaticVoidMethodV(env, cls, mid, args);
}
void call_static_void(JNIEnv *env, jclass cls, jmethodID mid, ...) {
    va_list a; va_start(a, mid); call_static_void_v(env, cls, mid, a); va_end(a);
}
void call_static_void_a(JNIEnv *env, jclass cls, jmethodID mid, const jvalue *args) {
    if (kind_of(env, cls, nullptr, mid, true, 'V') == Kind::ShowVoid) {
        g_show_hits.fetch_add(1, std::memory_order_relaxed);
        deliver_reward(env, cls, nullptr);
        return;
    }
    g_orig.CallStaticVoidMethodA(env, cls, mid, args);
}

void call_void_v(JNIEnv *env, jobject obj, jmethodID mid, va_list args) {
    if (kind_of(env, nullptr, obj, mid, false, 'V') == Kind::ShowVoid) {
        g_show_hits.fetch_add(1, std::memory_order_relaxed);
        deliver_reward(env, nullptr, obj);
        return;
    }
    g_orig.CallVoidMethodV(env, obj, mid, args);
}
void call_void(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    va_list a; va_start(a, mid); call_void_v(env, obj, mid, a); va_end(a);
}
void call_void_a(JNIEnv *env, jobject obj, jmethodID mid, const jvalue *args) {
    if (kind_of(env, nullptr, obj, mid, false, 'V') == Kind::ShowVoid) {
        g_show_hits.fetch_add(1, std::memory_order_relaxed);
        deliver_reward(env, nullptr, obj);
        return;
    }
    g_orig.CallVoidMethodA(env, obj, mid, args);
}

// Показ, возвращающий номер запроса, и последующий опрос результата.
//
// Игра создаёт запрос на показ, получает его номер и затем периодически
// спрашивает статус. Модуль возвращает собственный номер, а на опрос по нему
// отвечает «успешно завершён».
jint call_static_int_v(JNIEnv *env, jclass cls, jmethodID mid, va_list args) {
    const Kind kind = kind_of(env, cls, nullptr, mid, true, 'I');
    if (kind == Kind::ShowInt) {
        g_show_hits.fetch_add(1, std::memory_order_relaxed);
        deliver_reward(env, cls, nullptr);
        return kSentinelRequestId;
    }
    if (kind == Kind::StatusQuery) {
        va_list copy;
        va_copy(copy, args);
        const jint id = va_arg(copy, jint);
        va_end(copy);
        if (id == kSentinelRequestId) return kRequestStatusDone;
    }
    return g_orig.CallStaticIntMethodV(env, cls, mid, args);
}
jint call_static_int(JNIEnv *env, jclass cls, jmethodID mid, ...) {
    va_list a; va_start(a, mid);
    jint r = call_static_int_v(env, cls, mid, a);
    va_end(a);
    return r;
}

jint call_int_v(JNIEnv *env, jobject obj, jmethodID mid, va_list args) {
    const Kind kind = kind_of(env, nullptr, obj, mid, false, 'I');
    if (kind == Kind::ShowInt) {
        g_show_hits.fetch_add(1, std::memory_order_relaxed);
        deliver_reward(env, nullptr, obj);
        return kSentinelRequestId;
    }
    if (kind == Kind::StatusQuery) {
        va_list copy;
        va_copy(copy, args);
        const jint id = va_arg(copy, jint);
        va_end(copy);
        if (id == kSentinelRequestId) return kRequestStatusDone;
    }
    return g_orig.CallIntMethodV(env, obj, mid, args);
}
jint call_int(JNIEnv *env, jobject obj, jmethodID mid, ...) {
    va_list a; va_start(a, mid);
    jint r = call_int_v(env, obj, mid, a);
    va_end(a);
    return r;
}

} // namespace

bool install_jni_bridge_hook(JNIEnv *env, const char *package_name) {
    static std::mutex s_mutex;
    std::lock_guard<std::mutex> lock(s_mutex);
    if (g_installed) return true;
    if (!env || !env->functions) return false;

    g_package = package_name ? package_name : "";
    {
        // Пространство имён приложения: первые две части имени пакета.
        // com.notdoppler.earntodie2 -> com.notdoppler
        const std::string lower = to_lower(g_package);
        const size_t first = lower.find('.');
        const size_t second = (first == std::string::npos) ? std::string::npos
                                                           : lower.find('.', first + 1);
        g_vendor_prefix = (second == std::string::npos) ? lower : lower.substr(0, second);
    }
    if (g_vendor_prefix.empty()) return false;

    if (!app_has_ad_sdk(env)) {
        LOGI("[JNI_BRIDGE] Рекламных SDK в %s не найдено; перехват не требуется", g_package.c_str());
        return false;
    }

    auto *table = const_cast<JNINativeInterface *>(env->functions);
    memcpy(&g_orig, table, sizeof(JNINativeInterface));

    // Таблица функций — это данные, а не код: право на исполнение не
    // запрашивается, иначе ядро отклонит изменение прав страницы.
    const long ps = sysconf(_SC_PAGESIZE) > 0 ? sysconf(_SC_PAGESIZE) : 4096;
    const auto start = reinterpret_cast<uintptr_t>(table) & ~static_cast<uintptr_t>(ps - 1);
    const auto end = (reinterpret_cast<uintptr_t>(table) + sizeof(JNINativeInterface) +
                      static_cast<uintptr_t>(ps) - 1) & ~static_cast<uintptr_t>(ps - 1);
    if (mprotect(reinterpret_cast<void *>(start), end - start, PROT_READ | PROT_WRITE) != 0) {
        LOGW("[JNI_BRIDGE] Таблица JNI недоступна для записи (%s)", strerror(errno));
        return false;
    }

    table->CallStaticBooleanMethod  = call_static_boolean;
    table->CallStaticBooleanMethodV = call_static_boolean_v;
    table->CallStaticBooleanMethodA = call_static_boolean_a;
    table->CallBooleanMethod        = call_boolean;
    table->CallBooleanMethodV       = call_boolean_v;
    table->CallBooleanMethodA       = call_boolean_a;
    table->CallStaticVoidMethod     = call_static_void;
    table->CallStaticVoidMethodV    = call_static_void_v;
    table->CallStaticVoidMethodA    = call_static_void_a;
    table->CallVoidMethod           = call_void;
    table->CallVoidMethodV          = call_void_v;
    table->CallVoidMethodA          = call_void_a;
    table->CallStaticIntMethod      = call_static_int;
    table->CallStaticIntMethodV     = call_static_int_v;
    table->CallIntMethod            = call_int;
    table->CallIntMethodV           = call_int_v;

    mprotect(reinterpret_cast<void *>(start), end - start, PROT_READ);

    g_installed = true;
    LOGI("[JNI_BRIDGE] Перехват границы нативный код -> Java установлен для %s", g_package.c_str());
    return true;
}

void log_jni_bridge_activity(bool force) {
    static std::mutex s_mutex;
    static uint64_t s_last = UINT64_MAX;
    std::lock_guard<std::mutex> lock(s_mutex);
    if (!g_installed) return;

    const uint64_t ready = g_ready_hits.load(std::memory_order_relaxed);
    const uint64_t show = g_show_hits.load(std::memory_order_relaxed);
    const uint64_t total = ready + show;
    if (!force && total == s_last) return;
    s_last = total;

    LOGI("[JNI_BRIDGE] разобрано методов=%llu | готовность: срабатываний=%llu | показ: срабатываний=%llu",
         static_cast<unsigned long long>(g_resolved.load(std::memory_order_relaxed)),
         static_cast<unsigned long long>(ready),
         static_cast<unsigned long long>(show));
}

} // namespace smartreward
