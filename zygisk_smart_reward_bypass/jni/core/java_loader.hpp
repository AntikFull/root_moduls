#pragma once

#include <jni.h>
#include <string>
#include <memory>

namespace smartreward {

struct WorkerContext {
    std::string process_name;
    jint uid = 0;
};

void set_java_vm(JavaVM *jvm);
JavaVM *get_java_vm();

void *java_dex_loader_worker(void *arg);
void *engine_probe_worker(void *arg);

} // namespace smartreward
