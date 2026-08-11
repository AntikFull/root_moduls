# Zapret2 eCubz

[Русский](#zapret2-ecubz) | [English](#zapret2-ecubz-english-version)

---

**Разработчик:** [eCubz (4PDA)](https://4pda.to/forum/index.php?showuser=1266125)  
**TG Сообщество модуля:** [https://t.me/module_ecubz](https://t.me/module_ecubz) — Проект находится в разработке, нужна обратная связь.  
**Исходный код:** [github.com/AntikFull/root_moduls/tree/main/zapret2-module](https://github.com/AntikFull/root_moduls/tree/main/zapret2-module)

Надежный обход блокировок и замедления ресурсов (YouTube, Discord и др.) на вашем Android-устройстве без использования сторонних VPN-сервисов.

Это Magisk / KernelSU / APatch модуль, работающий на базе мощного движка `nfqws` (проект zapret). Он перехватывает и модифицирует сетевые пакеты прямо на устройстве, позволяя вернуть привычную скорость работы популярных ресурсов.

---

## Требования

- **Android 6.0+**
- **Root**: Magisk / KernelSU / KernelSU Next / APatch
- **Архитектуры**: ARM64 / ARM / x86_64 / x86

---

## Что умеет

- Выбор приложений прямо в WebUI;
- Режимы `INCLUDE` / `EXCLUDE` / `GLOBAL`;
- Обход DPI для YouTube, мессенджеров, браузеров и других приложений;
- Автоматическое применение после выбора приложения — отдельная кнопка «Сохранить» не нужна;
- Поддержка Wi-Fi Hotspot и USB-раздачи;
- Раздача интернета через VPN телефона (VPN Tethering);
- Если VPN пропал — по умолчанию клиенты автоматически переходят на AntiDPI, а не остаются без интернета;
- Блокировка QUIC/HTTP3 с переводом соединения на TCP;
- Опциональное перенаправление DNS клиентов раздачи;
- AUTO-стратегия с автоматическим безопасным переходом на SIMPLE, если ядро не поддерживает нужные возможности;
- Material 3 Expressive WebUI;
- Встроенные логи, диагностика и проверка состояния NFQUEUE/ядра.

---

<details>
<summary><b>Возможности WebUI</b></summary>

- **Выбор режима работы:** Весь трафик устройства, «Исключать выбранные приложения» (`EXCLUDE`) или «Только для выбранных приложений» (`INCLUDE`).
- **Списки доменов и исключений:** Управление доменными списками и дополнительными стратегиями обхода прямо в текстовом поле интерфейса.
- **Быстрое управление приложениями:** Удобный поиск по названию пакета, отображение иконок и переключатели `INCLUDE`/`EXCLUDE` для любого установленного приложения.
- **Настройка QUIC & TCP:** Гибкое управление трафиком HTTP/3 (QUIC) и функцией TCP fallback.
- **Логи в реальном времени:** Просмотр журнала работы службы `nfqws` прямо с экрана настроек.
</details>

<details>
<summary><b>Техническая информация</b></summary>

- **Сетевой стек:** `iptables` с поддержкой `NFQUEUE`. Для стандартного per-app режима — поддержка `owner/xt_owner`.
- **Совместимость бинарников:** Сами вложенные `nfqws2`-бинарники собраны с минимальной целью Android API 21 (Android 5.0), но практический рекомендуемый минимум для модуля — Android 6.0+. В частности, текущий Magisk официально поддерживает Android 6.0+.
- **Интерфейс управления:** Полный WebUI с приложениями, названиями и иконками ориентирован в первую очередь на KernelSU / KernelSU Next / APatch WebUI API. Основная сетевая часть модуля при этом не зависит от WebUI и работает через конфиг/Action/CLI и с другими root-менеджерами.
- **Режимы ядра:** Для режима AUTO ядро должно поддерживать `nf_conntrack_acct` + `CONNMARK/connmark` + `xt_connbytes`. Если чего-то из этого нет, модуль автоматически использует рабочую стратегию `SIMPLE`. Отсутствие `xt_connbytes` не мешает пользоваться модулем.
- **Поддержка IPv6:** Для AntiDPI по IPv6 нужны `ip6tables` + `IPv6 NFQUEUE` + `owner`. Если этих возможностей нет, IPv4 продолжает работать, а модуль показывает соответствующий compatibility-статус.
- **Маршрутизация Hotspot/USB:** Для VPN → Hotspot/USB дополнительно нужны рабочие `ip rule/policy routing`, `FORWARD` и `MASQUERADE` в ядре/netfilter. VPN-интерфейс и интерфейс раздачи определяются динамически (`tun0` или `wlan2` не являются обязательными именами).
- **Upstream Zapret:** Сам upstream Zapret подтверждает, что transparent `nfqws` на Android требует root и использует NFQUEUE. Android-ядра в общем случае имеют поддержку NFQUEUE.
- **Требования Root-менеджеров:** Отдельно root-менеджеры имеют свои требования к ядру: KernelSU Next заявляет поддержку ядер 4.4–6.6, а APatch — 3.18–6.12 (ARM64). Это требования способов получения root, а не самого модуля Zapret2 eCubz.
</details>

---

> **Важно:** Результат зависит от провайдера и прошивки. При конфликте с VPN, фильтраторами или другими DPI-модулями используйте только один сетевой модуль одновременно.
> 
> *Проект создан в образовательных целях.*
>
> *После установки и перезагрузки бывает, что служба не стартует сразу — подождите пару минут (пока система полностью прогрузится), зайдите в модуль и нажмите «Перезапустить модуль» (в WebUI или через action.sh).*

---

## Поддержать проект / Донаты

Если вам нравится модуль и вы хотите поддержать дальнейшую разработку, обновления и улучшение функционала:

- **Telegram канал поддержки:** [https://t.me/module_ecubz](https://t.me/module_ecubz)
- **Связаться с автором:** [https://t.me/eCubz](https://t.me/eCubz)

Ваша поддержка помогает проекту активно развиваться, выходить частым обновлениям и поддерживать совместимость с новыми версиями Android и прошивок.

---

# Zapret2 eCubz (English Version)

**Developer:** [eCubz (4PDA)](https://4pda.to/forum/index.php?showuser=1266125)  
**TG Community:** [https://t.me/module_ecubz](https://t.me/module_ecubz) — Project is under active development, feedback is welcome.  
**Source Code:** [github.com/AntikFull/root_moduls/tree/main/zapret2-module](https://github.com/AntikFull/root_moduls/tree/main/zapret2-module)

Reliable bypass of DPI throttling and resource blocking (YouTube, Discord, etc.) on your Android device without third-party VPN services.

This is a Magisk / KernelSU / APatch module powered by the high-performance `nfqws` engine (zapret project). It intercepts and modifies network packets on-device, restoring speed and access to popular web services.

---

## Requirements

- **Android 6.0+**
- **Root**: Magisk / KernelSU / KernelSU Next / APatch
- **Architectures**: ARM64 / ARM / x86_64 / x86

---

## Key Features

- Per-app selection directly inside WebUI;
- Operating modes: `INCLUDE` / `EXCLUDE` / `GLOBAL`;
- DPI bypass for YouTube, instant messengers, web browsers, and other apps;
- Instant automatic rule application upon app selection (no "Save" button required);
- Wi-Fi Hotspot and USB Tethering support;
- VPN Tethering (sharing phone's active VPN connection to tethered devices);
- AntiDPI fallback: if VPN connection drops, tethered clients automatically fallback to AntiDPI mode instead of losing internet;
- QUIC / HTTP3 blocking with seamless TCP fallback enforcement;
- Optional DNS redirection for tethered clients;
- AUTO strategy with graceful fallback to SIMPLE mode if kernel features are missing;
- Modern Material 3 Expressive WebUI;
- Integrated logging, diagnostic utilities, and NFQUEUE/kernel feature probes.

---

<details>
<summary><b>WebUI Capabilities</b></summary>

- **Mode Switching:** Global device traffic, "Exclude selected applications" (`EXCLUDE`), or "Only selected applications" (`INCLUDE`).
- **Domain & Exclusion Lists:** Edit target domain lists and custom bypass strategies directly inside the WebUI text editor.
- **Fast Application Management:** Convenient app search by package/label, dynamic icon rendering, and `INCLUDE`/`EXCLUDE` toggles for installed apps.
- **QUIC & TCP Control:** Flexible HTTP/3 (QUIC) blocking and TCP fallback configuration.
- **Real-Time Logs:** View live `nfqws` daemon logs directly from the settings interface.
</details>

<details>
<summary><b>Technical Details</b></summary>

- **Network Stack:** Uses `iptables` with `NFQUEUE` target. Standard per-app filtering relies on `owner/xt_owner` kernel modules.
- **Binary Compatibility:** Bundled `nfqws2` binaries are compiled targeting Android API 21+ (Android 5.0+), though Android 6.0+ is recommended for optimal system behavior.
- **Management Interfaces:** Full WebUI with app icons is designed primarily for KernelSU / KernelSU Next / APatch WebUI API. Core network engine is independent of WebUI and can be managed via config files, `action.sh`, or CLI.
- **Kernel Requirements for AUTO Mode:** Requires `nf_conntrack_acct` + `CONNMARK/connmark` + `xt_connbytes`. If any feature is missing, the module automatically falls back to `SIMPLE` mode without breaking functionality.
- **IPv6 Support:** Requires `ip6tables` + `IPv6 NFQUEUE` + `owner`. If missing, IPv4 AntiDPI continues to function properly while reporting compatibility status.
- **Hotspot & Tether Routing:** VPN → Hotspot/USB sharing requires working `ip rule/policy routing`, `FORWARD`, and `MASQUERADE` in netfilter. Interfaces are detected dynamically (names like `tun0` or `wlan2` are not hardcoded).
- **Upstream Compatibility:** Upstream Zapret confirms that transparent `nfqws` on Android requires root privileges and `NFQUEUE`. Most Android kernels include `NFQUEUE` support out of the box.
</details>

---

> **Important:** Performance depends on your ISP and ROM environment. Do not run multiple network/DPI bypass modules or conflicting VPN apps simultaneously.
> 
> *Created for educational and research purposes.*
> 
> *If the service does not start immediately after reboot, please wait 1-2 minutes for system services to complete initialization, then open the module and click "Restart module" (in WebUI or via action.sh).*

---

## Support the Project / Donations

If you find this module helpful and wish to support its ongoing development, bug fixes, and feature updates:

- **Telegram Channel & Support:** [https://t.me/module_ecubz](https://t.me/module_ecubz)
- **Contact Developer:** [https://t.me/eCubz](https://t.me/eCubz)

Your support helps keep the project active, updated, and compatible with the latest Android releases and custom ROMs.
