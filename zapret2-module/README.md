# Zapret 2 for Android (Magisk / KernelSU / APatch Module)

## v2.6.13 — Material 3 Expressive WebUI и точный compatibility-статус

- WebUI полностью переработан в стиле Material 3 Expressive: выразительные контейнеры и формы, tonal/filled/outlined actions, адаптивная компоновка, light/dark palette и крупная status-панель.
- Добавлены анимации нажатия и обратной связи: ripple, shape morph, spring-like scale, snackbar, animated loading state, reveal карточек и активная навигация по разделам. Учитывается `prefers-reduced-motion`.
- Улучшена доступность: `focus-visible`, крупные touch-targets, `aria-live` для статуса и понятное disabled-состояние зависимых настроек.
- Настройки Hotspot стали контекстными: поля VPN недоступны, когда VPN-раздача выключена; DNS-пул недоступен, когда DNS redirect выключен.
- Кнопка обновления приложений получила полноценный loading/feedback state; INCLUDE/EXCLUDE переключатели откатывают визуальное состояние при ошибке backend.
- Исправлен health для AUTO compatibility fallback: отсутствие optional `xt_connbytes` больше не переводит исправно работающий модуль в `DEGRADED`.
- Диагностика отдельно показывает `nf_conntrack_acct`, `CONNMARK`, `connbytes`, `NFQUEUE` и `owner`. На ядрах без `xt_connbytes` отображается `OK · compatibility fallback`, активная стратегия — SIMPLE.
- Все WebUI actions дополнительно проверены на соответствие backend-командам `zapret2-control`.
- По результатам проверки исправлена реальная ошибка кнопки «Сохранить и применить стратегии»: прежний whitelist `validate_strategy_args` ошибочно отклонял корректные аргументы с `--`; новый validator принимает безопасный синтаксис nfqws2 и по-прежнему блокирует shell-метасимволы.

## v2.6.12 — строгие сетевые роли и стабильная VPN-раздача

- VPN-routing возвращён к рабочей базе v2.6.10: приватная таблица Zapret2 `11999`, точные `iif`-правила и AntiDPI fallback.
- Исправлен регресс v2.6.11: `rmnet*`, `wlan*` и другие физические Android `NOT_VPN` интерфейсы больше не могут быть ошибочно выбраны как VPN.
- VPN в `AUTO` определяется сначала по Android `Connectivity` как Transport VPN, затем по фактическому default-route/`rt_tables` только для строгих tunnel-имён (`tun*`, `wg*`, `awg*`, `vpn*` и т.п.). При сомнении модуль выбирает «VPN не найден», а не опасный ложный VPN.
- Hotspot/USB определяется по текущему `dumpsys tethering` состоянию `TETHERED`; fallback допускает только tether-подобные имена с приватным gateway и исключает физические `NOT_VPN` интерфейсы.
- AntiDPI/QUIC/DNS правила Hotspot теперь перестраиваются под фактические downstream-интерфейсы, без привязки к `wlan2`.
- Watcher гибридный: события `/data/misc/net` + лёгкий polling + периодическая строгая перепроверка Android ролей. Переходное состояние автоматически повторяется до готовности.
- Сохранён безопасный fallback policy-routing только на точную подсеть конкретного tether-интерфейса; широкие `10/8`, `172.16/12`, `192.168/16` правила не используются.
- Диагностика показывает строгие роли `downstream/vpn/physical`, текущие Android tether states и применённые VPN policy/NAT правила.

## v2.6.7 — tether/VPN и рабочий AUTO

