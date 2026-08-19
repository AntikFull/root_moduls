# v6.0.8 / 6008

- **Rollback correctness:** runtime, ordinary uninstall и deferred rollback используют общий authoritative component-state engine; `UNKNOWN` больше не превращается в `default`/external preserve.
- **Transactional uninstall recovery:** deferred bundle строится во временной директории, обязательные assets копируются с verification и публикуются атомарно до удаления source state.
- **Multi-user fail-safe:** failure `cmd user list` или package snapshot больше не означает `user 0 only`/empty inventory; неполная generation не публикуется authoritative.
- **Discovery tri-state:** package/manifest discovery различает authoritative DATA/EMPTY и FAILED; при FAILED прежние audit/candidate/membership rows сохраняются и идут на retry.
- **Policy-neutral candidate schema v3:** manifest discovery больше не зависит от ADS/ANALYTICS/SYSTEM toggles; старые потенциально неполные caches принудительно проходят один authoritative deep rebuild.
- **FAST snapshot gate:** global-delta FAST прекращается, если installed-package snapshot не authoritative.
- **Firewall terminal semantics:** cleanup проверяет отсутствие own jump/master/child chains, missing active backend остаётся PENDING; QUIC/DoH rule failures больше не маскируются success; stale child chains удаляются до batch restore.
- **AppOps apply retry:** read/set/verify failures возвращают nonzero и создают side-effect pending state.
- **Scope/cache hardening:** malformed package-scope/candidate rows инвалидируют cache; missing/corrupt SYSTEM primary key fail-safe OFF и не resurrect legacy `SCAN_SYSTEM_APPS`.
- **Boot rules transaction:** startup использует только central checked `rebuild_composite_rules()`; stale composite не считается допустимым после failed commit.
- **Current-user safety:** inability to resolve current Android user больше не угадывается как user 0.
- **Ad Surface snapshot safety:** failed authoritative package inventory не публикует ложнопустой surface index и сохраняет последний completed index.

# v6.0.7 / 6007

- **Global Delta FAST v2**: обычные ADS/ANALYTICS/SYSTEM переключения больше не выполняют `dumpsys package` для неизменившихся пакетов. Сначала строится единый desired membership-set, затем вычисляется глобальный diff `desired - current` / `current - desired`.
- **PM только для реального delta**: PackageManager read-back/disable/restore выполняются только для компонентов, которые реально добавляются в ownership или выходят из него. No-op generation на валидном cache не делает component PM calls.
- **Batch membership/state transaction**: новые original-state записи сохраняются одной транзакцией до мутаций; итоговый `disabled_components.list` коммитится атомарно одним batch; успешно восстановленные state rows удаляются batch-операцией после membership commit.
- **Fail-safe authoritative state read**: новый компонент не отключается, если его исходный override state нельзя достоверно прочитать. Generation остаётся failed/pending, ownership не придумывается.
- **Rollback UNKNOWN != default**: обычный deep/add path и orphan restore также переведены на authoritative component-state read; временный `dumpsys package` failure больше не может превратить UNKNOWN в `default` и удалить recovery state.
- **Persistent package scope cache**: `package_scope.list` хранит `USER/SYSTEM` классификацию и убирает повторную дорогую системную классификацию из interactive FAST. Cache обновляется package-delta/system-expansion и безопасно перестраивается authoritative package snapshots.
- **Low-priority ownership verifier**: проверка внешнего re-enable и orphan rollback вынесена из interactive FAST в редкий safety/pending verifier. Это сохраняет enforcement/rollback, не заставляя каждый toggle перечитывать все owned packages.
- **Category hand-off без PM**: `ADS↔ANALYTICS` на уже-owned компоненте меняет только membership-set, без промежуточного restore/re-disable и без повторного PackageManager read.
- **Generation safety сохранена**: failed batch/state/PM операции не продвигают `.config.hash`/`.applied_generation`; pending ownership остаётся для повторной проверки.
- LSPosed/Xposed companion bridge остаётся удалённым; upgrade-cleanup v6.0.6 сохранён.

# v6.0.6 / 6006

- Полностью удалён retired LSPosed/Xposed companion bridge из runtime `common.sh`: больше нет framework detection, `XPOSED_BRIDGE` policy и экспорта target-файлов.
- При обновлении автоматически удаляются legacy `xposed_targets.json`, `xposed_targets.list` и их незавершённые `.tmp.*` файлы из data/module paths.
- Legacy-ключ `XPOSED_BRIDGE=...` атомарно удаляется из существующего `settings.conf`, остальные пользовательские настройки сохраняются.
- Native Zygisk + `aad_core.dex` остаются единственным встроенным in-process Auto-Collapse/QA-контуром; внешний LSPosed/APK companion для runtime AAD не требуется.

