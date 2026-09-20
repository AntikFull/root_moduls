#include "managed_invoker.hpp"
#include "../../core/log.hpp"
#include "../../core/safe_memory.hpp"

#include <dlfcn.h>

namespace smartreward {

ManagedInvoker &ManagedInvoker::instance() {
    static ManagedInvoker s_instance;
    return s_instance;
}

void ManagedInvoker::bind(void *handle) {
    if (ready_ || !handle) return;

    runtime_invoke_ = reinterpret_cast<il2cpp_runtime_invoke_t>(dlsym(handle, "il2cpp_runtime_invoke"));
    object_new_ = reinterpret_cast<il2cpp_object_new_t>(dlsym(handle, "il2cpp_object_new"));
    string_new_ = reinterpret_cast<il2cpp_string_new_t>(dlsym(handle, "il2cpp_string_new"));
    object_get_class_ = reinterpret_cast<il2cpp_object_get_class_t>(dlsym(handle, "il2cpp_object_get_class"));
    class_get_field_ = reinterpret_cast<il2cpp_class_get_field_from_name_t>(
        dlsym(handle, "il2cpp_class_get_field_from_name"));
    field_get_value_ = reinterpret_cast<il2cpp_field_get_value_t>(dlsym(handle, "il2cpp_field_get_value"));
    field_set_value_ = reinterpret_cast<il2cpp_field_set_value_t>(dlsym(handle, "il2cpp_field_set_value"));
    field_static_get_value_ = reinterpret_cast<il2cpp_field_static_get_value_t>(
        dlsym(handle, "il2cpp_field_static_get_value"));
    class_get_method_ = reinterpret_cast<il2cpp_class_get_method_from_name_t>(
        dlsym(handle, "il2cpp_class_get_method_from_name"));
    class_get_name_ = reinterpret_cast<il2cpp_class_get_name_t>(dlsym(handle, "il2cpp_class_get_name"));
    class_from_type_ = reinterpret_cast<il2cpp_class_from_type_t>(dlsym(handle, "il2cpp_class_from_type"));
    method_get_param_ = reinterpret_cast<il2cpp_method_get_param_t>(dlsym(handle, "il2cpp_method_get_param"));

    ready_ = (runtime_invoke_ != nullptr && string_new_ != nullptr && object_get_class_ != nullptr &&
              class_get_method_ != nullptr);

    LOGI("[MANAGED] Вызов управляемого кода: %s (invoke=%d new=%d string=%d field=%d)",
         ready_ ? "доступен" : "НЕДОСТУПЕН", runtime_invoke_ != nullptr, object_new_ != nullptr,
         string_new_ != nullptr, class_get_field_ != nullptr);
}

Il2CppString *ManagedInvoker::make_string(const std::string &utf8) const {
    if (!string_new_) return nullptr;
    return string_new_(utf8.c_str());
}

bool ManagedInvoker::invoke(const MethodInfo *method, void *obj, void **params) const {
    if (!ready_ || !method) return false;

    Il2CppException *exc = nullptr;
    runtime_invoke_(method, obj, params, &exc);
    if (exc) {
        // Исключение управляемого кода поглощается: оно не должно всплывать
        // в игровой код через наш перехват.
        LOGW("[MANAGED] Управляемый вызов завершился исключением; оно поглощено");
        return false;
    }
    return true;
}

Il2CppObject *ManagedInvoker::invoke_object(const MethodInfo *method, void *obj, void **params,
                                            bool *success) const {
    if (success) *success = false;
    if (!ready_ || !method) return nullptr;

    Il2CppException *exc = nullptr;
    Il2CppObject *result = runtime_invoke_(method, obj, params, &exc);
    if (exc) {
        LOGW("[MANAGED] Управляемый вызов с результатом завершился исключением; оно поглощено");
        return nullptr;
    }
    if (success) *success = true;
    return result;
}

Il2CppObject *ManagedInvoker::new_object(Il2CppClass *klass) const {
    if (!object_new_ || !klass) return nullptr;
    return object_new_(klass);
}

Il2CppClass *ManagedInvoker::class_of(void *obj) const {
    if (!object_get_class_ || !obj) return nullptr;
    if (!is_readable_memory(obj, sizeof(void *) * 2)) return nullptr;
    return object_get_class_(reinterpret_cast<Il2CppObject *>(obj));
}

const Il2CppType *ManagedInvoker::param_type(const MethodInfo *method, int index) const {
    if (!method_get_param_ || !method || index < 0) return nullptr;
    return method_get_param_(method, static_cast<uint32_t>(index));
}

Il2CppClass *ManagedInvoker::class_from_type(const Il2CppType *type) const {
    if (!class_from_type_ || !type) return nullptr;
    return class_from_type_(type);
}

void *ManagedInvoker::read_object_field(void *obj, const char *field_name) const {
    if (!class_get_field_ || !field_get_value_ || !obj || !field_name) return nullptr;
    Il2CppClass *klass = class_of(obj);
    if (!klass) return nullptr;

    FieldInfo *field = class_get_field_(klass, field_name);
    if (!field) return nullptr;

    void *value = nullptr;
    field_get_value_(reinterpret_cast<Il2CppObject *>(obj), field, &value);
    return value;
}

bool ManagedInvoker::write_field(void *obj, const char *field_name, void *value_ptr) const {
    if (!class_get_field_ || !field_set_value_ || !obj || !field_name || !value_ptr) return false;
    Il2CppClass *klass = class_of(obj);
    if (!klass) return false;
    FieldInfo *field = class_get_field_(klass, field_name);
    if (!field) return false;
    field_set_value_(reinterpret_cast<Il2CppObject *>(obj), field, value_ptr);
    return true;
}

bool ManagedInvoker::read_enum_constant(Il2CppClass *enum_class, const char *name, int32_t *out) const {
    if (!class_get_field_ || !field_static_get_value_ || !enum_class || !name || !out) return false;
    FieldInfo *field = class_get_field_(enum_class, name);
    if (!field) return false;
    int32_t value = 0;
    field_static_get_value_(field, &value);
    *out = value;
    return true;
}

const MethodInfo *ManagedInvoker::find_method(Il2CppClass *klass, const char *name, int argc) const {
    if (!class_get_method_ || !klass || !name) return nullptr;
    return class_get_method_(klass, name, argc);
}

bool ManagedInvoker::invoke_delegate(void *delegate_obj, void **params, int argc) const {
    if (!ready_ || !delegate_obj) return false;

    Il2CppClass *klass = class_of(delegate_obj);
    if (!klass) return false;

    // У любого делегата есть метод Invoke с сигнатурой самого делегата.
    const MethodInfo *invoke_method = find_method(klass, "Invoke", argc);
    if (!invoke_method) {
        LOGW("[MANAGED] У делегата %s нет Invoke с %d аргументом(ами)",
             class_get_name_ ? class_get_name_(klass) : "?", argc);
        return false;
    }
    return invoke(invoke_method, delegate_obj, params);
}

} // namespace smartreward
