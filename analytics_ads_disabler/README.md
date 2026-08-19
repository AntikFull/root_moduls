# Analytics & Ads Disabler v6.0.8


> **v6.0.8:** Correctness/failure hardening: единый checked rollback для runtime/uninstall/deferred, transactional recovery bundle, authoritative multi-user snapshots, DATA/EMPTY/FAILED discovery semantics, policy-neutral candidate schema v3, verified firewall cleanup и fail-safe AppOps/network retries.

> **v6.0.7:** FAST переведён на глобальный membership-delta. Неизменившиеся пакеты больше не проходят `dumpsys package` при обычном переключении ADS/ANALYTICS/SYSTEM; PM вызывается только для реального add/remove delta. Original state и membership DB коммитятся batch-транзакциями, а внешние изменения проверяет отдельный low-priority verifier.

> **v6.0.6:** LSPosed/Xposed companion bridge удалён из runtime полностью. Auto-Collapse работает через встроенный Zygisk + `aad_core.dex`; отдельный LSPosed/APK-компаньон AAD не требуется. При обновлении старые `xposed_targets.json/list` и ключ `XPOSED_BRIDGE` удаляются автоматически.

**Analytics & Ads Disabler** — универсальный, полностью автономный root-модуль для Magisk / KernelSU / KernelSU Next / APatch, предназначенный для блокировки мобильной рекламы, трекеров и фоновой аналитики.