- Исправлена причина остановки VPN: старые правила `ip rule from 10.0.0.0/8 ... lookup tun0` могли захватывать собственный underlay VPN на мобильных сетях, где телефон получает адрес 10.x. Теперь VPN sharing использует только `iif` конкретного tether-интерфейса.
- Zapret2 больше не вешает DPI/QUIC/DNS на весь forwarded-трафик: правила ограничены downstream-интерфейсами Hotspot/USB (`ap*`, `swlan*`, `rndis*`, `ncm*`, `wlan1..4` и т.д.).
- FORWARD/PREROUTING hooks вставляются в начало цепочки, поэтому vendor/netd/другие модули не могут обойти Zapret2 ранним ACCEPT; при этом внутренние правила интерфейсно ограничены.
- `AUTO/circular` теперь получает первые ответные пакеты сервера через INPUT/FORWARD. Потоки помечаются `CONNMARK`, а `connbytes` ограничивает reply-feed первыми 12 пакетами. Если нужных возможностей ядра нет, runtime автоматически использует SIMPLE вместо сломанного AUTO.
- Для `connbytes` в AUTO проверяется/включается `nf_conntrack_acct`.
- VPN→Hotspot/USB работает самостоятельно: Zapret2 создаёт собственные policy routing/NAT правила только для tether-интерфейсов.
- VPN-интерфейс по умолчанию `AUTO`; поиск таблицы работает не только через `/data/misc/net/rt_tables`, но и через реальные таблицы `ip route`.
- Принудительный DNS раздачи по умолчанию выключен и при включении применяется только к tether-интерфейсам.
- Диагностика дополнена builtin-chain counters, интерфейсами, `dumpsys tethering`, VPN policy state и маршрутами.

## v2.6.6 — установщик

- Удалён вложенный MMT Extended: модулю без system-overlay он не нужен.
- `customize.sh` теперь самостоятельно распаковывает ZIP, выбирает ABI и выставляет права.
- Кнопки громкости учитывают только события `DOWN`; остаточные `UP`, `SYN`, `MSC` и касания экрана игнорируются.
- Таймаут показывает безопасный дефолт: Hotspot и QUIC — да, VPN-маршрутизация и принудительный DNS — нет.
- Краткий лог установки сохраняется в `/sdcard/eCubz/zapret2_install.log`.
- Ошибка ABI/распаковки/копирования теперь завершает установку с явным сообщением, а не оставляет полумодуль.


## WebUI / диагностика v2.6.5

WebUI открывается штатно из страницы модуля в KernelSU Next (раздел WebUI). Отдельный HTTP-сервер, localhost-порт и CGI не используются: страница выполняет команды через официальный root API `ksu.exec`. Это исключает конфликты портов с другими модулями.

`QUIC_MODE="SELECTED"` — значение по умолчанию: блокируется только QUIC/HTTP3 (UDP/443) у приложений из `apps.list`. Другой UDP этих приложений не затрагивается. Для клиентов Hotspot/USB действует отдельный `FORCE_TCP_HOTSPOT=1`, также только на UDP/443. Значение `GLOBAL` блокирует UDP/443 у всего телефона, а `OFF` не блокирует QUIC.

