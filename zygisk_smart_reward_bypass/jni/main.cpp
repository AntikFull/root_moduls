#include "zygisk.hpp"
#include "core/log.hpp"
#include "core/target_filter.hpp"
#include "core/java_loader.hpp"
#include "core/il2cpp_api.hpp"
#include "core/config.hpp"
#include "discovery/report_writer.hpp"

#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <string>
#include <pthread.h>

namespace {

void companion_handler(int socket) {
    if (socket >= 0) {
        close(socket);
    }
}

class SmartRewardModule final : public zygisk::ModuleBase {
public:
    void onLoad(zygisk::Api *api, JNIEnv *env) override {
        api_ = api;
        env_ = env;
        if (env) {
            JavaVM *jvm = nullptr;
            env->GetJavaVM(&jvm);
            if (jvm) {
                smartreward::set_java_vm(jvm);
            }
        }
    }

    void preAppSpecialize(zygisk::AppSpecializeArgs *args) override {
        active_ = false;
        process_name_.clear();
        app_data_dir_.clear();
        uid_ = 0;

        if (!args || args->uid < 10000) {
            return;
        }

        char pkg[128] = {0};
        if (env_ && args->nice_name) {
            const char *raw = env_->GetStringUTFChars(args->nice_name, nullptr);
            if (raw) {
                strncpy(pkg, raw, sizeof(pkg) - 1);
                env_->ReleaseStringUTFChars(args->nice_name, raw);
            }
        }
        if (env_ && args->app_data_dir) {
            const char *dir = env_->GetStringUTFChars(args->app_data_dir, nullptr);
            if (dir) {
                app_data_dir_ = dir;
                if (!pkg[0]) {
                    const char *last_slash = strrchr(dir, '/');
                    if (last_slash) strncpy(pkg, last_slash + 1, sizeof(pkg) - 1);
                }
                env_->ReleaseStringUTFChars(args->app_data_dir, dir);
            }
        }

        if (!pkg[0] || smartreward::is_protected_process(pkg, args->uid) || !smartreward::is_target_process(pkg)) {
            return;
        }

        // Кэшируем правила из конфигурационного файла, пока работает от имени root
        smartreward::g_cached_rules = smartreward::load_hook_rules();

        active_ = true;
        process_name_ = pkg;
        uid_ = args->uid;
    }

    void postAppSpecialize(const zygisk::AppSpecializeArgs *) override {
        if (!active_) {
            if (api_) api_->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        if (process_name_.empty()) {
            int fd = open("/proc/self/cmdline", O_RDONLY | O_CLOEXEC);
            if (fd >= 0) {
                char buf[128] = {0};
                ssize_t r = read(fd, buf, sizeof(buf) - 1);
                close(fd);
                if (r > 0) {
                    buf[r] = '\0';
                    process_name_ = buf;
                }
            }
        }

        if (smartreward::is_protected_process(process_name_.c_str(), uid_)) return;

        smartreward::log_session_start(process_name_.c_str(), getpid());
        LOGI("[INJECT] SmartReward Zygisk successfully injected into target process: %s (PID=%d)",
             process_name_.c_str(), static_cast<int>(getpid()));

        // Create/update a durable per-package profile even when the app is Java/Kotlin-only.
        smartreward::ReportWriter::initialize_process(process_name_, process_name_, app_data_dir_);

        // Запуск Java DEX In-Memory загрузчика
        auto java_ctx = new smartreward::WorkerContext{process_name_, uid_};
        pthread_t jth{};
        if (pthread_create(&jth, nullptr, smartreward::java_dex_loader_worker, java_ctx) == 0) {
            pthread_detach(jth);
        } else {
            delete java_ctx;
            LOGE("Failed to spawn Java DEX loader thread");
        }

        // Запуск воркера детекции игровых движков и IL2CPP резолвера
        auto engine_ctx = new smartreward::WorkerContext{process_name_, uid_};
        pthread_t eth{};
        if (pthread_create(&eth, nullptr, smartreward::engine_probe_worker, engine_ctx) == 0) {
            pthread_detach(eth);
        } else {
            delete engine_ctx;
            LOGE("Failed to spawn Engine Probe worker thread");
        }
    }

    void preServerSpecialize(zygisk::ServerSpecializeArgs *) override {}

private:
    zygisk::Api *api_ = nullptr;
    JNIEnv *env_ = nullptr;
    bool active_ = false;
    std::string process_name_;
    std::string app_data_dir_;
    jint uid_ = 0;
};

} // namespace

REGISTER_ZYGISK_MODULE(SmartRewardModule)
REGISTER_ZYGISK_COMPANION(companion_handler)
