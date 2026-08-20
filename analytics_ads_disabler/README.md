# Analytics & Ads Disabler v6.1.6

> **v6.1.6:** Безопасность ContentProvider (AppMetrica / Yandex / FileProvider), гарантированная изоляция Zygisk для браузеров и банков, сохранение Secure DNS (DoH).

> **v6.0.9:** Критические исправления инвентаря путей к APK и универсальная поддержка Multi-App/вторичных профилей (User 999, User 10, User 2); надежный fallback исходного состояния `default`; мгновенная фиксация успешных ответов PackageManager; гарантированная работа всех типов белых списков (`whitelist.list`, `white_analytics.list`, `white_ads.list`).

> **v6.0.8:** Повышение надежности и отказоустойчивости: единый проверенный механизм отката (rollback) для runtime, удаления и отложенных задач; транзакционный пакет восстановления; строгое разделение снимков multi-user; трехпозиционная семантика обнаружения (данные / пусто / ошибка); нейтральная к политике схема кандидатов v3; гарантированная очистка правил фаервола и безопасные повторные попытки для AppOps и сетевых операций.

> **v6.0.7:** Оптимизация FAST-режима на базе глобальной разницы состояний (membership-delta). Неизменившиеся приложения больше не опрашивают PackageManager (`dumpsys package`) при переключении рекламы/аналитики/системных служб; PM вызывается строго для реальных изменений. Исходные состояния и база компонентов сохраняются пакетными транзакциями, а внешние изменения проверяются отдельным фоновым верификатором.

> **v6.0.6:** Полный отказ от LSPosed/Xposed компаньонов. Схлопывание баннеров (Auto-Collapse) работает автономно через встроенный Zygisk и `aad_core.dex`, без внешних APK. Устаревшие файлы моста и настройки Xposed автоматически удаляются при обновлении.

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

