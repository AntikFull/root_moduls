# Список изменений Analytics & Ads Disabler v5.4.2 (5420)

## v5.4.2

- **Коренное исправление Intent Firewall для полноэкранной рекламы (Google, Yandex, Unity, AppLovin, myTarget, Pangle, Bigo и др.)**:
  - Исправлена работа регулярных выражений `re:` в парсерах `section_match` и `component_matches_rule_section` (сопоставление класса без префикса имени пакета).
  - Снято ошибочное multi-user ограничение в `ifw_filter_global_candidates`, из-за которого правила IFW сбрасывались при наличии второго пользователя (`u999` Dual Apps).
  - Оптимизирована регистрация Activity: устранен медленный IPC-вызов `cmd package query-activities` для Activity из AXML-манифеста самого приложения.
  - По умолчанию активирован режим `COMPONENT_BACKEND=HYBRID` и увеличен лимит правил `MAX_IFW_ACTIVITIES_PER_CATEGORY=256/512`.
- **Полная блокировка рекламы в RuStore и Едадил**:
  - Все рекламные Activity (Fullscreen, Reward, Interstitial, Splash, AdUnit) гарантированно блокируются через Intent Firewall на уровне ядра Android.
  - В `Ad Killer` (цепочка `AAD_ADKILL` в iptables) добавлена мгновенная блокировка сетевых рекламных запросов RuStore (`ads.rustore.ru`, `banners.rustore.ru`, `promo.rustore.ru`, `top-fwz1.mail.ru`, `ad.mail.ru`, `target.my.com`).
  - Отключены фоновые рекламные провайдеры myTarget, AppLovin, ironSource, Mintegral, Vungle, Yandex Ads.

## v5.4.1

- **RuStore Ads & myTarget/VK Ads расширение**: Добавлена полная поддержка блокировки рекламных витрин RuStore (`ads.rustore.ru`, `ads-integration.rustore.ru`, `adv.rustore.ru`, `banners.rustore.ru`, `ru.vk.store.feature.advertisement`, `ru.rustore.sdk.banner`) и расширены эндпоинты myTarget/VK Ads (`top-fwz1.mail.ru`, `ads.vk.com`, `adman.ru`, `m.mradx.net`).
- **Расширение Intent Firewall для полноэкранной рекламы**: Добавлен полный перечень Activity современных версий SDK: Yandex Mobile Ads (v5/v6/v7 Interstitial/Rewarded/Fullscreen/Instream), Huawei PPS Ads, RuStore Ads SDK, VK Ads, Unity Ads, AppLovin MAX, Pangle.
- **Оптимизация базы правил и синхронизация**: Автоматическая фоновая пересборка правил IFW и Ad Killer при обновлении базы правил.

## v5.4.0

- **Anti-DoH / Anti-Private-DNS Bypass (`BLOCK_DOH_BYPASS=1`)**: Ad Killer теперь блокирует прямые обращения рекламных SDK к захардкоженным IP-адресам публичных DoH/DoT серверов (Google, Cloudflare, Yandex, Quad9, AdGuard) по портам TCP 443 и 853 для UID целевых приложений, исключая обход системного DNS.
- **Системное зануление рекламного ID (`ZERO_AD_ID=1`)**: При старте сервиса автоматически выставляются флаги `ad_id_zero 1` и `limit_ad_tracking 1`, вынуждая рекламные аукционы (RTB) возвращать статус `No Fill` (реклама не выкуплена).
- **AppOps Overlay Control (`BLOCK_OVERLAY_ADS=1`)**: Для приложений с агрессивными форматами рекламы (App-Open / Interstitial) автоматически сбрасываются права `SYSTEM_ALERT_WINDOW` и `TOAST_WINDOW` в `ignore`, блокируя всплывающие поверх окон баннеры.
- **WebView Content Blocking (`BLOCK_WEBVIEW_ADS=1`)**: Добавлена systemless-фильтрация рекламных доменов внутри встроенного Android System WebView через `/data/local/tmp/webview-command-line`.
- **Фоновый демон автообновления правил (`rule_updater.sh`)**: Добавлена автоматическая проверка и скачивание обновлённых баз правил `rules.conf` с GitHub с валидацией целостности, фильтром Wi-Fi и проверкой хеша.
- Полная интеграция восстановления прав AppOps и очистки конфигураций при удалении модуля.

