# 🚀 Android Root Modules Collection by eCubz

<div align="center">

[![Android](https://img.shields.io/badge/Android-7.0%20--%2016-brightgreen.svg?style=for-the-badge&logo=android)](https://github.com/AntikFull/root_moduls)
[![Root Environments](https://img.shields.io/badge/Root-Magisk%20%7C%20KernelSU%20%7C%20APatch-orange.svg?style=for-the-badge&logo=rooted)](https://github.com/AntikFull/root_moduls)
[![Telegram Channel](https://img.shields.io/badge/Telegram-@module__ecubz-blue.svg?style=for-the-badge&logo=telegram)](https://t.me/module_ecubz)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge)](LICENSE)

**Официальный репозиторий systemless-модулей нового поколения для Magisk, KernelSU, KernelSU Next и APatch.**
<br>
*Official repository of next-generation systemless modules for Magisk, KernelSU, KernelSU Next, and APatch.*

[🇷🇺 Русский](#-русский-раздел) • [🇬🇧 English](#-english-section) • [📦 Скачать релизы](#-прямые-ссылки-на-загрузку--direct-downloads) • [💬 Сообщество](#-автор-и-сообщество--author--community)

</div>

---

## 🇷🇺 Русский раздел

Коллекция высокопроизводительных, энергоэффективных модулей от **eCubz**, ориентированных на решение реальных задач: системный обход блокировок и замедлений (YouTube, Discord), отключение системной телеметрии и рекламы, бесплатная раздача интернета без доплат и доступ к зарубежным AI-сервисам без глобального VPN.

### 📦 Каталог модулей

| Модуль | Актуальная версия | Описание | Поддерживаемые среды |
| :--- | :--- | :--- | :--- |
| **[zapret2-android](./zapret2-android)** | `v4.0.5` | Системный обход DPI-блокировок (YouTube 4K, Discord, сайты) на базе `nfqws2`/`tpws` + точечный туннель для любых приложений. Работает на уровне ядра: 0% оверхеда по батарее, поддержка обхода на раздаче (Hotspot/Wi-Fi). | Magisk / KernelSU / APatch (Android 7–16) |
| **[analytics_ads_disabler](./analytics_ads_disabler)** | `v7.0.1` | Блокировка рекламы и аналитики внутри процессов приложений через Zygisk: штатное выключение SDK, сетевой перехват по стеку вызовов, схлопывание баннеров, закрытие полноэкранной рекламы. Без списков доменов в основе и без сканирования APK. | **Zygisk обязателен**: Magisk с Zygisk / KernelSU + ZygiskNext или ReZygisk / APatch (Android 8–16) |
| **[AIUnblock](./AIUnblock)** | `v3.0.5` | Автоматическая избирательная маршрутизация для приложений искусственного интеллекта (ChatGPT, Gemini, Claude, Grok, NotebookLM, Perplexity) без включения VPN на весь телефон. | Magisk / KernelSU / APatch |
| **[nfqttl_ecubz](./nfqttl_ecubz)** | `v15.1.5` | Smart Multi-Engine фиксация TTL (IPv4) и Hop Limit (IPv6) с защитой от утечек и выделенной таблицей VPN-маршрутизации для обхода ограничений операторов на раздачу интернета. | Magisk / KernelSU / APatch |
| **[alice-bt-launcher](./alice-bt-launcher)** | `v1.1.0` | Автоматический фоновый запуск и контроль процессов голосового ассистента Алиса AI при подключении Bluetooth-наушников или гарнитуры. | Magisk / KernelSU / APatch |

---

### 🌟 Ключевые преимущества
- ⚡ **Нулевое влияние на батарею:** Модули работают через системные фильтры ядра (`iptables`, `nftables`, Android Package Manager), не создавая фоновых виртуальных сетевых интерфейсов VPN.
- 🛡 **100% Systemless:** Ни один системный раздел (`/system`, `/vendor`, `/product`) не перемонтируется в режим RW. Безопасно для Integrity и SafetyNet.
- 🔄 **Автообновления:** Все модули поддерживают проверку и скачивание обновлений прямо через Magisk App, KernelSU Manager и APatch WebUI.

---

## 🇬🇧 English Section

High-performance, battery-friendly root modules built by **eCubz** designed for everyday Android enhancement: system-level DPI bypass (YouTube, Discord), telemetry/ad disabling, mobile hotspot carrier bypass, and seamless AI routing.

### 📦 Modules Overview

1. **[zapret2-android](./zapret2-android) (v4.0.5)**
   - System-level DPI bypass powered by `nfqws2`/`tpws` and lightweight tunnel for any selected applications.
   - Restores YouTube 4K playback, Discord voice/media, and blocked web resources directly in the kernel netfilter. Zero battery drain compared to classic VPNs. Full hotspot/tethering support.

2. **[analytics_ads_disabler](./analytics_ads_disabler) (v7.0.1)**
   - In-process ad & analytics blocker built on Zygisk. Ad SDKs are identified by class-name signatures instead of domain blocklists, so the rule set stays stable for years.
   - Four layers: the SDK's own GDPR opt-out API, in-process network denial (endpoint list plus call-stack inference), ad container collapsing, and full-screen ad dismissal.
   - No APK scanning, no DEX parsing, no periodic polling. One background process that sleeps in the kernel; zero idle load.
   - Requires Zygisk (Magisk Zygisk / KernelSU + ZygiskNext or ReZygisk / APatch). Website ads inside standalone browsers are out of scope by design.
3. **[AIUnblock](./AIUnblock) (v3.0.5)**
   - Smart transparent routing for AI apps (ChatGPT, Google Gemini, Claude, Grok, NotebookLM, Perplexity) without tunneling full device traffic.
4. **[nfqttl_ecubz](./nfqttl_ecubz) (v15.1.5)**
   - Advanced multi-engine IPv4 TTL & IPv6 Hop Limit locker (iptables/nftables) with Zero-Leak forwarding and dedicated VPN routing table to bypass mobile carrier tethering throttling and extra fees.
5. **[alice-bt-launcher](./alice-bt-launcher) (v1.1.0)**
   - Background daemon for auto-launching and managing Alice AI Assistant when Bluetooth audio devices connect.

---

## 📦 Прямые ссылки на загрузку / Direct Downloads

| Модуль / Module | Ссылка на ZIP / ZIP Direct Link | Размер / Size |
| :--- | :--- | :--- |
| **zapret2-android v4.0.5** | [zapret2-android_v4.0.5_4005.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/zapret2-android_v4.0.5_4005.zip) | ~11.8 MB |
| **analytics_ads_disabler v7.0.1** | [analytics_ads_disabler_v7.0.1_7001.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/analytics_ads_disabler_v7.0.1_7001.zip) | ~425 KB |
| **AIUnblock v3.0.5** | [AIUnblock_v3.0.5_305.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/AIUnblock_v3.0.5_305.zip) | ~9.6 MB |
| **nfqttl_ecubz v15.1.5** | [nfqttl_ecubz_v15.1.5_1515.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/nfqttl_ecubz_v15.1.5_1515.zip) | ~80 KB |
| **alice-bt-launcher v1.1.0** | [alice-bt-launcher_v1.1.0_110.zip](https://raw.githubusercontent.com/AntikFull/root_moduls/main/releases/alice-bt-launcher_v1.1.0_110.zip) | ~7.5 KB |

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

`magisk` • `magisk-module` • `kernelsu` • `kernelsu-module` • `apatch` • `apatch-module` • `zapret` • `zapret2` • `nfqws` • `tpws` • `dpi-bypass` • `youtube-unblock` • `discord-unblock` • `adblock` • `hyperos-debloat` • `miui-debloat` • `telemetry-blocker` • `ttl-fix` • `hop-limit` • `tethering-bypass` • `ai-unblock` • `chatgpt` • `gemini-android` • `claude` • `systemless` • `android-root` • `android-16`

---

## 💬 Автор и Сообщество / Author & Community

- **Автор / Author:** eCubz ([@eCubz](https://t.me/eCubz))
- **Официальный Telegram-канал и поддержка:** [t.me/module_ecubz](https://t.me/module_ecubz)
- **Багрепорты и предложения:** [GitHub Issues](https://github.com/AntikFull/root_moduls/issues)

---

## 💖 Поддержать разработчика / Support & Donations

Ваша поддержка мотивирует развивать проекты, поддерживать базы стратегий и оперативно выпускать фиксы!  
*Your support helps maintain the projects and release regular updates!*

- **СБП (Россия):** `+7 923 618-89-93`
- **Т-Банк:** [Перевод по ссылке Т-Банк](https://www.tinkoff.ru/rm/r_qoRUrMgqrw.gQAquXjKzF/ca7Vm7131)
- **Ю.Money (Яндекс):** [Перевод ЮMoney (410011494875904)](https://yoomoney.ru/to/410011494875904)
- **Crypto Bot (Telegram):** [USDT / TON / GRAM](http://t.me/send?start=IVjCT8LiszJ2)
- **TON Wallet:** `UQCLyovMu5882XPekfUqXOLFbYFHROaB9uoWMsIaifvMqEC4`

---

## 📄 Лицензия / License

Распространяется под лицензией MIT. При повторной публикации или форке сохранение авторства **eCubz** и ссылки на канал **https://t.me/module_ecubz** обязательно.
