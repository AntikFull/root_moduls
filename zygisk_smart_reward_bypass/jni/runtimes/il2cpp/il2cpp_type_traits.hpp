#pragma once

#include "il2cpp_symbols.hpp"
#include "../../core/safe_memory.hpp"
#include <string>
#include <cstring>

namespace smartreward {

class Il2CppTypeTraits {
public:
    static bool is_string_object(void *ptr,
                                 il2cpp_class_get_name_t class_get_name_fn,
                                 il2cpp_string_length_t string_length_fn) {
        if (!ptr || !is_readable_memory(ptr, sizeof(void*) * 2)) return false;

        // Если доступен официальный il2cpp_string_length, вызываем его
        if (string_length_fn) {
            // Проверяем класс перед вызовом
            Il2CppClass *klass = *reinterpret_cast<Il2CppClass **>(ptr);
            if (klass && is_readable_memory(klass, sizeof(void*) * 4) && class_get_name_fn) {
                const char *cname = class_get_name_fn(klass);
                if (cname && (strcmp(cname, "String") == 0 || strcmp(cname, "System.String") == 0)) {
                    return true;
                }
            }
        }

        // Проверка через имя класса
        Il2CppClass *klass = *reinterpret_cast<Il2CppClass **>(ptr);
        if (klass && is_readable_memory(klass, sizeof(void*) * 4) && class_get_name_fn) {
            const char *kname = class_get_name_fn(klass);
            if (kname && (strcmp(kname, "String") == 0 || strcmp(kname, "System.String") == 0)) {
                return true;
            }
        }
        return false;
    }

