#pragma once

#include <cstdio>
#include <cstdint>
#include <cstddef>
#include <cinttypes>
#include <unistd.h>
#include <sys/mman.h>

namespace smartreward {

// Парсинг точных прав защиты страницы памяти из /proc/self/maps
inline int query_page_protection(uintptr_t target_addr) {
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) return PROT_READ;

    char line[512];
    uintptr_t start = 0, end = 0;
    char perms[5] = {0};
    int prot = PROT_READ;

    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "%" SCNxPTR "-%" SCNxPTR " %4s", &start, &end, perms) == 3) {
            if (target_addr >= start && target_addr < end) {
                prot = 0;
                if (perms[0] == 'r') prot |= PROT_READ;
                if (perms[1] == 'w') prot |= PROT_WRITE;
                if (perms[2] == 'x') prot |= PROT_EXEC;
                break;
            }
        }
    }
    fclose(f);
    return prot;
}

// RAII обёртка для безопасного изменения и строгого восстановления прав страниц памяти
struct PageProtectScope {
    void *addr;
    size_t size;
    size_t protect_size;
    uintptr_t page_start;
    int original_prot;
    bool success;

    PageProtectScope(void *address, size_t sz)
        : addr(address), size(sz), protect_size(0), page_start(0),
          original_prot(PROT_READ), success(false) {
        if (!addr || size == 0) return;

        long page_size = sysconf(_SC_PAGESIZE);
        if (page_size <= 0) page_size = 4096;

        page_start = reinterpret_cast<uintptr_t>(addr) & ~(page_size - 1);
        uintptr_t page_end = (reinterpret_cast<uintptr_t>(addr) + size + page_size - 1) & ~(page_size - 1);
        protect_size = page_end - page_start;

        original_prot = query_page_protection(page_start);

        // Временно добавляем PROT_WRITE к оригинальным флагам страницы (без добавления PROT_EXEC)
        if (mprotect(reinterpret_cast<void *>(page_start), protect_size, original_prot | PROT_WRITE) == 0) {
            success = true;
        }
    }

    ~PageProtectScope() {
        if (success && addr && protect_size > 0) {
            // Восстанавливаем строго исходные права страницы
            mprotect(reinterpret_cast<void *>(page_start), protect_size, original_prot);
        }
    }
};

} // namespace smartreward