## v5.3.2

- Оптимизирован сброс QUIC UDP/443 в Ad Killer: используется явный `REJECT --reject-with icmp-port-unreachable` (IPv4) и `icmp6-port-unreachable` (IPv6), что исключает 1-3 секундные задержки сетевых клиентов перед fallback на TCP.
- Исправлен подсчет выполненных операций в `process_package_all_users`: счетчик `total` теперь корректно аккумулирует результаты обработки всех пользователей.
- Добавлен автоматический сборщик мусора (GC) для устаревших временных файлов `.*.tmp.*` и `.*.running.*` при старте сервиса.
- Нормализованы многострочные литералы `printf` в потоковых операциях и генерации ключей хешей.
- Повышена стабильность блокировок при множественных фоновых событиях.

## v5.3.1

- Удалено безусловное сканирование всех соседних APK: используются только пути base/split APK, принадлежащие конкретному пакету.
- Устранена ошибка `/system/bin/printf: Argument list too long` на OEM-прошивках с общими каталогами overlay.
- Завершение воркеров определяется по атомарным done-маркерам; процессы корректно собираются через `wait`, без многочасового зависания на zombie PID.
- Финальный прогресс `processed=total` записывается один раз вместо повторения каждые две секунды.
- Добавлен watchdog индексатора (30 минут по умолчанию) с сохранением предыдущего успешного индекса при таймауте.
- Добавлен предел 64 APK на пакет как защита от повреждённого или аномального списка путей.
- События пакетов во время активного прохода схлопываются в один отложенный повтор через 60 секунд.
- Action не запускает deep diagnostics и полный перескан параллельно активному Ad Surface Indexer; вместо этого показывает текущий прогресс и безопасно завершается.
- Метаданные релиза и русские строки проверяются как строгий UTF-8 без BOM и CRLF.

## v5.3.0

- Добавлен адаптивный шлюз стабилизации Android перед тяжёлым boot-сканом.
- Ожидание учитывает uptime, boot animation, доступность Package Manager, CPU idle и MemAvailable.
- По умолчанию требуется три спокойных 5-секундных интервала после 120 секунд uptime.
- Максимальное ожидание ограничено 300 секундами; после таймаута модуль продолжает запуск.
- Решение шлюза и измеренные метрики записываются в `boot_trace.log` и `debug.log`.
- Все пороги вынесены в `settings.conf` и сохраняются при обновлении.

## v5.2.0

- Максимум read-only воркеров Ad Surface Indexer увеличен с двух до четырёх.
- Адаптивный лимит по памяти: четыре воркера при 4 ГБ и более, три при 2-4 ГБ, два при 1-2 ГБ, один при объёме менее 1 ГБ.
- Эффективное число воркеров автоматически ограничивается количеством доступных CPU.
- `config_event.sh` отбрасывает внутренние `.surface_*` события до загрузки `common.sh`, исключая лишнюю инициализацию runtime.
- Временные shard/result/progress-файлы получают права 0600.

## v5.1.0

- Ad Surface Indexer использует до двух низкоприоритетных read-only воркеров.
- Каждый воркер пишет в изолированные временные файлы; итоговый индекс объединяется только после успешного завершения всех воркеров.
- При свободной памяти менее 1 ГБ или одном доступном CPU индексатор автоматически переключается на один воркер.
- PM/IFW, базы состояний, восстановление компонентов и Network Killer остаются последовательными.
- При сбое воркера сохраняется предыдущий успешно завершённый индекс.

## v4.9.1

- Network Killer 17 SDK, init-провайдеры, Xposed bridge.
- Адаптивное отключение аналитики и рекламы: SAFE / BALANCED / AGGRESSIVE.
- AXML Full Activity Scanner + Ad Surface Indexer.
- Точный PM rollback и HYBRID IFW+PM.
- Поддержка онлайн-обновления через root-менеджеры.