Автор: `eCubz` (https://t.me/eCubz)  
Группа поддержки и обновлений: https://t.me/module_ecubz  

---

## Архитектура v6.0.0

Версия 6.0.0 представляет обновлённую модель управления:

1. **3 независимых переключателя (Universal 3-Switch Model):**
   - `BLOCK_ADS=1|0` — блокировка рекламных сервисов, ресиверов, точных провайдеров и активностей.
   - `BLOCK_ANALYTICS=1|0` — блокировка служб телеметрии, трекеров и сборщиков данных (Yandex Metrica, AppsFlyer, Firebase, AppMetrica, Adjust и др.).
   - `INCLUDE_SYSTEM_APPS=0|1` — безопасность системы по умолчанию (`0` = только пользовательские приложения; `1` = явный opt-in для системных приложений).
   - Устаревшие режимы (SAFE/BALANCED/AGGRESSIVE/HYBRID/IFW) удалены в пользу прямого PM per-user управления.

2. **Per-User Isolation (Android Multi-User):**
   - Управление компонентами через `pm enable/disable` с поддержкой `--user <id>` для каждого отдельного профиля (Основной, Work Profile, Dual Apps, Secure Folder).
   - Исходные состояния компонентов сохраняются в базе данных модуля (`component_state.list`) для гарантированного возврата в исходное состояние при отключении или удалении.

3. **Сетевой фаервол Ad Killer (`AAD_ADKILL`):**
   - Фильтрация известных рекламных хостов на уровне сокетов через iptables/ip6tables.
   - Полная защита от race conditions и дедлоков благодаря использованию `-w 2` (xtables lock).
   - Блокировка обхода через DoH/DoT и QUIC/UDP-443.

4. **Двухуровневая система правил:**
   - `rules.vendor.conf` — официальная обновляемая база правил модуля.
   - `rules.user.conf` — постоянные пользовательские правила, не перезаписываемые при обновлениях.
   - Композитный `rules.conf` автоматически пересобирается при любых изменениях.

5. **Динамическая защита критических служб:**
   - Автоматическое определение активного Launcher, клавиатуры (IME) и системного WebView провайдера.
   - Защита системных компонентов прошивок HyperOS, OneUI, ColorOS, OriginOS, EMUI и AOSP от случайного отключения.

6. **Zygisk In-Memory View-Collapse:**
   - Нативная интеграция для схлопывания баннерных контейнеров и мокирования Rewarded Ads в изолированных QA-сборках.
   - Строгая fail-closed валидация: целевой процесс, SHA-256 сертификата приложения и DEX-библиотеки.

---


## Быстрая policy-модель v6.0.7

Начиная с v6.0.5 глубокое обнаружение компонентов отделено от обычного применения политики:

- `component_candidates.list` хранит подтверждённые кандидаты последнего deep discovery / package-delta;
- `package_scope.list` хранит per-user классификацию пакета `USER/SYSTEM`, чтобы interactive FAST не повторял системную классификацию каждого пакета;
- FAST строит один глобальный desired membership-set, вычисляет симметричный diff с текущим `disabled_components.list` и вызывает PackageManager только для реально изменившихся компонентов;
- если membership-set компонента меняется только между `ADS` и `ANALYTICS`, выполняется чистый membership hand-off без PM;
- original states для новых owned компонентов сохраняются batch-транзакцией **до** любой мутации, а итоговый membership DB коммитится одним atomic batch;
- внешний re-enable/орphan state проверяет отдельный low-priority ownership verifier, поэтому обычный toggle не перечитывает все owned packages;
- обычные изменения `BLOCK_ADS`, `BLOCK_ANALYTICS` и выключение `INCLUDE_SYSTEM_APPS` применяются из кэша без повторного manifest-аудита всех приложений;
- переход `INCLUDE_SYSTEM_APPS=0 -> 1` при USER-only кэше сканирует только системное расширение, не повторяя пользовательские пакеты;
- каждый reconcile получает неизменяемый snapshot `settings.conf`; изменение настроек во время прохода coalescится в следующую generation, поэтому разные пакеты не должны обрабатываться по разным версиям политики;
- `reconcile.status` и `.applied_generation` позволяют диагностике дождаться именно завершённой generation, а не ориентироваться только на таймаут;
- при обычной загрузке валидный discovery-кэш используется повторно: выполняется package-delta, а полный deep scan нужен только при отсутствующем/устаревшем кэше, изменении правил или ручном полном рескане.

Ручной **RESCAN** из Action Menu остаётся именно глубоким аудитом и поэтому может занимать заметно больше времени, чем обычное переключение трёх основных параметров.

## Конфигурация и управление

Файлы конфигурации расположены в `/data/adb/analytics_ads_disabler/`:

- `settings.conf` — основные параметры работы модуля:
  - `BLOCK_ADS=1`
  - `BLOCK_ANALYTICS=1`
  - `INCLUDE_SYSTEM_APPS=0`
  - `AD_SURFACE_KILLER=1`
  - `ZERO_AD_ID=0`
  - `BLOCK_OVERLAY_ADS=0`
  - `BLOCK_WEBVIEW_ADS=0`
  - `LOG_MIRROR=0`
- `rules.user.conf` — пользовательские паттерны и регулярные выражения.
- `whitelist.list` — глобальный белый список приложений (полное исключение из обработки).
- `white_ads.list` — исключение из блокировки рекламы.
- `white_analytics.list` — исключение из блокировки аналитики.

### Action Menu (Кнопка в Magisk / KSU / APatch)

При нажатии кнопки «Action» в интерфейсе root-менеджера:
- Нажатие **Громкость+** в течение 5 секунд — интерактивное меню настройки (`BLOCK_ADS`, `BLOCK_ANALYTICS`, `INCLUDE_SYSTEM_APPS`).
- Нажатие **Громкость-** или отсутствие нажатия — запуск немедленного полного сканирования и применения правил.

---

## Журналы и диагностика

Все системные логи хранятся в `/data/adb/analytics_ads_disabler/logs/`:
- `debug.log` — операционный лог работы модуля и событий.
- `diagnostics.log` — отчет о возможностях PackageManager и окружения.
- `install_diagnostics.log` — диагностика процесса установки.
- `component_audit.log` — аудит обнаруженных и отключенных компонентов.
- `ad_surface_scan.log` — отчет фонового сканера поверхностей рекламы.
- `reconcile.status` — текущее terminal/running состояние policy generation (`FAST`, `SYSTEM_EXPAND`, `PACKAGE_DELTA`, `DEEP_MANUAL`).
- `.applied_generation` — hash и время последней полностью применённой generation.
- `component_candidates.list` — persistent discovery-кэш для быстрых ADS/ANALYTICS/SYSTEM переключений.
- `package_scope.list` — persistent per-user `USER/SYSTEM` scope-кэш для FAST.
- `.component_verify.pending` — marker отложенной низкоприоритетной проверки ownership после временной PM/commit ошибки.

Зеркалирование логов в `/sdcard/eCubz/logs/Analytics_Ads_Disabler/` по умолчанию выключено (`LOG_MIRROR=0`) для защиты приватности и может быть включено в `settings.conf`.

---

## Удаление и откат изменений

При удалении модуля:
1. Запускается `uninstall.sh`.
2. Если PackageManager доступен, оригинальные состояния компонентов восстанавливаются немедленно.
3. Если удаление инициировано до загрузки Android, создается временный отложенный воркер `/data/adb/analytics_ads_disabler_rollback`, который безопасно восстановит состояние компонентов и системные настройки (AppOps, Ad-ID, WebView) после события `sys.boot_completed`.
