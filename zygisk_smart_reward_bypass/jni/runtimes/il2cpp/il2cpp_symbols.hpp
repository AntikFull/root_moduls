#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

namespace smartreward {

struct Il2CppDomain;
struct Il2CppAssembly;
struct Il2CppImage;
struct Il2CppClass;
struct Il2CppType;
struct Il2CppObject;
struct Il2CppString;
struct Il2CppThread;

enum class ResolveStatus {
    Success,
    NotIl2Cpp,
    RuntimeNotReady,
    FatalError
};

typedef void (*Il2CppMethodPointer)();

struct MethodInfo {
    Il2CppMethodPointer methodPointer;
    void *invoker_method;
    const char *name;
    Il2CppClass *klass;
    const Il2CppType *return_type;
    const void *parameters;
};

// Typedefs для всех стандартных экспортов libil2cpp.so
using il2cpp_domain_get_t = Il2CppDomain *(*)();
using il2cpp_domain_get_assemblies_t = const Il2CppAssembly **(*)(const Il2CppDomain *, size_t *);
using il2cpp_assembly_get_image_t = const Il2CppImage *(*)(const Il2CppAssembly *);
using il2cpp_image_get_name_t = const char *(*)(const Il2CppImage *);
using il2cpp_image_get_class_count_t = size_t (*)(const Il2CppImage *);
using il2cpp_image_get_class_t = Il2CppClass *(*)(const Il2CppImage *, size_t);

using il2cpp_thread_attach_t = Il2CppThread *(*)(Il2CppDomain *);
using il2cpp_thread_detach_t = void (*)(Il2CppThread *);
using il2cpp_thread_current_t = Il2CppThread *(*)();
using il2cpp_is_vm_thread_t = bool (*)();

using il2cpp_class_get_name_t = const char *(*)(Il2CppClass *);
using il2cpp_class_get_namespace_t = const char *(*)(Il2CppClass *);
using il2cpp_class_from_name_t = Il2CppClass *(*)(const Il2CppImage *, const char *, const char *);
using il2cpp_class_get_methods_t = const MethodInfo *(*)(Il2CppClass *, void **);
using il2cpp_class_get_method_from_name_t = const MethodInfo *(*)(Il2CppClass *, const char *, int);
using il2cpp_class_get_parent_t = Il2CppClass *(*)(Il2CppClass *);
using il2cpp_class_is_subclass_of_t = bool (*)(Il2CppClass *, Il2CppClass *, bool);

using il2cpp_method_get_name_t = const char *(*)(const MethodInfo *);
using il2cpp_method_get_param_count_t = uint32_t (*)(const MethodInfo *);
using il2cpp_method_get_param_t = const Il2CppType *(*)(const MethodInfo *, uint32_t);
using il2cpp_method_get_return_type_t = const Il2CppType *(*)(const MethodInfo *);
using il2cpp_method_get_flags_t = uint32_t (*)(const MethodInfo *, uint32_t *);

using il2cpp_type_get_type_t = int (*)(const Il2CppType *);
using il2cpp_type_get_name_t = char *(*)(const Il2CppType *);
using il2cpp_free_t = void (*)(void *);

using il2cpp_string_chars_t = const uint16_t *(*)(Il2CppString *);
// Создание управляемой строки из UTF-8. Требуется для передачи событий
// рекламного SDK обратно в C#-код игры.
using il2cpp_string_new_t = Il2CppString *(*)(const char *);

// ---------------------------------------------------------------------------
// Штатный механизм вызова управляемого кода.
//
// il2cpp_runtime_invoke сам подбирает корректный invoker для сигнатуры метода,
// поэтому вызов не зависит от ручного приведения указателей на функции и не
// ломает соглашение о вызове при неожиданных типах аргументов.
// ---------------------------------------------------------------------------
struct Il2CppObject;
struct Il2CppException;
struct FieldInfo;

using il2cpp_runtime_invoke_t = Il2CppObject *(*)(const MethodInfo *method, void *obj,
                                                  void **params, Il2CppException **exc);
using il2cpp_object_new_t = Il2CppObject *(*)(Il2CppClass *klass);
using il2cpp_class_get_field_from_name_t = FieldInfo *(*)(Il2CppClass *klass, const char *name);
using il2cpp_field_get_value_t = void (*)(Il2CppObject *obj, FieldInfo *field, void *value);
using il2cpp_value_box_t = Il2CppObject *(*)(Il2CppClass *klass, void *data);
using il2cpp_field_set_value_t = void (*)(Il2CppObject *obj, FieldInfo *field, void *value);
using il2cpp_field_static_get_value_t = void (*)(FieldInfo *field, void *value);
using il2cpp_class_from_type_t = Il2CppClass *(*)(const Il2CppType *type);
using il2cpp_string_length_t = int32_t (*)(Il2CppString *);
using il2cpp_object_get_class_t = Il2CppClass *(*)(Il2CppObject *);

using UnitySendMessage_t = void (*)(const char *, const char *, const char *);

enum class ConfidenceTier {
    SdkConfirmed = 1,
    AdSemantic = 2,
    HeuristicOnly = 3
};

// Унифицированный дескриптор метода в метадата-индексе
struct MethodDescriptor {
    const MethodInfo *method_ptr = nullptr;
    std::string assembly;
    std::string name_space;
    std::string class_name;
    std::string method_name;
    bool is_static = false;
    std::string return_type;
    uint32_t param_count = 0;
    std::vector<std::string> param_types;
    uint32_t lexical_score = 0;
    uint32_t signature_score = 0;
    uint32_t sdk_score = 0;
    uint32_t total_score = 0;
    ConfidenceTier confidence_tier = ConfidenceTier::HeuristicOnly;
};

// Матрица возможностей экспортов IL2CPP (Capability Matrix)
struct Il2CppCapabilityMatrix {
    bool has_domain_get = false;
    bool has_domain_assemblies = false;
    bool has_assembly_image = false;
    bool has_class_iter = false;
    bool has_class_from_name = false;
    bool has_method_from_name = false;
    bool has_method_iter = false;
    bool has_method_flags = false;
    bool has_method_params = false;
    bool has_string_api = false;
    bool has_parent_api = false;
    bool has_free = false;

    bool is_ready() const {
        return has_domain_get && has_domain_assemblies && has_assembly_image &&
               (has_class_iter || has_class_from_name) &&
               has_method_iter && has_method_flags;
    }
};

} // namespace smartreward