# v6.0.5 / 6005

- Fast policy reconcile: обычные `BLOCK_ADS` / `BLOCK_ANALYTICS` / `INCLUDE_SYSTEM_APPS` больше не требуют полного manifest discovery всех приложений при валидном candidate cache.
- Generation snapshot + coalescing: один reconcile работает по неизменяемому snapshot настроек; более новая policy не смешивается с уже идущим проходом и применяется следующей generation.
- Persistent `component_candidates.list` + discovery/non-primary hashes; warm boot использует cache и package-delta вместо безусловного deep scan.
- `SYSTEM 0→1` расширяет USER-cache только системными пакетами; частичный/неавторитетный PackageManager snapshot fail-safe оставляет scope `USER` и не применяет неполную policy.
- `SYSTEM 1→0` и category OFF используют текущие memberships/ownership для быстрого restore.
- Category hand-off исправлен: новая membership добавляется до удаления старой, поэтому `ADS↔ANALYTICS` не вызывает временный restore/re-disable одного компонента и не портит original state.
- Overlay AppOps теперь строго ADS-only: analytics-only package не получает ADS overlay restrictions только потому, что `BLOCK_ADS=1` глобально.
- `reconcile.status` и `.applied_generation` добавлены для точного runtime/ADB ожидания terminal generation (`FAST`, `SYSTEM_EXPAND`, `DEEP`, `PACKAGE_DELTA`, `NOOP`).
- `qa_targets.list` теперь действительно участвует в config generation hash.
- Старый v6.0.4 audit может безопасно bootstrap'нуть USER candidate cache только при подтверждённом полном coverage; иначе выполняется deep discovery.

# v6.0.4 / 6004

- Fixed authoritative per-user package snapshots: an empty profile is now a valid successful snapshot, while PackageManager failures remain UNKNOWN and never trigger restore/ownership deletion.
- Added snapshot-validity guard to whitelist/config delta restore.
- Added unified scope re-check at the final firewall mutation boundary; stale targets cannot bypass SYSTEM/whitelist/protected policy.
- AppOps restore now retains unresolved ownership rows and verifies read-back before dropping state.
- Advertising-ID settings restore now uses compare-before-restore, per-user retry state and read-back verification.
- WebView shared-file feature is OFF by default on fresh installs and restore retains backup on failures.
- Rule updater only advances success timestamp after composite rebuild + policy reconcile; failed generations roll back/retry.
- Legacy v5 custom-rule migration preserves section context.
- Installer refuses to delete live state locks and validates exact SHA-256 format.
- Firewall rebuild preserves the existing AAD jump position instead of reinserting at OUTPUT position 1.
- App-event locks now use PID + process starttime ownership.
- Legacy IFW cleanup no longer blocks the PM-only runtime when an old IFW file was modified externally.

# Список изменений Analytics & Ads Disabler

## v6.0.3

- **Двухсторонний Authoritative Snapshot для Multi-User**:
  - Введена раздельная фиксация валидности установленных (`.users_snapshot_ok`) и желаемых (`.users_desired_snapshot_ok`) пакетов.
  - Scope-exit откат разрешён только при одновременной валидности обоих снимков пользователя.
- **Поддержка обновлённых системных приложений и Fail-Safe классификатор**:
  - `cap_is_system_package()` проверяет флаги пакета (`SYSTEM`, `UPDATED_SYSTEM_APP`) для приложений из `/data/app`.
  - Статус UNKNOWN при `INCLUDE_SYSTEM_APPS=0` безопасно трактуется как системное приложение (skip).
- **Сквозной Scope Guard на уровне сети**:
  - Все кандидаты Ad Surface Killer и сетевые цели проходят проверку через `is_package_in_scope "$pkg" "$user"`.
  - Удалён hardcoded обход для RuStore/myTarget.
- **Строгая блокировка AppOps по Primary Policy**:
  - `aad_apply_appops_overlay_control()` напрямую проверяет `BLOCK_ADS=1` и `is_package_in_scope`, исключая применение оверлей-контроля при выключенной блокировке рекламы.