**Автор:** [eCubz](https://t.me/eCubz)
**Репозиторий проекта:** Частный (Private) GitHub репозиторий
**Совместимость:** Magisk, KernelSU, KernelSU-Next, APatch

---

## Описание

Модуль **Zapret 2 for Android** предназначен для автономного обхода замедлений и блокировок сетевого трафика (HTTP, HTTPS/TLS, QUIC) на мобильных устройствах под управлением Android с Root-правами.

Модуль основан на **zapret2** от *bol-van* (`nfqws2` + динамические Lua-стратегии) и включает подсистему выборочного обхода для приложений (**Per-App Split Tunneling**), подсистему встроенного веб-интерфейса (**WebUI**), а также механизм принудительного перевода мессенджеров (Telegram, ExteraGram, Ayugram) с UDP на TCP.

По умолчанию сразу после установки модуль работает в целевом режиме **`INCLUDE`**: в NFQUEUE попадает только трафик приложений из `apps.list`. QUIC/HTTP3 (UDP/443) блокируется только для этого же списка. Для выбранных приложений по умолчанию активна стратегия `AUTO`, которая переключает варианты обхода по признакам сбоев. Hotspot/USB обрабатывается отдельно.

---

## Ключевые возможности

1. **Полная мультиархитектурность**:
   - Встроены статически скомпилированные бинарники `nfqws2` v1.0.4 для всех 4-х архитектур Android (`arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`).
   - Использование официальных Lua-скриптов обхода (`zapret-lib.lua`, `zapret-antidpi.lua`, `zapret-auto.lua`, `zapret-obfs.lua`).

2. **Три режима работы (`MODE`)**:
   - **`INCLUDE`** (**по умолчанию**) — обход DPI применяется только к приложениям из `apps.list`; это рекомендуемый режим с минимальным вмешательством.
   - **`EXCLUDE`** — широкий режим: обход DPI применяется ко всем приложениям, кроме указанных в `exclude.list`.
   - **`GLOBAL`** — обход DPI применяется ко всему трафику устройства без ограничений.

3. **Встроенный WebUI без HTTP-сервера**:
   - WebUI открывается штатно из страницы модуля в KernelSU Next и выполняет команды через `ksu.exec`.
   - Управление режимами, приложениями, QUIC, Hotspot, стратегиями и диагностикой.

4. **Точечный QUIC fallback (`FORCE_TCP`)**:
   - В режиме `SELECTED` блокируется только UDP/443 у приложений из `apps.list`; другой UDP не затрагивается.
   - Для Hotspot/USB действует отдельное правило UDP/443 через `FORCE_TCP_HOTSPOT`.

5. **Action / CLI / диагностика**:
   - **Action Button** перезапускает службу и показывает краткий health-статус.
   - CLI: `/data/adb/modules/zapret2-android/bin/zapret2-control`.
   - Команда `diag` собирает состояние UID, iptables/NFQUEUE, маршрутов, процессов и последних логов в `/sdcard/eCubz/zapret2_diagnostics_latest.txt`.

---

## Проверенная эталонная стратегия (`ALT4` с `repeats=6`)

Стратегия `SIMPLE` оставлена как проверенный базовый вариант `ALT4` (`fake badseq + multisplit`). По умолчанию v2.6.5 использует `AUTO`; эффективность конкретной стратегии зависит от провайдера и типа DPI:

```bash
DESYNC_ARGS="--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit --payload=http_req --lua-desync=fake:blob=fake_default_http:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit"
```

### Таблица проверенных стратегий:

| Стратегия | Описание техники | Рекомендуемые условия / Операторы | Строка `DESYNC_ARGS` |
|---|---|---|---|
| **`ALT4`** *(SIMPLE)* | `fake badseq (repeats=6) + multisplit` | Базовый вариант для ручного режима | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit --payload=http_req --lua-desync=fake:blob=fake_default_http:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit` |
| **`FAKE_TLS_AUTO`** | `fake + multidisorder` | Провайдеры с глубоким L7-анализом TLS | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=0x00000000:repeats=11:tcp_seq=-10000:tcp_ack=-66000:tcp_ts_up --lua-desync=fake:blob=fake_default_tls:tls_mod=rnd,dupsid,sni=www.google.com:repeats=11:tcp_seq=-10000:tcp_ack=-66000:tcp_ts_up --lua-desync=multidisorder:pos=1,midsld` |
| **`ALT`** | `fake + fakedsplit, ts` | Сети с корректной поддержкой TCP Timestamps | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=fakedsplit:pattern=0x00:repeats=6:tcp_ts=-600000:tcp_ts_up` |
| **`ALT2`** | `multisplit seqovl=652 pos=2` | Наложение сегментов | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=multisplit:pos=2:seqovl=652` |

---

## Конфигурация и управление

Все конфигурационные файлы после установки находятся в папке модуля:
`/data/adb/modules/zapret2-android/`

### 1. Файл `zapret2.conf`
Содержит главные параметры работы:
```bash
# Режим фильтрации по умолчанию: только apps.list
MODE="INCLUDE"

# Принудительный перевод Telegram/приложений с UDP на TCP (1 - вкл, 0 - выкл)
FORCE_TCP="1"

# Перехватываемые TCP порты
PORTS_TCP="80,443"

# Номер очереди NFQUEUE
QNUM="200"
```

---

## Использование консоли управления (`zapret2-control`)

Вы можете управлять модулем из любой консоли (Termux, ADB Shell) от имени Root:

```bash
su -c /data/adb/modules/zapret2-android/bin/zapret2-control [команда]
```

### Доступные команды:
- `.../bin/zapret2-control status` — показать текущий статус и режим работы демона.
- `.../bin/zapret2-control json-status` — вернуть JSON статус для WebUI.
- `.../bin/zapret2-control json-apps` — вернуть полный массив приложений Android для WebUI.
- `.../bin/zapret2-control mode [exclude|include|global]` — сменить режим фильтрации.
- `.../bin/zapret2-control forcetcp [1|0]` — включить/выключить принудительный TCP.
- `.../bin/zapret2-control add <pkg>` — добавить пакет приложения.
- `.../bin/zapret2-control del <pkg>` — удалить пакет приложения.
- `.../bin/zapret2-control restart` — перезапустить службу `zapret2`.
- `.../bin/zapret2-control diag` — собрать полный диагностический отчёт.
- `.../bin/zapret2-control nfqws-debug 1|0` — временно включить/выключить подробный debug `nfqws2`.

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


## v2.6.5
- Runtime-адаптация: проверка `iptables`/`ip6tables`, `owner`, `NFQUEUE` и `--queue-bypass` перед установкой правил.
- UID приложений собираются сразу из нескольких источников (`pm`, `cmd package`, `/data/system/packages.list`) с прямым fallback для отдельного пакета и поддержкой нескольких Android users.
- `EXCLUDE` имеет приоритет над `INCLUDE`; широкий EXCLUDE fail-safe не включается без `owner match`.
- Обычный лог теперь пишет окружение, выбранный backend UID, ошибки команд, состояние правил и NFQUEUE.
- Добавлен временный `NFQWS_DEBUG=1`, ротация логов и полный диагностический отчёт из WebUI.
- Бинарники перенесены из `system/bin` в приватный `bin/` модуля: системный overlay для работы больше не нужен.
- WebUI объединяет несколько источников списка пакетов и показывает health/warnings.
- Из дефолтного `exclude.list` убраны пересечения с `apps.list`, чтобы выбранные Telegram/браузеры не исключали сами себя.

## v2.6.4
- Исправлен список приложений в WebUI: основной источник — Android `pm`, поэтому `listUserPackages/listSystemPackages` KernelSU больше не обязательны.
- `getPackagesInfo` используется только для названий/метаданных, при его отсутствии WebUI показывает package name и остаётся полностью рабочим.
- Добавлена классификация системных приложений непосредственно через PackageManager.

### v2.6.8
- VPN→Hotspot/USB полностью самостоятельный: отдельная таблица маршрутизации Zapret2 (`11999`) вместо зависимости от временных Android VPN tables.
- VPN watcher отслеживает реальные VPN/tether интерфейсы и адреса, поэтому включение VPN после загрузки модуля больше не пропускается на Android 16.
- Fail-closed защита от утечки: при включённой VPN-раздаче клиент не может незаметно уйти через обычный upstream/реальный IP, пока VPN не готов.
- Для vendor-систем, где `ip rule iif` не принимается, есть безопасный fallback только на точную подсеть активного tether-интерфейса.
- Диагностика показывает приватную VPN route-table, policy rules, VPN FORWARD/NAT и killswitch.


### v2.6.10
- Добавлена настройка «Если VPN недоступен»: `AntiDPI` (по умолчанию) или `Блокировать интернет клиентов`.
- В режиме `AntiDPI` при исчезновении VPN удаляются только VPN policy/NAT/guard правила; штатная Android-раздача продолжает работу, а `ZAPRET2_MANGLE_FORWARD` и QUIC-политика продолжают обрабатывать клиентов.
- DNS forwarding полностью отделён от наличия интернета: `DNS=Нет` больше не ассоциирован с VPN kill-switch.
- Режим `BLOCK` сохраняет прежнее fail-closed поведение для пользователей, которым важнее исключить любой выход клиентов мимо VPN.
- WebUI показывает понятное пользователю название `AntiDPI`, внутреннее значение конфигурации — `VPN_FALLBACK_MODE=ANTIDPI|BLOCK`.

### Исправление v2.6.10: VPN включён после запуска Hotspot

`vpn-watch` теперь различает стабильное и переходное состояние интерфейсов. Если `tun0`/downstream уже создан, но Android ещё не назначил адрес или маршрут, ранняя попытка не считается завершённой: применение VPN-routing повторяется автоматически до успешного `VPN sharing ACTIVE`. Перезапуск Hotspot для переключения AntiDPI → VPN больше не должен требоваться.
