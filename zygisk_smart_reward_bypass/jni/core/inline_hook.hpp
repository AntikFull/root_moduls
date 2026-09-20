#pragma once

#include <cstddef>
#include <cstdint>

namespace smartreward {

// Результат установки перехвата.
enum class DetourStatus {
    Ok = 0,
    NullTarget,        // methodPointer == nullptr (метод не скомпилирован)
    UnsupportedArch,   // ABI без поддержки inline-хуков
    NotExecutable,     // адрес не принадлежит исполняемой области процесса
    NoIsland,          // не удалось разместить переходник в пределах досягаемости перехода
    ProtectFailed,     // mprotect отклонён ядром/SELinux
    AlreadyHooked
};

const char *to_string(DetourStatus status);

// Безусловная замена функции: target больше никогда не выполняется, управление
// сразу уходит в replacement. Регистры аргументов не трогаются, поэтому
// replacement получает ровно те же аргументы, что и оригинал (ABI сохраняется).
//
// Оригинал НЕ сохраняется: перехват рассчитан на полную подмену поведения
// (готовность рекламы / показ рекламы), где вызывать исходный код не требуется.
DetourStatus install_detour(void *target, void *replacement);

// Проверка, установлен ли уже перехват по данному адресу. Нужна, чтобы
// пересекающиеся правила конфигурации не занимали слоты трамплинов повторно.
bool is_detoured(void *target);

// Количество успешно установленных перехватов в текущем процессе.
size_t detour_count();

// Диагностика размещения переходников (для отчёта о состоянии движка).
void detour_island_stats(size_t *pages_out, size_t *slots_used_out);

} // namespace smartreward
