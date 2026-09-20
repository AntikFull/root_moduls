#include "java_loader.hpp"
#include "smart_reward_dex.h"
#include "log.hpp"
#include "engine_probe.hpp"
#include "il2cpp_api.hpp"
#include "jni_bridge_hook.hpp"

#include <unistd.h>
#include <memory>

namespace smartreward {

extern "C" {
JNIEXPORT void JNICALL Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeNotifyUnityReward(
        JNIEnv *env, jclass, jstring j_obj, jstring j_meth, jstring j_msg);
JNIEXPORT jlong JNICALL Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeStartRewardTrace(
        JNIEnv *env, jclass, jstring j_pkg, jstring j_proc, jstring j_eng, jstring j_sdk, jstring j_plc, jint conf);
JNIEXPORT void JNICALL Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeRecordRewardStage(
        JNIEnv *env, jclass, jlong j_tid, jint j_stage, jint j_fail, jstring j_detail);
JNIEXPORT void JNICALL Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeRecordReadyCheck(
        JNIEnv *env, jclass, jstring j_sdk, jstring j_fmt, jstring j_plc,
        jstring j_cls, jstring j_mth, jboolean j_val, jint j_reason);
}

namespace {
    JavaVM *g_jvm = nullptr;
}

void set_java_vm(JavaVM *jvm) {
    g_jvm = jvm;
}

JavaVM *get_java_vm() {
    return g_jvm;
}

void *java_dex_loader_worker(void *arg) {
    std::unique_ptr<WorkerContext> ctx(reinterpret_cast<WorkerContext *>(arg));
    const std::string process_name = ctx ? ctx->process_name : "unknown";

    if (!g_jvm) {
        LOGW("JavaVM is null in java_dex_loader_worker");
        return nullptr;
    }

    JNIEnv *env = nullptr;
    if (g_jvm->AttachCurrentThread(&env, nullptr) != JNI_OK || !env) {
        LOGE("Failed to attach JNI thread to JavaVM for process %s", process_name.c_str());
        return nullptr;
    }

    jclass act_thread = nullptr;
    jmethodID cur_app = nullptr;
    jobject app = nullptr;

    for (int i = 0; i < 50; ++i) {
        act_thread = env->FindClass("android/app/ActivityThread");
        if (act_thread) {
            cur_app = env->GetStaticMethodID(act_thread, "currentApplication", "()Landroid/app/Application;");
            if (cur_app) {
                app = env->CallStaticObjectMethod(act_thread, cur_app);
                if (app) break;
            }
        }
        env->ExceptionClear();
        usleep(100000);
    }

    if (!app) {
        LOGW("Failed to obtain currentApplication() after timeout in %s", process_name.c_str());
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    jclass byte_buf_class = env->FindClass("java/nio/ByteBuffer");
    if (!byte_buf_class) {
        LOGE("Failed to find java/nio/ByteBuffer");
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    jmethodID wrap_mid = env->GetStaticMethodID(byte_buf_class, "wrap", "([B)Ljava/nio/ByteBuffer;");
    if (!wrap_mid) {
        LOGE("Failed to get ByteBuffer.wrap method");
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    jbyteArray byte_array = env->NewByteArray(SMART_REWARD_DEX_SIZE);
    if (!byte_array) {
        LOGE("Failed to allocate byte array for in-memory DEX");
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    env->SetByteArrayRegion(byte_array, 0, SMART_REWARD_DEX_SIZE, reinterpret_cast<const jbyte *>(SMART_REWARD_DEX_BYTES));
    jobject byte_buf = env->CallStaticObjectMethod(byte_buf_class, wrap_mid, byte_array);
    env->DeleteLocalRef(byte_array);

    if (!byte_buf) {
        LOGE("Failed to create ByteBuffer from DEX bytes");
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    jclass cl_class = env->FindClass("dalvik/system/InMemoryDexClassLoader");
    if (!cl_class) {
        LOGE("Failed to find dalvik/system/InMemoryDexClassLoader");
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    jmethodID cl_init = env->GetMethodID(cl_class, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V");
    if (!cl_init) {
        LOGE("Failed to get InMemoryDexClassLoader constructor");
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    jclass app_class = env->GetObjectClass(app);
    jmethodID get_cl = env->GetMethodID(app_class, "getClassLoader", "()Ljava/lang/ClassLoader;");
    if (!get_cl) {
        LOGE("Failed to get getClassLoader method from Application");
        g_jvm->DetachCurrentThread();
        return nullptr;
    }

    jobject parent_cl = env->CallObjectMethod(app, get_cl);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        parent_cl = nullptr;
    }

    jobject dex_cl = env->NewObject(cl_class, cl_init, byte_buf, parent_cl);
    if (dex_cl) {
        jmethodID load_cls = env->GetMethodID(cl_class, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
        jstring cls_str = env->NewStringUTF("ecubz.smartreward.zygisk.SmartRewardCore");
        jclass core_cls = reinterpret_cast<jclass>(env->CallObjectMethod(dex_cl, load_cls, cls_str));
        if (core_cls) {
            static const JNINativeMethod g_methods[] = {
                {const_cast<char *>("nativeNotifyUnityReward"),
                 const_cast<char *>("(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"),
                 reinterpret_cast<void *>(&Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeNotifyUnityReward)},
                {const_cast<char *>("nativeStartRewardTrace"),
                 const_cast<char *>("(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;I)J"),
                 reinterpret_cast<void *>(&Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeStartRewardTrace)},
                {const_cast<char *>("nativeRecordRewardStage"),
                 const_cast<char *>("(JIILjava/lang/String;)V"),
                 reinterpret_cast<void *>(&Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeRecordRewardStage)},
                {const_cast<char *>("nativeRecordReadyCheck"),
                 const_cast<char *>("(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ZI)V"),
                 reinterpret_cast<void *>(&Java_ecubz_smartreward_zygisk_SmartRewardCore_nativeRecordReadyCheck)}
            };
            if (env->RegisterNatives(core_cls, g_methods, sizeof(g_methods) / sizeof(g_methods[0])) != JNI_OK) {
                env->ExceptionClear();
                LOGE("[JAVA_LOADER] RegisterNatives failed for SmartRewardCore; telemetry and native reward bridges disabled");
            } else {
                LOGI("[JAVA_LOADER] Successfully registered %zu native JNI methods in SmartRewardCore",
                     sizeof(g_methods) / sizeof(g_methods[0]));
            }

            jmethodID init_m = env->GetStaticMethodID(core_cls, "init", "(Landroid/app/Application;)Z");
            if (init_m) {
                jboolean res = env->CallStaticBooleanMethod(core_cls, init_m, app);
                LOGI("[SMART_REWARD] In-Memory Java core successfully launched in %s (init result=%d)",
                     process_name.c_str(), res);
            }
        }
    }

    env->ExceptionClear();
    g_jvm->DetachCurrentThread();
    return nullptr;
}

void *engine_probe_worker(void *arg) {
    std::unique_ptr<WorkerContext> ctx(reinterpret_cast<WorkerContext *>(arg));
    const std::string process_name = ctx ? ctx->process_name : "unknown";

    LOGI("[ENGINE_PROBE] Starting adaptive engine detection & IL2CPP resolution for %s", process_name.c_str());

    EngineState state;
    bool il2cpp_resolved = false;

    // Адаптивное трехфазное окно опроса:
    // Фаза 1: 25 итераций по 200 мс (0..5 сек) - быстрый старт
    // Фаза 2: 20 итераций по 500 мс (5..15 сек) - splash / login экраны
    // Фаза 3: 20 итераций по 2000 мс (15..55 сек) - поздняя докачка ассетов / hot-update
    for (int i = 0; i < 65; ++i) {
        probe_native_engines(state);

        if (state.unity_il2cpp && !il2cpp_resolved) {
            ResolveStatus status = Il2CppResolver::instance().probe_and_resolve(process_name);
            if (status == ResolveStatus::Success) {
                il2cpp_resolved = true;
                LOGI("[ENGINE_PROBE] IL2CPP successfully resolved on iteration %d; monitoring for dynamic assemblies", i);
            } else if (status == ResolveStatus::FatalError) {
                LOGW("[ENGINE_PROBE] IL2CPP resolution encountered fatal error; aborting retry");
                break;
            }
            // Если RuntimeNotReady — повторяем попытку
        }

        // Игры на нативных движках (Cocos2d-x, LOVE 2D, Unreal) не содержат
        // C#-кода: рекламная логика у них в Java, а обращается к ней игровой
        // код через JNI. Для них включается перехват границы JNI.
        //
        // Порог в 30 итераций (~7 секунд) выбран с запасом: Unity подгружает
        // libil2cpp на старте, поэтому к этому моменту движок уже определён.
        // Для Unity-игр перехват не ставится: там работает слой IL2CPP, и
        // трогать таблицу JNI без необходимости не нужно.
        if (i == 30 && !state.unity_il2cpp && !il2cpp_resolved) {
            JavaVM *vm = get_java_vm();
            JNIEnv *jni = nullptr;
            if (vm && vm->AttachCurrentThread(&jni, nullptr) == JNI_OK && jni) {
                LOGI("[ENGINE_PROBE] C#-код не обнаружен; включается перехват границы JNI");
                install_jni_bridge_hook(jni, process_name.c_str());
            }
        }

        if (il2cpp_resolved) {
            usleep(2000000);
            // Проверка появления новых динамических сборок (hot-update / asset download)
            Il2CppResolver::instance().check_and_rescan_assemblies(process_name);
            // Сводка выводится только при изменении счётчиков, поэтому лог не засоряется
            log_hook_activity(false);
            continue;
        }

        if (i < 25) {
            usleep(200000);
        } else if (i < 45) {
            usleep(500000);
        } else {
            usleep(2000000);
        }
    }

    if (!il2cpp_resolved) {
        // Наблюдение за перехватом JNI в играх на нативных движках.
        log_jni_bridge_activity(true);
        for (int beat = 0; beat < 120; ++beat) {
            usleep(30000000);
            log_jni_bridge_activity(false);
        }
        return nullptr;
    }

    if (il2cpp_resolved) {
        // Итоговая сводка после окна установки перехватов.
        log_hook_activity(true);

        // Дальнейшее наблюдение: поток спит и печатает строку только тогда,
        // когда счётчики срабатываний изменились. Нагрузки на процессор нет.
        for (int beat = 0; beat < 120; ++beat) {
            usleep(30000000);
            log_hook_activity(false);
            log_jni_bridge_activity(false);
        }
    }

    return nullptr;
}

} // namespace smartreward