- **Транзакционный Compare-Before-Restore**:
  - Создана единая функция `aad_restore_owned_settings()` с поддержкой per-user строк и проверкой неизменности значений перед откатом.
  - Деинсталлятор и отложенный воркер `rollback.sh` учитывают ошибки всех подсистем (компоненты, AppOps, Ad-ID, WebView) перед удалением каталогов восстановления.
- **Изоляция общего системного файла WebView**:
  - Параметр `BLOCK_WEBVIEW_ADS` переведён в значение `0` по умолчанию, исключая конфликты с глобальным `/data/local/tmp/webview-command-line`.
- **Единый Rule Updater Builder**:
  - `rule_updater.sh` переведён на центральный `rebuild_composite_rules` из `common.sh`, а метка обновления фиксируется только после успешной синхронизации.
- **Умная миграция кастомных правил с v5**:
  - Пользовательские правила из старого `rules.conf` автоматически переносятся в `rules.user.conf` с сохранением их активности.
- **Активация кэша динамических ролей**:
  - Явный экспорт `AAD_PROTECTED_CACHE_ACTIVE=1` на время реконсиляции для оптимизации вызовов Binder.

## v6.0.2

- **Разрыв inotify-петли вокруг `rules.conf`**:
  - `rules.conf` исключён из наблюдения `config_event.sh`, отслеживаются только исходные конфигурационные файлы.
  - Генератор композитных правил `rebuild_composite_rules()` стал строго идемпотентным (проверка `cmp -s`).
- **Строгая иерархия Primary Policy**:
  - Все side-effects (`ZERO_AD_ID`, `BLOCK_WEBVIEW_ADS`, `BLOCK_OVERLAY_ADS`, firewall) теперь строго подчиняются главным переключателям `BLOCK_ADS` и `BLOCK_ANALYTICS`. При их отключении все системные модификации полностью и транзакционно откатываются.
- **Единый безопасный Boot-путь Side Effects**:
  - Удалены дублированные функции из `service.sh`, все side-effects применяются через единый `reconcile_side_effects "boot"` с адаптивной проверкой окружения.
- **Повышение надежности Multi-User и PackageManager**:
  - Внедрена функция `cap_is_system_package` и единый guard `is_package_in_scope` для всех стадий мутации.
  - Добавлена авторизованная валидация снимков каждого Android-пользователя, исключающая ошибочное удаление записей при сбоях Binder.
  - Кэширование динамически защищённых системных ролей (Launcher, IME, WebView) per-user.
- **Fail-Closed верификация целостности**:
  - Установщик `customize.sh` гарантирует валидацию 64-hex SHA-256 манифеста с поддержкой альтернативных утилит (sha256sum, busybox, openssl).
  - Восстановлена функция `install_diag()`.
- **Полная приватность логов**:
  - При `LOG_MIRROR=0` отключена любая фоновая запись и создание каталогов на `/sdcard`.

## v6.0.1

- **Включение `ZERO_AD_ID=0` по умолчанию**:
  - Автоматическое обнуление Google Advertising ID (`00000000-0000-0000-0000-000000000000`) и активация системного запрета таргетинга `limit_ad_tracking=1` прямо из коробки.
- **Адаптивная поддержка `BLOCK_WEBVIEW_ADS=0` по умолчанию**:
  - Добавлена интеллектуальная проверка среды (`aad_is_webview_command_line_supported`): флаги командной строки WebView применяются, если прошивка поддерживает их чтение (userdebug/eng/debuggable или включены параметры разработчика / ADB), и безопасно пропускаются на production user-прошивках без ошибок.

## v6.0.0

- **Архитектурная концепция: «Один универсальный движок + три переключателя»**:
  - Полностью исключены технические режимы (`SAFE`, `HYBRID`, `PM`, `IFW limits`) из пользовательского интерфейса и конфигурации.
  - Конфигурация сведена к 3 понятным параметрам: `BLOCK_ADS=1`, `BLOCK_ANALYTICS=1`, `INCLUDE_SYSTEM_APPS=0`.
  - В интерактивном установщике задаются только 3 вопроса клавишами громкости.
- **PM per-user как единственный компонентный бэкенд**:
  - Полный отказ от глобального IFW в основном контуре: исключены риски межпрофильных коллизий (Work Profile, Dual Apps, Secondary User).
  - Изолированное отключение компонентов отдельно для каждого Android-пользователя и профиля.
- **Композитная система списков правил (Vendor vs Local)**:
  - Правила разделены на `rules.vendor.conf` (обновляемые из репозитория) и `rules.user.conf` (кастомные правила пользователя).
  - Автообновлятор правил больше никогда не перезаписывает и не удаляет пользовательские правила.
