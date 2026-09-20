#pragma once

#include <string>

namespace smartreward {

struct EngineState {
    bool unity_il2cpp = false;
    bool unity_mono = false;
    bool cocos_cpp = false;
    bool cocos_js = false;
    bool cocos_general = false;
    bool love = false;
    bool luajit = false;
    bool lua = false;
    bool unreal = false;

    bool any_found() const {
        return unity_il2cpp || unity_mono || cocos_cpp || cocos_js ||
               cocos_general || love || luajit || lua || unreal;
    }
};

bool maps_contains_library(const char *soname);
bool find_library_path_in_maps(const char *soname, std::string &out_path);
void *wait_for_loaded_library(const char *soname, int attempts = 100, unsigned int delay_us = 100000);

void probe_native_engines(EngineState &state);
void poll_native_engines(EngineState &state, int max_iterations = 50, unsigned int interval_us = 300000);

} // namespace smartreward
