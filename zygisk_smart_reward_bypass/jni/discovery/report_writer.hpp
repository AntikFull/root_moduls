#pragma once

#include "fingerprint.hpp"
#include <string>

namespace smartreward {

// Persistent per-package advertising profile writer.
// The source of truth lives in the target application's private files directory;
// service.sh mirrors it to /data/adb as root.
class ReportWriter {
public:
    static bool initialize_process(const std::string &package_name, const std::string &process_name, const std::string &app_data_dir = "");
    static bool write_json_report(const GameFingerprint &fp);
    static bool update_telemetry(const std::string &package_name, const std::string &telemetry_json);

    // Generic advertising observation. "trust" must be one of:
    // observed / inferred / synthetic.  Synthetic facts are deliberately kept
    // separate from facts actually received from the game/SDK.
    static bool record_ad_observation(const std::string &package_name,
                                      const std::string &process_name,
                                      const std::string &type,
                                      const std::string &trust,
                                      const std::string &source,
                                      const std::string &sdk,
                                      const std::string &format,
                                      const std::string &identifier,
                                      const std::string &placement,
                                      const std::string &reward_type,
                                      const std::string &reward_amount,
                                      const std::string &detail);

    static bool render_package_report(const std::string &package_name);
};

} // namespace smartreward
