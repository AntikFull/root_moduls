# Analytics & Ads Disabler

> Runtime version metadata is read from `module.prop` (`name`, `version`, `versionCode`) and reused in logs/diagnostics, preventing stale hardcoded version labels.

[ Русский](#русский) | [ English](#english)

---

## <a name="русский"></a>  Описание (Russian)

**Analytics & Ads Disabler** — адаптивный systemless-модуль для Magisk / KernelSU / KernelSU Next / APatch. Режим `SAFE` отключает совпавшие Services/Receivers, `BALANCED` дополнительно обрабатывает только точные Provider-правила. Backend `PM` остаётся стандартным, а опциональный `HYBRID` добавляет IFW-защиту для управляемых Services/Receivers и точных рекламных Activities. Неоднозначные Activity/Provider остаются только в аудите.

### Основные возможности
-  **Runtime Adaptive Engine:** Автоматическая адаптация под версию Android и оболочку (MIUI, HyperOS, OneUI, ColorOS, Pixel и др.).
-  **Экономия заряда и ресурсов:** Отключение фоновых трекеров снижает расход батареи и оперативной памяти.
-  **Блокировка рекламы и трекинга:** Отключение рекламных ресиверов и служб сбора данных (Yandex Metrica, Google Analytics, Firebase, AppMetrica и др.).
-  **Поддержка динамического отслеживания:** Автоматически обрабатывает новые и обновляемые приложения.
-  **Белые списки:** Возможность внесения исключений в `whitelist.list`, `white_ads.list`, `white_analytics.list`.
-  **Аудит компонентов:** Отчёт `component_audit.log` разделяет найденные компоненты по типу, категории, риску и принятому действию.
-  **Изолированный IFW:** HYBRID использует только `/data/system/ifw/analytics_ads_disabler.xml`, не перезаписывая правила App Manager, Blocker и других программ.
-  **Точный откат:** При отключении HYBRID или удалении модуля собственный IFW-файл удаляется, а PM-компоненты возвращаются к сохранённому исходному override.
-  **Без сетевого слоя:** Модуль не изменяет DNS/hosts и не конфликтует с отдельными сетевыми блокировщиками.

---

## <a name="english"></a>  Description (English)

**Analytics & Ads Disabler** is an adaptive systemless module for Magisk, KernelSU/Next and APatch. `SAFE` disables matched Services/Receivers and `BALANCED` additionally handles exact Provider rules. The default backend is `PM`; optional `HYBRID` adds isolated IFW rules for managed Services/Receivers and exact ad Activities. Ambiguous Activity/Provider matches remain report-only.

### Features
-  **Runtime Adaptive Engine:** Automatically adjusts behavior based on Android version and OEM ROM (MIUI, HyperOS, OneUI, ColorOS, Pixel, etc.).
-  **Battery & RAM Saver:** Disabling background telemetry services reduces idle battery drain and frees up memory.
-  **Ad & Telemetry Disabler:** Neutralizes analytics/tracking components (Google Analytics, Firebase, AppMetrica, Yandex Metrica, etc.).
-  **App Monitor:** Automatically applies disabler rules when new apps are installed or updated.
-  **Custom Whitelists:** Highly configurable via `whitelist.list`, `white_ads.list`, and `white_analytics.list`.
-  **Typed Audit:** `component_audit.log` records component type, category, risk, and selected action.
-  **Isolated IFW:** HYBRID owns a single dedicated IFW file and never rewrites third-party rule files.

---

## Автор и Сообщество / Author & Community
- **Автор / Author:** eCubz ([https://t.me/eCubz](https://t.me/eCubz))
- **Telegram Чат / Support Group:** [https://t.me/module_ecubz](https://t.me/module_ecubz)

---

---

---

## Донаты и поддержка / Donations
Ваша поддержка помогает развивать и поддерживать проекты! / Your support helps keep these projects active!

- СБП: `+7 923 618-89-93`
- Т-Банк: [Перевод Т-Банк](https://www.tinkoff.ru/rm/r_qoRUrMgqrw.gQAquXjKzF/ca7Vm7131)
- Ю.Money (Яндекс): [Перевод Ю.Money](https://yoomoney.ru/to/410011494875904)
- Crypto: [USDT | GRAM (Telegram Crypto Bot)](http://t.me/send?start=IVjCT8LiszJ2)
- TON Wallet (USDT): `UQCLyovMu5882XPekfUqXOLFbYFHROaB9uoWMsIaifvMqEC4`

---

## Лицензия / License

Модуль распространяется бесплатно под лицензией MIT. При распространении сохранение авторства **eCubz** и ссылки на канал **https://t.me/module_ecubz** обязательно.


## Policy and whitelist behavior (v4.4.1)

The compatibility backend only decides **how** a PackageManager state change is executed. It never decides **what** may be changed. System protection, global whitelist, category whitelist, ADS/ANALYTICS rules, and safety limits are evaluated first.

If a package is later added to `whitelist.list`, `white_ads.list`, or `white_analytics.list`, reconciliation removes only this module's matching memberships. A component is restored only when no remaining category still requires it, and restoration uses the exact override state saved before the module first touched that component. Components not tracked by this module are never bulk-enabled.

A verified learned write transport is reused for restore operations as well as disable operations. If it fails, the module falls back through the compatibility restore cascade and verifies the resulting state.


## Realtime config watch (v4.4.1)

When `REALTIME_MONITOR=1` and BusyBox `inotifyd` is available, changes to `settings.conf`, `rules.conf`, `whitelist.list`, `white_ads.list`, and `white_analytics.list` trigger an immediate policy reconciliation. The watcher listens on the module data directory so both direct writes and atomic replace/rename saves are detected. A hash-based polling loop remains enabled as a safety net and deduplicates events under the global operation lock.


### Config file paths (v4.4.8+)
The authoritative configuration lives in `/data/adb/analytics_ads_disabler/`. For convenience, the same filenames under `/data/adb/modules/analytics_ads_disabler/` are symlinks to those persistent files, so either path is safe to edit.

### Log file paths (v4.4.10+)
All module log files (`debug.log`, `diagnostics.log`, `boot_trace.log`, `install_diagnostics.log`, `uninstall.log`, `component_audit.log`) are consolidated under `/data/adb/analytics_ads_disabler/logs/`. External user-accessible copies are mirrored under `/sdcard/eCubz/logs/Analytics_Ads_Disabler/`.


### v4.4.10 log reliability

- `/data/adb/analytics_ads_disabler/logs/` is authoritative.
- `/sdcard/eCubz/logs/Analytics_Ads_Disabler/` is refreshed best-effort by a dedicated mirror worker about every 10 seconds; mirror failures never block scanning.
- `debug.previous.log` preserves the immediately previous boot/runtime debug log before `debug.log` is cleared.
- Legacy pre-unified log files are copied once to `*.legacy.log` names during upgrade when available.
- `uninstall.log` is copied to the external log directory before persistent module state is removed.

### Android 16 PackageManager transport

On API 36+, component-state writes do not use real shell UID 2000 as a fallback. The compatibility transport keeps uid 0 and can enter `u:r:shell:s0` only for a bounded PackageManager command. PackageManager stdin is always `/dev/null`, so no module state-file descriptor is transferred through Binder. Older Android releases keep the legacy fallback path.
