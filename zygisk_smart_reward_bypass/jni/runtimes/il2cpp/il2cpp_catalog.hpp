#pragma once

#include "il2cpp_symbols.hpp"
#include <string>
#include <vector>
#include <unordered_map>

namespace smartreward {

constexpr size_t METADATA_INDEX_BUDGET = 250000;

// Безопасное получение имени типа без риска heap corruption и с защитой generic-типов
std::string safe_type_get_name(const Il2CppType *type,
                               il2cpp_type_get_name_t get_name_fn,
                               il2cpp_free_t free_fn,
                               il2cpp_type_get_type_t get_type_fn = nullptr);

// Двухфазный метадата-индекс рантайма с расширенным бюджетом
class MetadataIndex {
public:
    static MetadataIndex &instance();

    void clear();
    size_t build(const std::vector<const Il2CppImage *> &images,
                 il2cpp_image_get_name_t image_get_name_fn,
                 il2cpp_image_get_class_count_t image_class_count_fn,
                 il2cpp_image_get_class_t image_get_class_fn,
                 il2cpp_class_get_name_t class_get_name_fn,
                 il2cpp_class_get_namespace_t class_get_namespace_fn,
                 il2cpp_class_get_methods_t class_get_methods_fn,
                 il2cpp_method_get_name_t method_get_name_fn,
                 il2cpp_method_get_param_count_t method_param_count_fn,
                 il2cpp_method_get_param_t method_get_param_fn,
                 il2cpp_method_get_return_type_t method_get_return_type_fn,
                 il2cpp_method_get_flags_t method_get_flags_fn,
                 il2cpp_type_get_name_t type_get_name_fn,
                 il2cpp_type_get_type_t type_get_type_fn,
                 il2cpp_free_t free_fn);

    const std::vector<MethodDescriptor> &get_all_methods() const { return methods_; }
    std::vector<MethodDescriptor> &get_mutable_methods() { return methods_; }
    size_t get_methods_seen() const { return methods_seen_; }
    size_t get_methods_indexed() const { return methods_.size(); }
    bool is_scan_truncated() const { return scan_truncated_; }
    size_t get_index_budget() const { return METADATA_INDEX_BUDGET; }

    // Возврат всех перегруженных методов по имени и argc
    std::vector<const MethodDescriptor *> find_methods(const std::string &assembly,
                                                      const std::string &name_space,
                                                      const std::string &class_name,
                                                      const std::string &method_name,
                                                      int arg_count) const;

    // Точный поиск метода по полному списку типов параметров и возврата
    const MethodDescriptor *find_method_exact(const std::string &assembly,
                                              const std::string &name_space,
                                              const std::string &class_name,
                                              const std::string &method_name,
                                              const std::vector<std::string> &param_types,
                                              const std::string &return_type = "") const;

    std::vector<const MethodDescriptor *> query_wildcard(const std::string &assembly_pat,
                                                         const std::string &namespace_pat,
                                                         const std::string &class_pat,
                                                         const std::string &method_pat,
                                                         int arg_count) const;

private:
    MetadataIndex() = default;

    std::vector<MethodDescriptor> methods_;
    size_t methods_seen_ = 0;
    bool scan_truncated_ = false;

    // Overload-aware lookup: ключ "assembly|namespace.class::method|pcount" -> индексы методов
    std::unordered_map<std::string, std::vector<size_t>> lookup_map_;

    // Иерархические индексы для быстрого поиска
    std::unordered_map<std::string, std::vector<size_t>> by_assembly_;
    std::unordered_map<std::string, std::vector<size_t>> by_class_;
};

} // namespace smartreward
