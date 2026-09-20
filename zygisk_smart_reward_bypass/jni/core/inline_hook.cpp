#include "inline_hook.hpp"
#include "log.hpp"

#include <sys/mman.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <cinttypes>
#include <mutex>
#include <vector>
#include <algorithm>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

namespace smartreward {

const char *to_string(DetourStatus status) {
    switch (status) {
        case DetourStatus::Ok:              return "OK";
        case DetourStatus::NullTarget:      return "NULL_TARGET";
        case DetourStatus::UnsupportedArch: return "UNSUPPORTED_ARCH";
        case DetourStatus::NotExecutable:   return "NOT_EXECUTABLE";
        case DetourStatus::NoIsland:        return "NO_ISLAND";
        case DetourStatus::ProtectFailed:   return "PROTECT_FAILED";
        case DetourStatus::AlreadyHooked:   return "ALREADY_HOOKED";
    }
    return "UNKNOWN";
}

namespace {

struct MapEntry {
    uintptr_t start;
    uintptr_t end;
    int prot;
};

std::mutex g_detour_mutex;
size_t g_detour_count = 0;
std::vector<uintptr_t> g_hooked_targets;

long page_size_cached() {
    static long s_ps = 0;
    if (s_ps == 0) {
        s_ps = sysconf(_SC_PAGESIZE);
        if (s_ps <= 0) s_ps = 4096;
    }
    return s_ps;
}

std::vector<MapEntry> read_maps() {
    std::vector<MapEntry> out;
    FILE *f = fopen("/proc/self/maps", "re");
    if (!f) return out;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        uintptr_t start = 0, end = 0;
        char perms[5] = {0};
        if (sscanf(line, "%" SCNxPTR "-%" SCNxPTR " %4s", &start, &end, perms) != 3) continue;
        int prot = 0;
        if (perms[0] == 'r') prot |= PROT_READ;
        if (perms[1] == 'w') prot |= PROT_WRITE;
        if (perms[2] == 'x') prot |= PROT_EXEC;
        out.push_back(MapEntry{start, end, prot});
    }
    fclose(f);
    std::sort(out.begin(), out.end(),
              [](const MapEntry &a, const MapEntry &b) { return a.start < b.start; });
    return out;
}

bool query_region(const std::vector<MapEntry> &maps, uintptr_t addr, MapEntry *out) {
    for (const auto &m : maps) {
        if (addr >= m.start && addr < m.end) {
            if (out) *out = m;
            return true;
        }
    }
    return false;
}

// RAII: временно добавляет PROT_WRITE к странице, не снимая PROT_EXEC,
// чтобы параллельно исполняющийся код не получил SIGSEGV.
struct WritableCode {
    uintptr_t page_start = 0;
    size_t    span = 0;
    int       original_prot = 0;
    bool      ok = false;

    WritableCode(uintptr_t addr, size_t len, int prot) {
        const long ps = page_size_cached();
        page_start = addr & ~static_cast<uintptr_t>(ps - 1);
        uintptr_t page_end = (addr + len + static_cast<uintptr_t>(ps) - 1) &
                             ~static_cast<uintptr_t>(ps - 1);
        span = page_end - page_start;
        original_prot = prot;
        if (mprotect(reinterpret_cast<void *>(page_start), span, prot | PROT_WRITE) == 0) {
            ok = true;
        }
    }