- **Централизованный xtables Wrapper и Dual-Stack Lifecycle**:
  - Внедрен централизованный wrapper `aad_iptables` / `aad_ip6tables` с автоматическим определением и применением блокировки `-w 2` (xtables lock).
  - Исправлен health-check сетевого фильтра: проверяются только реально активированные семейства протоколов (IPv4/IPv6), полностью исключая цикл перезапуска firewall.
- **Автоматический Integrity Manifest**:
  - Автоматический расчет SHA-256 для `aad_core.dex` и `.so` библиотек в build-пайплайне с генерацией `integrity.manifest` и автосинхронизацией `qa_targets.list`.
- **Усиление модели владения (Ownership Matrix) и защита приватности**:
  - Надежный regex-парсер режима AppOps, исключающий зависимость от порядка токенов в выводе OEM-прошивок.
  - Расширение deferred rollback bundle на `.appops_state` и `.ad_id_backup`.
  - Зеркалирование логов переведено в режим `LOG_MIRROR=0` по умолчанию для защиты приватности идентификаторов пакетов на открытом накопителе.

## v5.9.11

- **Комплексное устранение замечаний аудита безопасности (P0-P3)**:
  - **Безопасность загрузки правил (`rule_updater.sh`)**: удален обход TLS сертификатов, добавлена обязательная проверка SHA-256 хеша и валидация структуры секций правил.
  - **Диспетчеризация `service.sh`**: добавлен отдельный вход для `reconcile-rules` и `status`, исключающий удаление активных блокировок и гонки процессов на работающей системе.
  - **Модель владения ресурсами (Ownership Matrix)**: точный откат и сохранение исходных состояний для AppOps (`.appops_state`), системных параметров Settings (`.settings_snapshot`), IFW XML и `webview-command-line`.
  - **Безопасность Zygisk**: удалены небезопасные fallback-пути, усилена проверка прав root (`is_secure_root_file`), неразрушающие хуки `OnGlobalLayoutListener` с debounce.
  - **Корректность конфигурации**: устранены дублирующиеся параметры, синхронизированы дефолты между `settings.conf`, `customize.sh` и `README.md`.
  - **Сетевая стабильность**: добавлена поддержка xtables lock (`-w 2`) в iptables, раздельная валидация состояния IPv4 и IPv6.

## v5.9.9

- **Аппаратный Machine Code Trampoline для IL2CPP хуков**: заменён `set_method_pointer` на аппаратный 16-байтный ARM64/ARM32 трамплин `redirect_function` для перехвата прямых скомпилированных вызовов `ShowRewardedAd`, `ShowInterstitial`, `ShowRewardedInterstitialAd`, `HandleBackgroundCallback`.
- **Прямой вызов событий через C-API IL2CPP**: вызов `MaxSdkCallbacks.ForwardEvent` напрямую через указатель C# метода с созданием `Il2CppString` для мгновенной выдачи наград без завязки на `UnitySendMessage`.
- **Автоматический обход встроенных операций игры**: редирект `PurchasingManager.PurchaseWithRewardedVideo` -> `PurchaseImmediatelyWithRewardedVideo`, `AdShowOperation.CompleteFailed` -> `Complete`, патчинг `AdShowOperation.get_Result` -> 0 (`ShowAdResult.Success`).
- **Исправление PATH для KernelSU**: добавлена обязательная системная инициализация `PATH` в `common.sh`, `service.sh` и `compat.sh` для устранения ошибок вызова утилит toybox/busybox.

## v5.9.1

- Добавлена certificate-first авторизация Zygisk и обязательная проверка SHA-256 DEX до загрузки.
- IL2CPP профили теперь привязаны к scope, ABI, SHA-256 библиотеки и точным типам методов.
- Исправлен Thumb-2 trampoline для адресов с выравниванием 2 mod 4.
- Исправлены token cancellation, очистка сессий и lifecycle listeners в AadCore.
- DEX-сборка очищает временные классы перед javac/d8.
- Auto updater выключен по умолчанию и проверяет hash fail-closed.
- Добавлен Compare-Before-Restore для компонентов, settings, IFW и WebView command line.
- Удалены runtime-зависимости и документация LSPosed Companion.

## v5.8.0

