#include "target_filter.hpp"
#include "log.hpp"
#include "strings.hpp"

#include <fstream>
#include <cstring>
#include <algorithm>

namespace smartreward {

bool is_protected_process(const char *name, int uid) {
    if (uid < 10000) return true; // Системные UID
    if (!name || !*name) return false;

    // 1. Системные процессы Android и базовые компоненты
    if (strcmp(name, "system_server") == 0 || strcmp(name, "com.android.systemui") == 0) return true;
    if (strncmp(name, "android.", 8) == 0 || strncmp(name, "com.android.", 12) == 0) return true;
    if (strncmp(name, "vendor.", 7) == 0 || strncmp(name, "org.chromium.", 13) == 0) return true;
    if (strncmp(name, "com.google.android.gms", 22) == 0 || strncmp(name, "com.android.vending", 19) == 0) return true;
    if (strncmp(name, "com.google.android.inputmethod", 30) == 0) return true;
    if (strncmp(name, "org.codeaurora.", 15) == 0 || strncmp(name, "com.qualcomm.", 13) == 0) return true;
    if (strncmp(name, "com.qti.", 8) == 0 || strncmp(name, "org.chromium.", 13) == 0) return true;

    // 2. Системные службы OEM-производителей (Xiaomi, Samsung, BBK, Huawei, Transsion)
    if (strncmp(name, "com.oplus.", 10) == 0 || strncmp(name, "com.coloros.", 12) == 0 ||
        strncmp(name, "com.nearme.", 11) == 0 || strncmp(name, "com.heytap.", 11) == 0 ||
        strncmp(name, "com.miui.", 9) == 0 || strncmp(name, "com.xiaomi.", 11) == 0 ||
        strncmp(name, "com.samsung.", 12) == 0 || strncmp(name, "com.sec.", 8) == 0 ||
        strncmp(name, "com.huawei.", 11) == 0 || strncmp(name, "com.hihonor.", 12) == 0 ||
        strncmp(name, "com.transsion.", 14) == 0) {
        return true;
    }

    // 3. Root-менеджеры, хук-фреймворки и системные утилиты
    if (strncmp(name, "com.topjohnwu.magisk", 20) == 0 || strncmp(name, "me.weishu.kernelsu", 18) == 0 ||
        strncmp(name, "me.bmax.apatch", 14) == 0 || strncmp(name, "org.lsposed", 11) == 0 ||
        strncmp(name, "com.termux", 10) == 0 || strncmp(name, "bin.mt.plus", 11) == 0) {
        return true;
    }

    std::string lower_name = to_lower(name);

    auto matches_prefix = [](const std::string &name, const char *prefix) -> bool {
        size_t len = strlen(prefix);
        if (name.length() < len) return false;
        return (name.compare(0, len, prefix) == 0);
    };

    // 4. Веб-браузеры (Edge, Chrome, Yandex, Opera, Firefox, Brave и др.)
    static const char *const s_browser_prefixes[] = {
        "com.microsoft.emmx", "com.android.chrome", "com.chrome.", "ru.yandex.browser", "com.yandex.browser",
        "org.mozilla.firefox", "org.mozilla.fenix", "org.mozilla.focus", "com.opera.browser", "com.opera.mini",
        "com.opera.touch", "com.brave.browser", "com.vivaldi.browser", "com.duckduckgo.", "com.kiwibrowser.",
        "org.torproject.torbrowser", "com.sec.android.app.sbrowser", "com.mi.globalbrowser", "com.heytap.browser"
    };
    for (const char *pref : s_browser_prefixes) {
        if (matches_prefix(lower_name, pref)) return true;
    }

    // 5. Мессенджеры, соцсети и клиенты Telegram (ExteraGram, Nekogram, Plus, WhatsApp, VK и др.)
    static const char *const s_social_prefixes[] = {
        "com.exteragram", "org.telegram.", "nekox.messenger", "com.ime.android", "org.thunderdog.challegram",
        "com.whatsapp", "com.vkontakte.android", "com.vk.im", "ru.vk.messenger", "com.viber.voip",
        "com.discord", "com.skype.raider", "org.thoughtcrime.securesms", "im.vector.app", "org.matrix.",
        "com.zhiliaoapp.musically", "com.ss.android.ugc.trill", "com.instagram.android", "com.facebook.katana",
        "com.google.android.youtube", "app.revanced.android.youtube", "com.vanced.android.youtube",
        "com.spotify.music", "ru.kinopoisk", "ru.yandex.music"
    };
    for (const char *pref : s_social_prefixes) {
        if (matches_prefix(lower_name, pref)) return true;
    }

    // 6. Государственные порталы и сервисы (строгие префиксы)
    static const char *const s_gov_prefixes[] = {
        "ru.gosuslugi.", "ru.nalog.", "ru.rostelecom.esia", "ru.pfr.", "ru.sfr.",
        "ru.fssp.", "ru.mos.", "ru.mosreg.", "ru.emias.", "ru.dnevnik.", "ru.gibdd.", "ru.egisz."
    };
    for (const char *pref : s_gov_prefixes) {
        if (matches_prefix(lower_name, pref)) return true;
    }

    // 7. Банковские, платежные и крипто-приложения (строгие префиксы пакетов)
    static const char *const s_fin_prefixes[] = {
        "ru.sberbank", "com.sber", "com.idamob.tinkoff", "com.tcsbank", "ru.tinkoff", "ru.tbank",
        "ru.vtb", "com.vtb", "ru.alfabank", "com.alfa", "ru.raiffeisen", "ru.gazprombank",
        "ru.rshb", "ru.psbank", "ru.openbank", "ru.sovcomcard", "ru.sovcombank", "ru.pochtabank",
        "ru.yoomoney", "ru.qiwi", "ru.nspk", "ru.mirpay", "ru.sbp", "ru.mts.bank",
        "com.binance.", "com.bybit.", "io.metamask", "com.wallet.crypto.trustapp",
        "com.coinbase.", "com.okex.", "com.bitget."
    };
    for (const char *pref : s_fin_prefixes) {
        if (matches_prefix(lower_name, pref)) return true;
    }

    // 8. Проверка пользовательского deny-list файла (protected.list)
    std::ifstream pfile("/data/adb/zygisk_smart_reward_bypass/protected.list");
    if (pfile.is_open()) {
        std::string line;
        while (std::getline(pfile, line)) {
            std::string item = trim(line);
            if (item.empty() || item[0] == '#') continue;
            std::string l_item = to_lower(item);
            if (lower_name == l_item || matches_prefix(lower_name, l_item.c_str())) {
                return true;
            }
        }
    }

    return false;
}

std::vector<TargetRule> load_target_rules(const char *path) {
    std::vector<TargetRule> rules;
    std::ifstream in(path);
    if (!in.is_open()) {
        return rules;
    }

    std::string line;
    while (std::getline(in, line)) {
        std::string item = trim(line);
        if (item.empty() || item[0] == '#') continue;

        TargetRule rule;
        if (item[0] == '!') {
            rule.is_exclude = true;
            item = trim(item.substr(1));
        }
        if (item.empty()) continue;

        rule.is_exact = (item.find(':') != std::string::npos);
        rule.pattern = item;
        rules.push_back(rule);
    }
    return rules;
}

bool match_process_rules(const std::string &process_name, const std::vector<TargetRule> &rules) {
    if (process_name.empty() || rules.empty()) return false;

    const auto colon = process_name.find(':');
    const bool is_secondary_process = (colon != std::string::npos);
    const std::string base_package = process_name.substr(0, colon);

    // 1. Сначала проверяем исключающие правила (!)
    for (const auto &rule : rules) {
        if (!rule.is_exclude) continue;
        if (rule.is_exact) {
            if (rule.pattern == process_name) return false;
        } else {
            if (rule.pattern == base_package || rule.pattern == "*") return false;
        }
    }

    // 2. Проверяем разрешающие правила
    for (const auto &rule : rules) {
        if (rule.is_exclude) continue;
        if (rule.is_exact) {
            // Точное совпадение (например, package:secondary_process)
            if (rule.pattern == process_name) return true;
        } else {
            // Дочерние процессы (package:process) по умолчанию пропускаем,
            // если для них не задано точное правило с двоеточием
            if (is_secondary_process) {
                continue;
            }
            if (rule.pattern == "*" || rule.pattern == "all") {
                return true; // Универсальный режим (главные процессы всех пользовательских приложений)
            }
            if (rule.pattern == base_package) {
                return true;
            }
        }
    }

    return false;
}

bool is_target_process(const char *process_name) {
    if (!process_name || !*process_name) return false;

    auto rules = load_target_rules("/data/adb/zygisk_smart_reward_bypass/smart_reward.list");
    if (rules.empty()) {
        rules = load_target_rules("/data/adb/modules/zygisk_smart_reward_bypass/smart_reward.list");
    }
    if (rules.empty()) {
        LOGW("Не удалось открыть smart_reward.list; инъекция отключена для безопасности");
        return false;
    }

    return match_process_rules(process_name, rules);
}

} // namespace smartreward
