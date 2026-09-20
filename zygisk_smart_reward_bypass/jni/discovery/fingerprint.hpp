#pragma once

#include <string>
#include <vector>
#include "../runtimes/il2cpp/il2cpp_symbols.hpp"
#include "../runtimes/il2cpp/il2cpp_catalog.hpp"

namespace smartreward {

struct GameFingerprint {
    std::string package_name;
    std::string engine = "Unity IL2CPP";
    std::string unity_version = "Unknown";
    std::string abi;
    size_t assemblies_count = 0;
    size_t methods_seen = 0;
    size_t total_methods_indexed = 0;
    bool scan_truncated = false;
    std::vector<std::string> detected_sdks;
    std::vector<MethodDescriptor> candidates;
};

class FingerprintCollector {
public:
    static GameFingerprint build_from_index(
            const std::string &package_name,
            size_t assemblies_count,
            const std::vector<std::string> &sdks,
            MetadataIndex &index);

    static void score_method(MethodDescriptor &m, const std::vector<std::string> &sdks);
};

} // namespace smartreward