    static std::string utf16_to_utf8(const uint16_t *chars, size_t len) {
        if (!chars || len == 0) return "";
        std::string out;
        out.reserve(len * 2);
        for (size_t i = 0; i < len; ++i) {
            uint32_t cp = chars[i];
            if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < len) {
                uint32_t low = chars[i + 1];
                if (low >= 0xDC00 && low <= 0xDFFF) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    ++i;
                }
            }
            if (cp < 0x80) {
                out.push_back(static_cast<char>(cp));
            } else if (cp < 0x800) {
                out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            } else if (cp < 0x10000) {
                out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
                out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            } else {
                out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
                out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
            }
        }
        return out;
    }

    static std::string extract_utf8_string(void *ptr,
                                           il2cpp_string_chars_t string_chars_fn,
                                           il2cpp_string_length_t string_length_fn) {
        if (!ptr) return "";

        // 1. Официальный путь через il2cpp_string_*
        if (string_chars_fn && string_length_fn) {
            Il2CppString *str = reinterpret_cast<Il2CppString *>(ptr);
            int32_t len = string_length_fn(str);
            if (len > 0 && len < 4096) {
                const uint16_t *chars = string_chars_fn(str);
                if (chars && is_readable_memory(chars, len * sizeof(uint16_t))) {
                    return utf16_to_utf8(chars, static_cast<size_t>(len));
                }
            }
        }

        // 2. Архитектурно-независимый расчет смещений структуры Il2CppString
        uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
        uintptr_t offset_len = sizeof(void*) * 2;
        uintptr_t offset_chars = offset_len + sizeof(int32_t);

        if (is_readable_memory(reinterpret_cast<const void*>(addr + offset_len), sizeof(int32_t))) {
            int32_t len = *reinterpret_cast<const int32_t *>(addr + offset_len);
            const uint16_t *chars = reinterpret_cast<const uint16_t *>(addr + offset_chars);
            if (len > 0 && len < 4096 && is_readable_memory(chars, len * sizeof(uint16_t))) {
                return utf16_to_utf8(chars, static_cast<size_t>(len));
            }
        }

        return "";
    }

    static bool is_delegate_object(void *ptr,
                                   il2cpp_class_get_name_t class_get_name_fn,
                                   il2cpp_class_get_parent_t class_get_parent_fn) {
        if (!ptr || !is_readable_memory(ptr, sizeof(void*) * 5)) return false;

        Il2CppClass *klass = *reinterpret_cast<Il2CppClass **>(ptr);
        if (!klass || !is_readable_memory(klass, sizeof(void*) * 4)) return false;

        // 1. Быстрая проверка имени класса
        if (class_get_name_fn) {
            const char *cname = class_get_name_fn(klass);
            if (cname) {
                if (strcmp(cname, "MulticastDelegate") == 0 || strcmp(cname, "Delegate") == 0 ||
                    strstr(cname, "Action") != nullptr || strstr(cname, "Callback") != nullptr ||
                    strstr(cname, "Delegate") != nullptr || strstr(cname, "UnityAction") != nullptr) {
                    return true;
                }
            }
        }

        // 2. Иерархический обход дерева наследования (строго до MulticastDelegate / Delegate)
        if (class_get_parent_fn && class_get_name_fn) {
            Il2CppClass *curr = klass;
            int depth = 0;
            while (curr && is_readable_memory(curr, sizeof(void*) * 4) && depth < 12) {
                const char *cname = class_get_name_fn(curr);
                if (cname) {
                    if (strcmp(cname, "MulticastDelegate") == 0 || strcmp(cname, "Delegate") == 0) {
                        return true;
                    }
                }
                curr = class_get_parent_fn(curr);
                depth++;
            }
        }

        return false;
    }

    // Вызов C#-делегата обратного вызова.
    //
    // Значение аргумента можно безопасно синтезировать ТОЛЬКО для простых
    // значимых типов (bool, целые, перечисления). Если делегат принимает ссылку
    // на объект (Action<Reward>, Action<AdInfo>, Action<string>), подстановка
    // константы означала бы передачу невалидного указателя: игра обратится к
    // полю объекта и упадёт. В таком случае вызов не выполняется.
    static bool invoke_delegate_auto(void *ptr,
                                    il2cpp_class_get_name_t class_get_name_fn,
                                    il2cpp_method_get_param_count_t param_count_fn,
                                    il2cpp_method_get_param_t method_get_param_fn = nullptr,
                                    il2cpp_type_get_type_t type_get_type_fn = nullptr) {
        if (!ptr || !is_readable_memory(ptr, sizeof(void*) * 7)) return false;

        uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
        size_t ptr_sz = sizeof(void*);

        void *method_ptr = nullptr;
        void *target = nullptr;
        void *extra_arg = nullptr;

        void *candidate_method = *reinterpret_cast<void **>(addr + ptr_sz * 2);
        void *candidate_invoke = *reinterpret_cast<void **>(addr + ptr_sz * 3);
        void *candidate_target = *reinterpret_cast<void **>(addr + ptr_sz * 4);

        if (is_readable_memory(candidate_method, 4)) {
            method_ptr = candidate_method;
            target = candidate_target;
        } else if (is_readable_memory(candidate_invoke, 4)) {
            method_ptr = candidate_invoke;
            target = candidate_target;
        }

        if (!method_ptr || !is_readable_memory(method_ptr, 4)) return false;

        if (is_readable_memory(reinterpret_cast<const void*>(addr + ptr_sz * 5), ptr_sz)) {
            extra_arg = *reinterpret_cast<void **>(addr + ptr_sz * 5);
        }

        // Точное число параметров берём из MethodInfo делегата.
        const MethodInfo *method = reinterpret_cast<const MethodInfo *>(extra_arg);
        const bool method_valid = method && is_readable_memory(method, sizeof(void*) * 4);
        if (!method_valid || !param_count_fn) {
            // Без достоверного MethodInfo соглашение о вызове неизвестно.
            return false;
        }

        const int param_count = static_cast<int>(param_count_fn(method));
        if (param_count < 0 || param_count > 1) {
            // Делегаты с двумя и более параметрами безопасно синтезировать нельзя.
            return false;
        }

        if (param_count == 1) {
            if (!method_get_param_fn || !type_get_type_fn) return false;
            const Il2CppType *pt = method_get_param_fn(method, 0);
            if (!pt) return false;
            const int ttype = type_get_type_fn(pt);
            // Допустимы только простые значимые типы:
            // 0x02 Boolean, 0x04 SByte, 0x05 Byte, 0x06 Int16, 0x07 UInt16,
            // 0x08 Int32, 0x09 UInt32.
            const bool simple_value_type =
                (ttype == 0x02 || ttype == 0x04 || ttype == 0x05 ||
                 ttype == 0x06 || ttype == 0x07 || ttype == 0x08 || ttype == 0x09);
            if (!simple_value_type) {
                return false;
            }
        }

        (void)class_get_name_fn;

        if (target != nullptr) {
            if (param_count == 0) {
                using Fn = void (*)(void *target, const MethodInfo *m);
                reinterpret_cast<Fn>(method_ptr)(target, method);
            } else {
                using Fn = void (*)(void *target, int32_t value, const MethodInfo *m);
                reinterpret_cast<Fn>(method_ptr)(target, 1, method);
            }
        } else {
            if (param_count == 0) {
                using Fn = void (*)(const MethodInfo *m);
                reinterpret_cast<Fn>(method_ptr)(method);
            } else {
                using Fn = void (*)(int32_t value, const MethodInfo *m);
                reinterpret_cast<Fn>(method_ptr)(1, method);
            }
        }
        return true;
    }
};

} // namespace smartreward
