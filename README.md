# 🚀 Android Root Modules Collection by eCubz

<div align="center">

[![Android](https://img.shields.io/badge/Android-7.0%20--%2016-brightgreen.svg?style=for-the-badge&logo=android)](https://github.com/AntikFull/root_moduls)
[![Root Environments](https://img.shields.io/badge/Root-Magisk%20%7C%20KernelSU%20%7C%20APatch-orange.svg?style=for-the-badge&logo=rooted)](https://github.com/AntikFull/root_moduls)
[![Telegram Channel](https://img.shields.io/badge/Telegram-@eCubzPlugins-blue.svg?style=for-the-badge&logo=telegram)](https://t.me/eCubzPlugins)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)](LICENSE)

**Официальный репозиторий systemless-модулей нового поколения для Magisk, KernelSU, KernelSU Next и APatch.**
<br>
*Official repository of next-generation systemless modules for Magisk, KernelSU, KernelSU Next, and APatch.*

[🇷🇺 Русский](#-русский-раздел) • [🇬🇧 English](#-english-section) • [📦 Скачать релизы](#-прямые-ссылки-на-загрузку--direct-downloads) • [💬 Сообщество](#-автор-и-сообщество--author--community) • [💖 Поддержать](#-поддержать-разработчика--support--donations)

</div>

---

## 🇷🇺 Русский раздел

Коллекция высокопроизводительных, энергоэффективных модулей от **eCubz**, ориентированных на решение реальных задач: системный обход блокировок и замедлений (YouTube, Discord), мультипрофильный AmneziaWG клиент, отключение системной телеметрии и рекламы, бесплатная раздача интернета без доплат, фиксация беспроводной отладки и доступ к зарубежным AI-сервисам без глобального VPN.

### 📦 Каталог модулей

| Модуль | Актуальная версия | Описание | Поддерживаемые среды |
| :--- | :--- | :--- | :--- |
| **[AWG eCubz](./amneziawg-android)** | `v1.1.3` | Высокопроизводительный multi-profile клиент AmneziaWG (AWG 1.0) с раздельной маршрутизацией приложений (Per-App `uidrange` Priority 9000), умной паузой в доверенных Wi-Fi сетях (Smart Pause), поддержкой диапазонов H1-H4, автоимпортом IncludedApplications, LAN Bypass для домашних сетей, сканером QR-кодов и Material 3 WebUI. | Magisk / KernelSU / APatch (Android 9–16) |
| **[zapret2-android](./zapret2-android)** | `v4.2.9` | Системный обход DPI-блокировок (YouTube 4K, Discord, сайты) на базе `nfqws2`/`tpws` + точечный туннель для любых приложений. Работает на уровне ядра: 0% оверхеда по батарее, поддержка обхода на раздаче (Hotspot/Wi-Fi). | Magisk / KernelSU / APatch (Android 7–16) |
| **[tg-ws-proxy](./tg-ws-proxy)** | `v1.2.0` | Systemless MTProto WS Proxy для ускорения и стабильной работы Telegram без системного VPN. Встроенный WebUI (M3 Expressive), прямой WebSocket к ДЦ Telegram, поддержка Cloudflare Worker/доменов, пресеты батареи и Wi-Fi раздачи. | Magisk / KernelSU / APatch (Android 7–16) |
| **[analytics_ads_disabler](./analytics_ads_disabler)** | `v7.0.2` | Блокировка рекламы и аналитики внутри процессов приложений через Zygisk: штатное выключение SDK, сетевой перехват по стеку вызовов, схлопывание баннеров, закрытие полноэкранной рекламы. Без списков доменов в основе и без сканирования APK. | **Zygisk обязателен**: Magisk / KernelSU + ZygiskNext / APatch (Android 8–16) |
| **[AIUnblock](./AIUnblock)** | `v3.1.1` | Автоматическая избирательная маршрутизация для приложений искусственного интеллекта (ChatGPT, Gemini, Claude, Grok, NotebookLM, Perplexity) без включения VPN на весь телефон. | Magisk / KernelSU / APatch (Android 8–16) |
| **[nfqttl_ecubz](./nfqttl_ecubz)** | `v15.1.5` | Smart Multi-Engine фиксация TTL (IPv4) и Hop Limit (IPv6) с защитой от утечек и выделенной таблицей VPN-маршрутизации для обхода ограничений операторов на раздачу интернета. | Magisk / KernelSU / APatch (Android 7–16) |
| **[adb-wifi-fixed-port](./adb-wifi-fixed-port)** | `v1.1` | Автоматическая фиксация постоянного стандартного порта `5555` для беспроводной отладки ADB при включении Wi-Fi. Больше никаких случайных портов при переподключении. | Magisk / KernelSU / APatch (Android 11–16) |
| **[alice-bt-launcher](./alice-bt-launcher)** | `v1.1.0` | Автоматический фоновый запуск и контроль процессов голосового ассистента Алиса AI при подключении Bluetooth-наушников или гарнитуры. | Magisk / KernelSU / APatch (Android 8–16) |

---

### 🌟 Ключевые преимущества
- ⚡ **Нулевое влияние на батарею:** Модули работают через системные фильтры ядра (`iptables`, `nftables`, Android Package Manager), не создавая фоновых виртуальных сетевых интерфейсов VPN.
- 🛡 **100% Systemless:** Ни один системный раздел (`/system`, `/vendor`, `/product`) не перемонтируется в режим RW. Безопасно для Integrity и SafetyNet.
- 🔄 **Автообновления:** Все модули поддерживают проверку и скачивание обновлений прямо через Magisk App, KernelSU Manager и APatch WebUI.

---

## 🇬🇧 English Section

High-performance, battery-friendly root modules built by **eCubz** designed for everyday Android enhancement: system-level DPI bypass (YouTube, Discord), multi-profile AmneziaWG tunneling, telemetry/ad disabling, mobile hotspot carrier bypass, and seamless AI routing.

### 📦 Modules Overview

1. **[AWG eCubz](./amneziawg-android) (v1.1.3)**
   - Systemless Multi-Profile AmneziaWG (AWG 1.0) client with per-app split routing (`uidrange` kernel rules), Smart Pause in trusted Wi-Fi networks, H1-H4 ranges support, auto-import of IncludedApplications, LAN Bypass for home subnets, QR code import, and modern Material 3 WebUI.

2. **[zapret2-android](./zapret2-android) (v4.2.9)**
   - System-level DPI bypass powered by `nfqws2`/`tpws` and lightweight tunnel for any selected applications. Restores YouTube 4K, Discord voice/media, and blocked sites directly in netfilter.

3. **[tg-ws-proxy](./tg-ws-proxy) (v1.2.0)**
   - Systemless MTProto WebSocket proxy for Telegram acceleration without full-device VPN. Direct WSS tunneling to Telegram DCs, Cloudflare Worker fallback, and Material 3 Expressive WebUI.

4. **[analytics_ads_disabler](./analytics_ads_disabler) (v7.0.2)**
   - In-process ad & analytics blocker built on Zygisk. Ad SDKs are identified by class-name signatures instead of domain blocklists. GDPR opt-out API invocation, in-process network denial, and ad container collapsing.

5. **[AIUnblock](./AIUnblock) (v3.1.1)**
   - Smart transparent routing for AI apps (ChatGPT, Google Gemini, Claude, Grok, NotebookLM, Perplexity) without tunneling full device traffic.

6. **[nfqttl_ecubz](./nfqttl_ecubz) (v15.1.5)**
   - Advanced multi-engine IPv4 TTL & IPv6 Hop Limit locker (iptables/nftables) with Zero-Leak forwarding and dedicated VPN routing table to bypass mobile carrier tethering throttling.

7. **[adb-wifi-fixed-port](./adb-wifi-fixed-port) (v1.1)**
   - Locks wireless ADB debugging to standard port `5555` automatically on Wi-Fi connection, eliminating random ports.

8. **[alice-bt-launcher](./alice-bt-launcher) (v1.1.0)**
   - Background daemon for auto-launching and managing Alice AI Assistant when Bluetooth audio devices connect.

---

## 📦 Прямые ссылки на загрузку / Direct Downloads

| Модуль / Module | Актуальная версия | Ссылка на ZIP / ZIP Direct Link | Размер / Size |
| :--- | :--- | :--- | :--- |
| **AWG eCubz** | `v1.1.4` | [amneziawg-android_v1.1.4_1014.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/amneziawg-android_v1.1.4_1014.zip) | ~10.8 MB |
| **zapret2-android** | `v4.2.9` | [zapret2-android_v4.2.9_4290.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/zapret2-android_v4.2.9_4290.zip) | ~16.4 MB |
| **tg-ws-proxy** | `v1.2.0` | [tg-ws-proxy_v1.2.0_1200.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/tg-ws-proxy_v1.2.0_1200.zip) | ~11.4 MB |
| **AIUnblock** | `v3.1.1` | [AIUnblock_v3.1.1_311.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/AIUnblock_v3.1.1_311.zip) | ~9.6 MB |
| **analytics_ads_disabler** | `v7.0.2` | [analytics_ads_disabler_v7.0.2_7002.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/analytics_ads_disabler_v7.0.2_7002.zip) | ~445 KB |
| **nfqttl_ecubz** | `v15.1.5` | [nfqttl_ecubz_v15.1.5_1515.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/nfqttl_ecubz_v15.1.5_1515.zip) | ~100 KB |
| **adb-wifi-fixed-port** | `v1.1` | [adb_wifi_fixed_port_v1.1_110.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/adb_wifi_fixed_port_v1.1_110.zip) | ~2.3 KB |
| **alice-bt-launcher** | `v1.1.0` | [alice-bt-launcher_v1.1.0_110.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/alice-bt-launcher_v1.1.0_110.zip) | ~6.5 KB |

> 📂 Все предыдущие версии доступны в каталоге [`releases/Archive/`](https://github.com/AntikFull/root_moduls/tree/main/releases/Archive).

---

## 🛠 Установка / Installation

1. Скачайте нужный модуль из таблицы выше.
2. Откройте **Magisk App**, **KernelSU Manager** или **APatch Manager**.
3. Перейдите во вкладку **Модули (Modules)** -> **Установить из хранилища (Install from storage)**.
4. Выберите скачанный `.zip` архив и дождитесь завершения прошивки.
5. Перезагрузите устройство.

---

## 🔍 Теги и поисковая оптимизация / SEO Keywords

`magisk` • `magisk-module` • `kernelsu` • `kernelsu-module` • `apatch` • `apatch-module` • `amneziawg` • `amneziawg-android` • `wireguard` • `tg-ws-proxy` • `telegram-proxy` • `mtproto-proxy` • `zapret` • `zapret2` • `nfqws` • `tpws` • `dpi-bypass` • `youtube-unblock` • `discord-unblock` • `adblock` • `telemetry-blocker` • `ttl-fix` • `hop-limit` • `tethering-bypass` • `adb-wifi` • `ai-unblock` • `chatgpt` • `gemini-android` • `claude` • `systemless` • `android-root` • `android-16`

---

## 💬 Автор и Сообщество / Author & Community

- **Автор / Author:** eCubz ([@eCubz](https://t.me/eCubz))
- **Официальный Telegram-канал:** [t.me/eCubzPlugins](https://t.me/eCubzPlugins)
- **Багрепорты и предложения:** [GitHub Issues](https://github.com/AntikFull/root_moduls/issues)

---

## 💖 Поддержать разработчика / Support & Donations

Ваша поддержка мотивирует развивать проекты, поддерживать базы стратегий и оперативно выпускать регулярные обновления!  
*Your support helps maintain the projects and release regular updates!*

- **Ю.Money (Яндекс) — Предпочтительно / Preferred:**
  - Номер счёта: `4100 1149 4875 904`
  - [Перевод ЮMoney (410011494875904)](https://yoomoney.ru/to/410011494875904)
- **СБП (Россия) / Т-Банк:**
  - Номер: `+7 923 618-89-93`
  - [Перевод по ссылке Т-Банк](https://www.tinkoff.ru/rm/r_qoRUrMgqrw.gQAquXjKzF/ca7Vm7131)
- **Crypto Bot (Telegram):** [USDT / TON / GRAM](http://t.me/send?start=IVjCT8LiszJ2)
- **TON Wallet:** `UQCLyovMu5882XPekfUqXOLFbYFHROaB9uoWMsIaifvMqEC4`

---

## 📄 Лицензия / License

Распространяется под лицензией MIT. При повторной публикации или форке сохранение авторства **eCubz** и ссылки на канал **https://t.me/module_ecubz** обязательно.