    ~WritableCode() {
        if (ok) {
            mprotect(reinterpret_cast<void *>(page_start), span, original_prot);
        }
    }
};

// ---------------------------------------------------------------------------
// Переходники (islands)
//
// На ARM инструкция безусловного перехода адресует цель относительно PC и имеет
// ограниченный диапазон. Поэтому рядом с целевой функцией размещается страница
// с абсолютными переходами, а в саму функцию пишется всего одна инструкция.
// Патч в 4 байта по выровненному адресу атомарен относительно выборки инструкций,
// поэтому перехват безопасно ставится даже на выполняющуюся в этот момент функцию.
// ---------------------------------------------------------------------------

#if defined(__aarch64__)
constexpr size_t    kIslandSlotSize = 16;
constexpr uintptr_t kBranchReach    = 128u * 1024u * 1024u; // +-128 МБ для B imm26
constexpr size_t    kPatchSize      = 4;
#elif defined(__arm__)
constexpr size_t    kIslandSlotSize = 8;
constexpr uintptr_t kBranchReach    = 32u * 1024u * 1024u;  // +-32 МБ для B imm24
constexpr size_t    kPatchSize      = 4;
#elif defined(__x86_64__) || defined(__i386__)
constexpr size_t    kIslandSlotSize = 16;
constexpr uintptr_t kBranchReach    = 2000u * 1024u * 1024u; // +-2 ГБ для jmp rel32
constexpr size_t    kPatchSize      = 5;
#else
constexpr size_t    kIslandSlotSize = 16;
constexpr uintptr_t kBranchReach    = 0;
constexpr size_t    kPatchSize      = 0;
#endif

struct IslandPage {
    uintptr_t base = 0;
    size_t    used = 0;
    size_t    capacity = 0;
};

std::vector<IslandPage> g_islands;

bool island_in_reach(const IslandPage &page, uintptr_t target) {
    uintptr_t lo = page.base;
    uintptr_t hi = page.base + page.capacity * kIslandSlotSize;
    uintptr_t dist_lo = (target > lo) ? (target - lo) : (lo - target);
    uintptr_t dist_hi = (target > hi) ? (target - hi) : (hi - target);
    return dist_lo < kBranchReach && dist_hi < kBranchReach;
}

// Резервирует страницу под переходники в свободном промежутке адресного
// пространства, попадающем в радиус перехода от target.
uintptr_t reserve_island_page(uintptr_t target) {
    const long ps = page_size_cached();
    if (kBranchReach <= static_cast<uintptr_t>(ps) * 4) return 0;
    const uintptr_t reach = kBranchReach - static_cast<uintptr_t>(ps) * 4;
    const uintptr_t low  = (target > reach) ? (target - reach) : static_cast<uintptr_t>(ps);
    const uintptr_t high = target + reach;

    std::vector<MapEntry> maps = read_maps();
    if (maps.empty()) return 0;

    // Кандидаты — свободные промежутки между соседними отображениями.
    std::vector<uintptr_t> candidates;
    for (size_t i = 0; i + 1 < maps.size(); ++i) {
        uintptr_t gap_start = (maps[i].end + static_cast<uintptr_t>(ps) - 1) &
                              ~static_cast<uintptr_t>(ps - 1);
        uintptr_t gap_end   = maps[i + 1].start & ~static_cast<uintptr_t>(ps - 1);
        if (gap_end <= gap_start) continue;
        if (gap_end - gap_start < static_cast<uintptr_t>(ps)) continue;
        if (gap_end <= low || gap_start >= high) continue;

        uintptr_t near_low  = std::max(gap_start, low);
        uintptr_t near_high = std::min(gap_end, high) - static_cast<uintptr_t>(ps);
        candidates.push_back(near_low);
        if (near_high > near_low) candidates.push_back(near_high);
    }

    std::sort(candidates.begin(), candidates.end(), [target](uintptr_t a, uintptr_t b) {
        uintptr_t da = (a > target) ? (a - target) : (target - a);
        uintptr_t db = (b > target) ? (b - target) : (target - b);
        return da < db;
    });

    for (uintptr_t hint : candidates) {
        void *addr = mmap(reinterpret_cast<void *>(hint), static_cast<size_t>(ps),
                          PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
        if (addr == MAP_FAILED) continue;
        if (reinterpret_cast<uintptr_t>(addr) != hint) {
            munmap(addr, static_cast<size_t>(ps));
            continue;
        }
        if (mprotect(addr, static_cast<size_t>(ps), PROT_READ | PROT_EXEC) != 0) {
            munmap(addr, static_cast<size_t>(ps));
            continue;
        }
        return hint;
    }
    return 0;
}

// Записывает в переходник абсолютный переход на replacement и возвращает его адрес.
uintptr_t alloc_island_slot(uintptr_t target, uintptr_t replacement) {
    IslandPage *page = nullptr;
    for (auto &p : g_islands) {
        if (p.used < p.capacity && island_in_reach(p, target)) {
            page = &p;
            break;
        }
    }

    if (!page) {
        uintptr_t base = reserve_island_page(target);
        if (base == 0) return 0;
        IslandPage fresh;
        fresh.base = base;
        fresh.used = 0;
        fresh.capacity = static_cast<size_t>(page_size_cached()) / kIslandSlotSize;
        g_islands.push_back(fresh);
        page = &g_islands.back();
    }

    uintptr_t slot = page->base + page->used * kIslandSlotSize;

    WritableCode guard(slot, kIslandSlotSize, PROT_READ | PROT_EXEC);
    if (!guard.ok) return 0;

#if defined(__aarch64__)
    // LDR X17, #8 ; BR X17 ; .quad replacement
    uint32_t *code = reinterpret_cast<uint32_t *>(slot);
    code[0] = 0x58000051u;
    code[1] = 0xD61F0220u;
    *reinterpret_cast<uint64_t *>(slot + 8) = static_cast<uint64_t>(replacement);
#elif defined(__arm__)
    // LDR PC, [PC, #-4] ; .word replacement
    uint32_t *code = reinterpret_cast<uint32_t *>(slot);
    code[0] = 0xE51FF004u;
    code[1] = static_cast<uint32_t>(replacement);
#elif defined(__x86_64__)
    // movabs rax, imm64 ; jmp rax
    uint8_t *code = reinterpret_cast<uint8_t *>(slot);
    uint64_t dest = static_cast<uint64_t>(replacement);
    code[0] = 0x48;
    code[1] = 0xB8;
    memcpy(code + 2, &dest, sizeof(dest));
    code[10] = 0xFF;
    code[11] = 0xE0;
#elif defined(__i386__)
    // push imm32 ; ret
    uint8_t *code = reinterpret_cast<uint8_t *>(slot);
    uint32_t dest = static_cast<uint32_t>(replacement);
    code[0] = 0x68;
    memcpy(code + 1, &dest, sizeof(dest));
    code[5] = 0xC3;
#else
    (void)replacement;
    return 0;
#endif

    __builtin___clear_cache(reinterpret_cast<char *>(slot),
                            reinterpret_cast<char *>(slot + kIslandSlotSize));
    page->used++;
    return slot;
}

} // namespace

DetourStatus install_detour(void *target, void *replacement) {
    if (kPatchSize == 0) return DetourStatus::UnsupportedArch;
    if (!target || !replacement) return DetourStatus::NullTarget;

    uintptr_t target_addr = reinterpret_cast<uintptr_t>(target);
#if defined(__arm__)
    // Thumb-функции адресуются с установленным младшим битом и требуют иной
    // кодировки перехода; такие цели пропускаем вместо небезопасного патча.
    if ((target_addr & 1u) != 0) return DetourStatus::UnsupportedArch;
#endif

    std::lock_guard<std::mutex> lock(g_detour_mutex);

    if (std::find(g_hooked_targets.begin(), g_hooked_targets.end(), target_addr) !=
        g_hooked_targets.end()) {
        return DetourStatus::AlreadyHooked;
    }

    std::vector<MapEntry> maps = read_maps();
    MapEntry region{};
    if (!query_region(maps, target_addr, &region) || (region.prot & PROT_EXEC) == 0) {
        return DetourStatus::NotExecutable;
    }

    uintptr_t island = alloc_island_slot(target_addr, reinterpret_cast<uintptr_t>(replacement));
    if (island == 0) return DetourStatus::NoIsland;

    WritableCode guard(target_addr, kPatchSize, region.prot);
    if (!guard.ok) return DetourStatus::ProtectFailed;

#if defined(__aarch64__)
    intptr_t delta = static_cast<intptr_t>(island) - static_cast<intptr_t>(target_addr);
    intptr_t imm26 = delta >> 2;
    if (imm26 > 0x1FFFFFF || imm26 < -0x2000000) return DetourStatus::NoIsland;
    uint32_t branch = 0x14000000u | (static_cast<uint32_t>(imm26) & 0x03FFFFFFu);
    __atomic_store_n(reinterpret_cast<uint32_t *>(target_addr), branch, __ATOMIC_RELEASE);
#elif defined(__arm__)
    intptr_t delta = static_cast<intptr_t>(island) - static_cast<intptr_t>(target_addr) - 8;
    intptr_t imm24 = delta >> 2;
    if (imm24 > 0x7FFFFF || imm24 < -0x800000) return DetourStatus::NoIsland;
    uint32_t branch = 0xEA000000u | (static_cast<uint32_t>(imm24) & 0x00FFFFFFu);
    __atomic_store_n(reinterpret_cast<uint32_t *>(target_addr), branch, __ATOMIC_RELEASE);
#elif defined(__x86_64__) || defined(__i386__)
    intptr_t delta = static_cast<intptr_t>(island) - static_cast<intptr_t>(target_addr) - 5;
    if (delta > 0x7FFFFFFF || delta < -0x7FFFFFFF) return DetourStatus::NoIsland;
    uint8_t patch[5];
    int32_t rel = static_cast<int32_t>(delta);
    patch[0] = 0xE9;
    memcpy(patch + 1, &rel, sizeof(rel));
    memcpy(reinterpret_cast<void *>(target_addr), patch, sizeof(patch));
#endif

    __builtin___clear_cache(reinterpret_cast<char *>(target_addr),
                            reinterpret_cast<char *>(target_addr + kPatchSize));

    g_hooked_targets.push_back(target_addr);
    g_detour_count++;
    return DetourStatus::Ok;
}

bool is_detoured(void *target) {
    if (!target) return false;
    uintptr_t addr = reinterpret_cast<uintptr_t>(target);
#if defined(__arm__)
    addr &= ~static_cast<uintptr_t>(1);
#endif
    std::lock_guard<std::mutex> lock(g_detour_mutex);
    return std::find(g_hooked_targets.begin(), g_hooked_targets.end(), addr) !=
           g_hooked_targets.end();
}

size_t detour_count() {
    std::lock_guard<std::mutex> lock(g_detour_mutex);
    return g_detour_count;
}

void detour_island_stats(size_t *pages_out, size_t *slots_used_out) {
    std::lock_guard<std::mutex> lock(g_detour_mutex);
    if (pages_out) *pages_out = g_islands.size();
    if (slots_used_out) {
        size_t used = 0;
        for (const auto &p : g_islands) used += p.used;
        *slots_used_out = used;
    }
}

} // namespace smartreward
