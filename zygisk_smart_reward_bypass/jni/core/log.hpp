#pragma once

#include <android/log.h>
#include <unistd.h>
#include <cstdio>

#define LOG_TAG "SmartReward-Engine"

#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)

namespace smartreward {

inline void log_session_start(const char *process_name, pid_t pid) {
    LOGI("========== process-start package=%s pid=%d ==========", 
         process_name ? process_name : "unknown", 
         static_cast<int>(pid));
}

} // namespace smartreward
