#pragma once

#include "il2cpp_symbols.hpp"

#include <string>

namespace smartreward {

// ---------------------------------------------------------------------------
// Безопасный вызов управляемого (C#) кода из нативного слоя.
//
// Все обращения идут через штатный il2cpp_runtime_invoke: рантайм сам выбирает
// корректный invoker под сигнатуру метода. Это принципиально отличается от
// приведения methodPointer к произвольному указателю на функцию — там любая
// ошибка в предполагаемых типах аргументов приводит к порче регистров и
// падению процесса.
//
// Класс не владеет рантаймом и безопасно бездействует, если нужные экспорты
// libil2cpp.so недоступны.
// ---------------------------------------------------------------------------
class ManagedInvoker {
public:
    static ManagedInvoker &instance();

    // Привязка к экспортам libil2cpp.so. Повторный вызов безвреден.
    void bind(void *il2cpp_handle);
    bool ready() const { return ready_; }

    // Создание управляемой строки из UTF-8.
    Il2CppString *make_string(const std::string &utf8) const;

    // Вызов метода. obj == nullptr для статических методов.
    // Возвращает false, если вызов невозможен или управляемый код бросил
    // исключение (исключение поглощается и не выходит в игровой код).
    bool invoke(const MethodInfo *method, void *obj, void **params) const;

    // Вызов метода с возвратом ссылочного результата. Нужен для безопасного
    // перенаправления между методами с одинаковой сигнатурой Task<T>.
    Il2CppObject *invoke_object(const MethodInfo *method, void *obj, void **params,
                               bool *success = nullptr) const;

    // Создание объекта заданного класса без вызова конструктора.
    Il2CppObject *new_object(Il2CppClass *klass) const;

    // Чтение ссылочного поля объекта (например, поля-делегата события).
    void *read_object_field(void *obj, const char *field_name) const;

    // Класс объекта.
    Il2CppClass *class_of(void *obj) const;

    // Класс по типу (нужен, чтобы добраться до перечислений в сигнатурах).
    Il2CppClass *class_from_type(const Il2CppType *type) const;

    // Тип параметра метода по индексу.
    const Il2CppType *param_type(const MethodInfo *method, int index) const;

    // Поиск метода класса по имени и числу аргументов.
    const MethodInfo *find_method(Il2CppClass *klass, const char *name, int argc) const;

    // Запись ссылочного или значимого поля объекта.
    bool write_field(void *obj, const char *field_name, void *value_ptr) const;

    // Чтение значения константы перечисления из метаданных игры.
    // Позволяет не зашивать числовые константы SDK: значение берётся из той
    // версии сборки, которая реально загружена в процесс.
    bool read_enum_constant(Il2CppClass *enum_class, const char *name, int32_t *out) const;

    // Вызов делегата (Action/EventHandler и производные) через его метод Invoke.
    // Аргументы передаются как есть; ответственность за их корректность лежит
    // на вызывающей стороне.
    bool invoke_delegate(void *delegate_obj, void **params, int argc) const;

private:
    ManagedInvoker() = default;

    bool ready_ = false;
    il2cpp_runtime_invoke_t runtime_invoke_ = nullptr;
    il2cpp_object_new_t object_new_ = nullptr;
    il2cpp_string_new_t string_new_ = nullptr;
    il2cpp_object_get_class_t object_get_class_ = nullptr;
    il2cpp_class_get_field_from_name_t class_get_field_ = nullptr;
    il2cpp_field_get_value_t field_get_value_ = nullptr;
    il2cpp_field_set_value_t field_set_value_ = nullptr;
    il2cpp_field_static_get_value_t field_static_get_value_ = nullptr;
    il2cpp_class_get_method_from_name_t class_get_method_ = nullptr;
    il2cpp_class_get_name_t class_get_name_ = nullptr;
    il2cpp_class_from_type_t class_from_type_ = nullptr;
    il2cpp_method_get_param_t method_get_param_ = nullptr;
};

} // namespace smartreward
