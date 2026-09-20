#include "engine_probe.hpp"
#include "log.hpp"
#include "strings.hpp"

#include <dlfcn.h>
#include <unistd.h>
#include <fstream>
#include <string>
#include <vector>

namespace smartreward {

bool maps_contains_library(const char *soname) {
    std::string path;
    return find_library_path_in_maps(soname, path);
}

bool find_library_path_in_maps(const char *soname, std::string &out_path) {
    if (!soname || !*soname) return false;

    std::ifstream maps("/proc/self/maps");
    if (!maps.is_open()) return false;

    std::string line;
    while (std::getline(maps, line)) {
        if (line.find(soname) != std::string::npos) {
            // Извлекаем путь к файлу из последней колонки строки maps
            auto pos = line.find('/');
            if (pos != std::string::npos) {
                out_path = trim(line.substr(pos));
                return true;
            }
        }
    }
    return false;
}

void *wait_for_loaded_library(const char *soname, int attempts, unsigned int delay_us) {
    if (!soname || !*soname) return nullptr;

    for (int i = 0; i < attempts; ++i) {
        void *h = dlopen(soname, RTLD_NOW | RTLD_NOLOAD);
        if (h) return h;
        usleep(delay_us);
    }

    // Безопасный fallback по полному пути из /proc/self/maps (строго NOLOAD!)
    std::string full_path;
    if (find_library_path_in_maps(soname, full_path)) {
        LOGI("[ENGINE] %s found in /proc/self/maps at '%s'; attempting NOLOAD by full path...", soname, full_path.c_str());
        
        // Безопасная проверка с RTLD_NOLOAD, чтобы не инициировать самостоятельную загрузку чужого движка
        void *h = dlopen(full_path.c_str(), RTLD_NOW | RTLD_NOLOAD);
        if (h) return h;

        LOGW("[ENGINE] %s mapped at %s, but dlopen handle is restricted by linker namespace isolation; diagnostic probe skipping forced load",
             soname, full_path.c_str());
    }

    return nullptr;
}

void probe_native_engines(EngineState &state) {
    struct Candidate {
        const char *soname;
        const char *label;
        bool *target_flag;
    };

    Candidate candidates[] = {
        {"libil2cpp.so", "Unity IL2CPP", &state.unity_il2cpp},
        {"libmono.so", "Unity Mono", &state.unity_mono},
        {"libmonosgen-2.0.so", "Unity Mono", &state.unity_mono},
        {"libcocos2dcpp.so", "Cocos2d-x C++", &state.cocos_cpp},
        {"libcocos2djs.so", "Cocos2d-JS", &state.cocos_js},
        {"libcocos.so", "Cocos General", &state.cocos_general},
        {"liblove.so", "LÖVE 2D", &state.love},
        {"libluajit.so", "LuaJIT", &state.luajit},
        {"liblua.so", "Lua", &state.lua},
        {"libUE4.so", "Unreal Engine 4", &state.unreal},
        {"libUnreal.so", "Unreal Engine", &state.unreal},
    };

    for (auto &c : candidates) {
        if (*(c.target_flag)) continue; // Уже найден, пропускаем

        void *h = dlopen(c.soname, RTLD_NOW | RTLD_NOLOAD);
        if (h) {
            *(c.target_flag) = true;
            LOGI("[ENGINE] detected %s via %s (dlopen handle ok)", c.label, c.soname);
        } else {
            std::string full_path;
            if (find_library_path_in_maps(c.soname, full_path)) {
                *(c.target_flag) = true;
                LOGI("[ENGINE] detected %s via /proc/self/maps (%s)", c.label, full_path.c_str());
            }
        }
    }
}

void poll_native_engines(EngineState &state, int max_iterations, unsigned int interval_us) {
    for (int iter = 0; iter < max_iterations; ++iter) {
        probe_native_engines(state);
        usleep(interval_us);
    }
}

} // namespace smartreward
