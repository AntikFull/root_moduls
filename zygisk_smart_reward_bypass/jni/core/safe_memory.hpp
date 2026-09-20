#pragma once

#include <cstdint>
#include <cstddef>
#include <unistd.h>
#include <fcntl.h>

namespace smartreward {

inline int get_null_file_descriptor() {
    static int s_fd = -1;
    if (s_fd < 0 || fcntl(s_fd, F_GETFD) == -1) {
        s_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
    }
    return s_fd;
}

// Безопасная проверка читаемости указателя через системный вызов write в /dev/null
inline bool is_readable_memory(const void *ptr, size_t size, size_t min_align = 1) {
    if (!ptr || size == 0) return false;
    uintptr_t addr = reinterpret_cast<uintptr_t>(ptr);
    if (addr < 0x10000) return false;
    if (min_align > 1 && (addr & (min_align - 1)) != 0) return false;

    int fd = get_null_file_descriptor();
    if (fd < 0) return false; // fail-closed: если проверка невозможна, указатель не считается безопасным

    ssize_t written = write(fd, ptr, size);
    return written == static_cast<ssize_t>(size);
}

} // namespace smartreward