- Исправлен ABI Zygisk: самодельный layout API v4 заменён совместимым публичным API v5; устранено падение `zygote64` при `forkSystemServer` в ReZygisk.
- Zygisk IL2CPP переведён с жёстких RVA на экспортный C API (`domain -> assemblies -> image -> class -> method`).
- Добавлены конфигурируемые `READY` и `SHOW_REWARD` контракты с arm/arm64 trampoline и 16 KB page alignment.
- Java rewarded-моки вынесены в LSPosed Companion для AppLovin MAX, Google Mobile Ads, Yandex Mobile Ads и ironSource/LevelPlay.
- Все in-process хуки работают fail-closed только для точного `qa_targets.list`; системные UID и `system_server` исключены.

## v5.7.0

- **Universal Unity IL2CPP Native Hooking (`libil2cpp.so`)**:
  - Нативный C++ перехватчик памяти и C-API IL2CPP внутри Zygisk-движка.
  - Автоматическое динамическое сканирование и патчинг функций доступности рекламы (`IsAdAvailable`, `IsReady`, `IsRewardedVideoAvailable`, `HasAd`, `CanWatchAd` -> return true) прямо в бинарном коде ARM64/ARM32 `libil2cpp.so`.
  - Полная поддержка игр на движке Unity (Rogue Legend, Soul Knight, и любых других 3D/2D IL2CPP игр) без необходимости в отдельных чит-модулях.

## v5.6.1

- **Pre-Load & Availability Spoofing (Эмуляция готовности видео `isReady = true`)**:
  - Автоматический фоновый демон опроса слушателей ironSource, LevelPlay, AppLovin MAX, Unity Ads и Google AdMob.
  - Постоянная отправка положительного статуса готовности видео (`onRewardedVideoAvailabilityChanged(true)`, `onAdAvailable`, `onAdLoaded`) в C# движок Unity и Java.
  - Устранена ошибка *«Реклама не доступна»* в играх и приложениях при отключенном интернете или заблокированных рекламных серверах.

## v5.6.0

- **Universal Rewarded Ads Auto-Granting (Имитация наград за просмотр видео)**:
  - Автоматический перехват полноэкранных рекламных активностей всех основных сетей (Google AdMob, Yandex Ads, AppLovin MAX, Unity Ads, ironSource, myTarget/VK Ads, RuStore Ads).
  - Мгновенная эмуляция колбэков начисления наград (`onUserEarnedReward`, `onRewarded`, `onUnityAdsShowComplete(COMPLETED)`) и автоматическое закрытие рекламного окна за 0.01 секунды.
  - Пользователь получает бонусы/монеты/разблокировки в приложениях мгновенно без просмотра видеороликов и без задержек.
- **Оптимизация Zygisk Lifecycle**:
  - Улучшенная синхронизация жизненного цикла с ActivityThread без конфликтов с Intent Firewall и iptables.

## v5.5.0

- **Встроенный нативный Zygisk-движок Auto-Collapse (`zygisk/*.so` + `aad_core.dex`)**:
  - Полная интеграция нативного C++ Zygisk-перехватчика в корень модуля (`arm64-v8a.so`, `armeabi-v7a.so`, `x86.so`, `x86_64.so`).
  - Автоматическое схлопывание пустых рекламных рамок и контейнеров (AdMob, Yandex, MAX, Unity, ironSource, myTarget, RuStore, Meta, InMobi, BidMachine и др.) до `0x0 (View.GONE)` при запуске приложений.
  - 100% автономность: не требует установки LSPosed, отдельных APK-компаньонов или ручного выбора приложений в списках.
  - Динамический перехват добавления View через `OnHierarchyChangeListener` и `OnGlobalLayoutListener`.
- **Исправление генерации меток времени моста данных**:
  - Переход на `aad_epoch_ms` (Unix Epoch timestamp в миллисекундах) вместо `uptime`.

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
- **Системное зануление рекламного ID (`ZERO_AD_ID=0`)**: При старте сервиса автоматически выставляются флаги `ad_id_zero 1` и `limit_ad_tracking 1`, вынуждая рекламные аукционы (RTB) возвращать статус `No Fill` (реклама не выкуплена).
- **AppOps Overlay Control (`BLOCK_OVERLAY_ADS=1`)**: Для приложений с агрессивными форматами рекламы (App-Open / Interstitial) автоматически сбрасываются права `SYSTEM_ALERT_WINDOW` и `TOAST_WINDOW` в `ignore`, блокируя всплывающие поверх окон баннеры.
- **WebView Content Blocking (`BLOCK_WEBVIEW_ADS=0`)**: Добавлена systemless-фильтрация рекламных доменов внутри встроенного Android System WebView через `/data/local/tmp/webview-command-line`.
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
