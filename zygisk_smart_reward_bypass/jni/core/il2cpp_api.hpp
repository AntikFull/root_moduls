#pragma once

#include "config.hpp"
#include "page_protect.hpp"
#include "safe_memory.hpp"
#include "../runtimes/il2cpp/il2cpp_symbols.hpp"
#include "../runtimes/il2cpp/il2cpp_type_traits.hpp"
#include "../adapters/sdk_adapter.hpp"
#include "../adapters/max_bridge.hpp"
#include "../adapters/reward_channels.hpp"
#include "../discovery/fingerprint.hpp"
#include "../discovery/report_writer.hpp"

#include <string>
#include <vector>
#include <unordered_map>
#include <memory>

namespace smartreward {

class Il2CppResolver {
public:
    static Il2CppResolver &instance();

    bool init();
    ResolveStatus probe_and_resolve(const std::string &package_name = "");
    bool check_and_rescan_assemblies(const std::string &package_name = "");
    void notify_unity_reward(const char *game_object, const char *method, const char *message);
    void notify_active_sdk_rewards(uint64_t trace_id = 0);
    void notify_all_unity_rewards();
    void dispatch_targeted_reward(const std::string &sdk_name, const std::string &placement, uintptr_t obj_ptr, ISdkAdapter *adapter);
    void dispatch_hook_index(size_t index, const std::string &placement,
                             void *const *args, size_t argc);
    ISdkAdapter *find_adapter_by_name(const std::string &name) const;

    static constexpr size_t MAX_SHOW_HOOKS = 32;

    // Принудительная замена methodPointer на нативный хук
    bool hook_method_always_true(const MethodInfo *method, const char *desc);
    bool hook_method_network_reachability(const MethodInfo *method, const char *desc);
    bool hook_method_show_and_reward(const MethodInfo *method, const char *desc,
                                     const char *assembly);
    bool hook_method_forward_interceptor(const MethodInfo *method, const char *desc);

    // Валидация типов и соглашений о вызовах
    bool is_method_static(const MethodInfo *method) const;
    int get_method_cpp_args(const MethodInfo *method) const;
    bool is_string_object(void *ptr) const;
    bool is_delegate_object(void *ptr) const;
    bool invoke_direct_delegate(void *candidate_delegate) const;

    const Il2CppCapabilityMatrix &capabilities() const { return caps_; }
    il2cpp_string_chars_t string_chars_api() const { return string_chars_; }
    il2cpp_string_length_t string_length_api() const { return string_length_; }
    std::string get_package_name() const;
    std::string get_process_name() const;

private:
    Il2CppResolver();

    void *il2cpp_handle_ = nullptr;
    Il2CppCapabilityMatrix caps_;

    il2cpp_domain_get_t domain_get_ = nullptr;
    il2cpp_domain_get_assemblies_t domain_get_assemblies_ = nullptr;
    il2cpp_thread_attach_t thread_attach_ = nullptr;
    il2cpp_thread_detach_t thread_detach_ = nullptr;
    il2cpp_thread_current_t thread_current_ = nullptr;
    il2cpp_assembly_get_image_t assembly_get_image_ = nullptr;
    il2cpp_image_get_name_t image_get_name_ = nullptr;
    il2cpp_image_get_class_count_t image_get_class_count_ = nullptr;
    il2cpp_image_get_class_t image_get_class_ = nullptr;
    il2cpp_class_get_name_t class_get_name_ = nullptr;
    il2cpp_class_get_namespace_t class_get_namespace_ = nullptr;
    il2cpp_class_from_name_t class_from_name_ = nullptr;
    il2cpp_class_get_methods_t class_get_methods_ = nullptr;
    il2cpp_class_get_method_from_name_t class_get_method_from_name_ = nullptr;
    il2cpp_class_get_parent_t class_get_parent_ = nullptr;
    il2cpp_class_is_subclass_of_t class_is_subclass_of_ = nullptr;

    il2cpp_method_get_name_t method_get_name_ = nullptr;
    il2cpp_method_get_param_count_t method_get_param_count_ = nullptr;
    il2cpp_method_get_param_t method_get_param_ = nullptr;
    il2cpp_method_get_return_type_t method_get_return_type_ = nullptr;
    il2cpp_method_get_flags_t method_get_flags_ = nullptr;

    il2cpp_type_get_type_t type_get_type_ = nullptr;
    il2cpp_type_get_name_t type_get_name_ = nullptr;
    il2cpp_free_t il2cpp_free_ = nullptr;

    il2cpp_string_chars_t string_chars_ = nullptr;
    il2cpp_string_new_t string_new_ = nullptr;
    il2cpp_string_length_t string_length_ = nullptr;
    il2cpp_object_get_class_t object_get_class_ = nullptr;

    UnitySendMessage_t unity_send_message_ = nullptr;

    std::vector<std::unique_ptr<ISdkAdapter>> sdk_adapters_;
    std::vector<ISdkAdapter *> active_adapters_;
    std::string package_name_ = "unknown_pkg";
    std::string process_name_ = "main";

    void ensure_unity_bridge();
    void register_sdk_adapters();
};

void hook_maxsdk_callback_stub(void *a0, void *a1, void *a2);

// Сводка фактических срабатываний перехватов (вызывать только из фонового потока).
void log_hook_activity(bool force = false);

} // namespace smartreward
