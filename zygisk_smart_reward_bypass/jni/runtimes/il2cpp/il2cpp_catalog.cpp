#include "il2cpp_catalog.hpp"
#include "../../core/log.hpp"
#include "../../core/config.hpp"
#include "../../core/strings.hpp"
#include <cstdlib>
#include <cstring>
#include <algorithm>

namespace smartreward {

std::string safe_type_get_name(const Il2CppType *type,
                               il2cpp_type_get_name_t get_name_fn,
                               il2cpp_free_t free_fn,
                               il2cpp_type_get_type_t get_type_fn) {
    if (!type) return "System.Object";

    // 1. Предпочтительный путь: реальное полное имя типа из IL2CPP рантайма
    if (get_name_fn) {
        char *raw_name = get_name_fn(type);
        if (raw_name) {
            std::string name_str = raw_name;
            if (free_fn) {
                free_fn(raw_name);
            }
            if (!name_str.empty()) {
                return name_str;
            }
        }
    }

    // 2. Безопасный fallback по enum типа CLR/IL2CPP
    if (get_type_fn) {
        int t = get_type_fn(type);
        switch (t) {
            case 0x01: return "System.Void";
            case 0x02: return "System.Boolean";
            case 0x03: return "System.Char";
            case 0x04: return "System.SByte";
            case 0x05: return "System.Byte";
            case 0x06: return "System.Int16";
            case 0x07: return "System.UInt16";
            case 0x08: return "System.Int32";
            case 0x09: return "System.UInt32";
            case 0x0a: return "System.Int64";
            case 0x0b: return "System.UInt64";
            case 0x0c: return "System.Single";
            case 0x0d: return "System.Double";
            case 0x0e: return "System.String";
            case 0x0f: return "System.Ptr";
            case 0x10: return "System.ByRef";
            case 0x11: return "System.ValueType";
            case 0x12: return "System.Object";
            case 0x13: return "T"; // Generic Parameter (Var)
            case 0x14: return "System.Array";
            case 0x15: return "System.GenericInst";
            case 0x16: return "System.TypedReference";
            case 0x18: return "System.IntPtr";
            case 0x19: return "System.UIntPtr";
            case 0x1c: return "System.Object";
            case 0x1d: return "System.Array"; // SzArray
            case 0x1e: return "T"; // Generic Parameter (MVar)
            default:   return "System.Object";
        }
    }

    return "System.Object";
}

MetadataIndex &MetadataIndex::instance() {
    static MetadataIndex s_instance;
    return s_instance;
}

void MetadataIndex::clear() {
    methods_.clear();
    methods_seen_ = 0;
    scan_truncated_ = false;
    lookup_map_.clear();
    by_assembly_.clear();
    by_class_.clear();
}

size_t MetadataIndex::build(const std::vector<const Il2CppImage *> &images,
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
                            il2cpp_free_t free_fn) {
    clear();

    if (!image_get_name_fn || !image_class_count_fn || !image_get_class_fn ||
        !class_get_name_fn || !class_get_methods_fn || !method_get_name_fn) {
        return 0;
    }

    methods_.reserve(16384);
    bool limit_reached = false;

    // Сортировка сборок по приоритету: Рекламные SDK -> Игровой код (Assembly-CSharp) -> Прочие плагины -> Системные
    std::vector<const Il2CppImage *> sorted_images = images;
    std::stable_sort(sorted_images.begin(), sorted_images.end(), [&](const Il2CppImage *a, const Il2CppImage *b) {
        auto get_priority = [&](const Il2CppImage *img) -> int {
            if (!img) return 999;
            const char *raw = image_get_name_fn(img);
            if (!raw) return 999;
            std::string n = raw;
            if (n.find("MaxSdk") != std::string::npos ||
                n.find("GoogleMobileAds") != std::string::npos ||
                n.find("IronSource") != std::string::npos ||
                n.find("Advertisements") != std::string::npos ||
                n.find("Yandex") != std::string::npos ||
                n.find("Vungle") != std::string::npos ||
                n.find("Pangle") != std::string::npos) return 1;
            if (n.find("Assembly-CSharp") != std::string::npos) return 2;
            if (n.find("UnityEngine.") != std::string::npos) return 80;
            if (n.find("mscorlib") != std::string::npos ||
                n.rfind("System.", 0) == 0 ||
                n.rfind("Mono.", 0) == 0) return 90;
            return 10;
        };
        return get_priority(a) < get_priority(b);
    });

    // === ФАЗА A: Сверхбыстрый сбор легковесных дескрипторов всех методов ===
    for (const Il2CppImage *image : sorted_images) {
        if (!image || limit_reached) break;
        const char *img_raw = image_get_name_fn(image);
        std::string assembly_name = img_raw ? img_raw : "";

        // Пропускаем системные сборки .NET и внутренние модули движка Unity.
        //
        // Обход классов вынуждает рантайм материализовать метаданные каждого из
        // них. На крупной игре это десятки тысяч классов, что даёт длительную
        // конкуренцию с основным потоком за блокировки метаданных (фризы и
        // чёрный экран на старте) и повышает риск обращения к неготовым типам.
        // Рекламной логики в этих сборках заведомо нет, поэтому они исключаются.
        const bool is_system_assembly =
            assembly_name == "mscorlib.dll" ||
            assembly_name == "netstandard.dll" ||
            assembly_name.rfind("System", 0) == 0 ||
            assembly_name.rfind("Mono.", 0) == 0;

        const bool has_ad_marker =
            to_lower(assembly_name).find("ad") != std::string::npos ||
            to_lower(assembly_name).find("monet") != std::string::npos;

        // UnityEngine.*Module.dll — внутренние модули движка (Physics, Audio, UI...).
        const bool is_engine_module =
            assembly_name.rfind("UnityEngine.", 0) == 0 &&
            assembly_name.find("Module.dll") != std::string::npos &&
            !has_ad_marker;

        if (is_system_assembly || is_engine_module) {
            continue;
        }

        size_t class_count = image_class_count_fn(image);
        for (size_t c = 0; c < class_count; ++c) {
            if (limit_reached) break;

            Il2CppClass *klass = image_get_class_fn(image, c);
            if (!klass) continue;

            const char *cname = class_get_name_fn(klass);
            // Класс без имени означает не до конца сформированный тип: обращение
            // к его методам в этот момент небезопасно.
            if (!cname) continue;
            const char *ns = class_get_namespace_fn ? class_get_namespace_fn(klass) : "";
            std::string class_str = cname;
            std::string ns_str = ns ? ns : "";

            void *iter = nullptr;
            const MethodInfo *method = nullptr;
            while ((method = class_get_methods_fn(klass, &iter)) != nullptr) {
                methods_seen_++;

                if (methods_.size() >= METADATA_INDEX_BUDGET) {
                    limit_reached = true;
                    scan_truncated_ = true;
                    LOGW("[CATALOG] Reached metadata budget limit of %zu methods (seen %zu)",
                         METADATA_INDEX_BUDGET, methods_seen_);
                    break;
                }

                const char *mname = method_get_name_fn(method);
                if (!mname) continue;

                MethodDescriptor desc;
                desc.method_ptr = method;
                desc.assembly = assembly_name;
                desc.name_space = ns_str;
                desc.class_name = class_str;
                desc.method_name = mname;

                uint32_t pcount = method_param_count_fn ? method_param_count_fn(method) : 0;
                desc.param_count = pcount;

                if (method_get_flags_fn) {
                    uint32_t iflags = 0;
                    uint32_t flags = method_get_flags_fn(method, &iflags);
                    desc.is_static = (flags & 0x0010) != 0;
                }

                // === ФАЗА B: Извлечение типов параметров и возврата ===
                // Извлекаем полные типы для пользовательских сборок, SDK и потенциальных наград
                std::string lasm = to_lower(assembly_name);
                bool is_app_assembly = (lasm.find("assembly-csharp") != std::string::npos ||
                                        lasm.find("game") != std::string::npos ||
                                        lasm.find("app") != std::string::npos ||
                                        lasm.find("script") != std::string::npos ||
                                        lasm.find("voodoo") != std::string::npos ||
                                        lasm.find("max") != std::string::npos ||
                                        lasm.find("ads") != std::string::npos);

                if (is_app_assembly || pcount <= 6) {
                    if (method_get_return_type_fn) {
                        const Il2CppType *ret_type = method_get_return_type_fn(method);
                        desc.return_type = safe_type_get_name(ret_type, type_get_name_fn, free_fn, type_get_type_fn);
                    } else {
                        desc.return_type = "System.Void";
                    }

                    if (method_get_param_fn && pcount > 0) {
                        desc.param_types.reserve(pcount);
                        for (uint32_t p = 0; p < pcount; ++p) {
                            const Il2CppType *ptype = method_get_param_fn(method, p);
                            desc.param_types.push_back(safe_type_get_name(ptype, type_get_name_fn, free_fn, type_get_type_fn));
                        }
                    }
                } else {
                    desc.return_type = "System.Void";
                }

                size_t idx = methods_.size();
                methods_.push_back(std::move(desc));

                // Overload-aware lookup: ключ "assembly|namespace.class::method|pcount"
                std::string key = assembly_name + "|" + (ns_str.empty() ? "" : (ns_str + ".")) + class_str + "::" + mname + "|" + std::to_string(pcount);
                lookup_map_[key].push_back(idx);

                // Иерархические индексы
                by_assembly_[assembly_name].push_back(idx);
                by_class_[class_str].push_back(idx);
            }
        }
    }

    LOGI("[CATALOG] MetadataIndex built: %zu indexed, %zu seen, budget=%zu, truncated=%d",
         methods_.size(), methods_seen_, METADATA_INDEX_BUDGET, scan_truncated_);
    return methods_.size();
}

std::vector<const MethodDescriptor *> MetadataIndex::find_methods(const std::string &assembly,
                                                                 const std::string &name_space,
                                                                 const std::string &class_name,
                                                                 const std::string &method_name,
                                                                 int arg_count) const {
    std::vector<const MethodDescriptor *> results;
    std::string key = assembly + "|" + (name_space.empty() ? "" : (name_space + ".")) + class_name + "::" + method_name + "|" + std::to_string(arg_count);
    auto it = lookup_map_.find(key);
    if (it != lookup_map_.end()) {
        results.reserve(it->second.size());
        for (size_t idx : it->second) {
            if (idx < methods_.size()) results.push_back(&methods_[idx]);
        }
    }
    return results;
}

const MethodDescriptor *MetadataIndex::find_method_exact(const std::string &assembly,
                                                         const std::string &name_space,
                                                         const std::string &class_name,
                                                         const std::string &method_name,
                                                         const std::vector<std::string> &param_types,
                                                         const std::string &return_type) const {
    int argc = static_cast<int>(param_types.size());
    auto candidates = find_methods(assembly, name_space, class_name, method_name, argc);
    for (const auto *m : candidates) {
        if (!return_type.empty() && m->return_type != return_type) continue;
        if (m->param_types == param_types) return m;
    }
    return candidates.empty() ? nullptr : candidates[0];
}

std::vector<const MethodDescriptor *> MetadataIndex::query_wildcard(const std::string &assembly_pat,
                                                                    const std::string &namespace_pat,
                                                                    const std::string &class_pat,
                                                                    const std::string &method_pat,
                                                                    int arg_count) const {
    std::vector<const MethodDescriptor *> results;

    // Оптимизация: если class_pat точный (без wildcard), ищем сразу по by_class_
    if (!class_pat.empty() && class_pat.find('*') == std::string::npos && class_pat.find('?') == std::string::npos) {
        auto it = by_class_.find(class_pat);
        if (it != by_class_.end()) {
            for (size_t idx : it->second) {
                if (idx >= methods_.size()) continue;
                const auto &m = methods_[idx];
                if (!assembly_pat.empty() && !wildcard_match(assembly_pat.c_str(), m.assembly.c_str())) continue;
                if (!namespace_pat.empty() && !wildcard_match(namespace_pat.c_str(), m.name_space.c_str())) continue;
                if (!method_pat.empty() && !wildcard_match(method_pat.c_str(), m.method_name.c_str())) continue;
                if (arg_count >= 0 && static_cast<uint32_t>(arg_count) != m.param_count) continue;
                results.push_back(&m);
            }
            return results;
        }
    }

    // Оптимизация: если assembly_pat точный (без wildcard), ищем по by_assembly_
    if (!assembly_pat.empty() && assembly_pat.find('*') == std::string::npos && assembly_pat.find('?') == std::string::npos) {
        auto it = by_assembly_.find(assembly_pat);
        if (it != by_assembly_.end()) {
            for (size_t idx : it->second) {
                if (idx >= methods_.size()) continue;
                const auto &m = methods_[idx];
                if (!namespace_pat.empty() && !wildcard_match(namespace_pat.c_str(), m.name_space.c_str())) continue;
                if (!class_pat.empty() && !wildcard_match(class_pat.c_str(), m.class_name.c_str())) continue;
                if (!method_pat.empty() && !wildcard_match(method_pat.c_str(), m.method_name.c_str())) continue;
                if (arg_count >= 0 && static_cast<uint32_t>(arg_count) != m.param_count) continue;
                results.push_back(&m);
            }
            return results;
        }
    }

    // Линейный поиск
    for (const auto &m : methods_) {
        if (!assembly_pat.empty() && !wildcard_match(assembly_pat.c_str(), m.assembly.c_str())) continue;
        if (!namespace_pat.empty() && !wildcard_match(namespace_pat.c_str(), m.name_space.c_str())) continue;
        if (!class_pat.empty() && !wildcard_match(class_pat.c_str(), m.class_name.c_str())) continue;
        if (!method_pat.empty() && !wildcard_match(method_pat.c_str(), m.method_name.c_str())) continue;
        if (arg_count >= 0 && static_cast<uint32_t>(arg_count) != m.param_count) continue;
        results.push_back(&m);
    }
    return results;
}

} // namespace smartreward
