# Zapret 2 for Android (Magisk / KernelSU / APatch Module)

## WebUI v2.1.0

WebUI открывается штатно из страницы модуля в KernelSU Next (раздел WebUI). Отдельный HTTP-сервер, localhost-порт и CGI не используются: страница выполняет команды через официальный root API `ksu.exec`. Это исключает конфликты портов с другими модулями.

`QUIC_MODE="SELECTED"` — безопасное значение по умолчанию: UDP блокируется только у приложений из `force_tcp_apps.list`. Значение `GLOBAL` блокирует UDP/443 у всего устройства, а `OFF` не блокирует UDP.

**Автор:** [eCubz](https://t.me/eCubz)  
**Репозиторий проекта:** Частный (Private) GitHub репозиторий  
**Совместимость:** Magisk, KernelSU, KernelSU-Next, APatch  

---

##  Описание

Модуль **Zapret 2 for Android** предназначен для автономного обхода замедлений и блокировок сетевого трафика (HTTP, HTTPS/TLS, QUIC) на мобильных устройствах под управлением Android с Root-правами.

Модуль основан на **zapret2** от *bol-van* (`nfqws2` + динамические Lua-стратегии) и включает подсистему выборочного обхода для приложений (**Per-App Split Tunneling**), подсистему встроенного веб-интерфейса (**WebUI**), а также механизм принудительного перевода мессенджеров (Telegram, ExteraGram, Ayugram) с UDP на TCP.

По умолчанию сразу после установки модуль работает в режиме **`EXCLUDE`**: обход блокировок и замедлений применяется ко всему трафику устройства, кроме списка доверенных отечественных приложений и банков из `exclude.list`.

---

##  Ключевые возможности

1. **Полная мультиархитектурность**:
   - Встроены статически скомпилированные бинарники `nfqws2` v1.0.4 для всех 4-х архитектур Android (`arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`).
   - Использование официальных Lua-скриптов обхода (`zapret-lib.lua`, `zapret-antidpi.lua`, `zapret-auto.lua`, `zapret-obfs.lua`).

2. **Три режима работы (`MODE`)**:
   - **`EXCLUDE`** (по умолчанию при установке) — обход DPI применяется ко всем приложениям, **кроме** указанных в `exclude.list` (все росс. сервисы, Госуслуги, Яндекс, банки).
   - **`INCLUDE`** — обход DPI применяется **только** к приложениям из списка `apps.list`.
   - **`GLOBAL`** — обход DPI применяется ко всему трафику устройства без ограничений.

3. **Встроенный WebUI и управления через браузер**:
   - Встроенный мобильный WebUI веб-интерфейс на порту `http://127.0.0.1:8080`.
   - Полное управление режимами, списком приложений, принудительным TCP и запуск автоподбора дополнительной стратегии.

4. **Принудительный перевод на TCP (`FORCE_TCP`)**:
   - Блокировка/REJECT исходящих UDP-пакетов для выбранных мессенджеров.
   - Клиенты Telegram / ExteraGram / Ayugram автоматически переключаются с UDP на протокол MTProto over TCP (порты 443, 80, 5222), который эффективно обрабатывается Lua-стратегиями `zapret2`.

5. **Управление через Action Button & CLI**:
   - **Action Button**: Нажатие кнопки *Action* в интерфейсе KernelSU / APatch / Magisk открывает браузер с WebUI (`http://127.0.0.1:8080`) и перезапускает службу.
   - **CLI утилита**: Запуск из терминала `su -c zapret2-control` с расширенным выбором команд.

---

##  Проверенная эталонная стратегия (`ALT4` с `repeats=6`)

По умолчанию в конфигурационном файле `/data/adb/modules/zapret2-android/zapret2.conf` задействована **100% проверенная эталонная стратегия ALT4** (`fake badseq + multisplit`), гарантирующая стабильное воспроизведение YouTube и работу Discord на мобильных провайдерах и домашнем интернете:

```bash
DESYNC_ARGS="--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit --payload=http_req --lua-desync=fake:blob=fake_default_http:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit"
```

###  Таблица проверенных стратегий:

| Стратегия | Описание техники | Рекомендуемые условия / Операторы | Строка `DESYNC_ARGS` |
|---|---|---|---|
| **`ALT4`** *(по умолчанию)* | `fake badseq (repeats=6) + multisplit` | 100% Эталон для YouTube и Discord в РФ | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit --payload=http_req --lua-desync=fake:blob=fake_default_http:repeats=6:tcp_seq=1000:tcp_ack=-66000:tcp_ts_up --lua-desync=multisplit` |
| **`FAKE_TLS_AUTO`** | `fake + multidisorder` | Провайдеры с глубоким L7-анализом TLS | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=0x00000000:repeats=11:tcp_seq=-10000:tcp_ack=-66000:tcp_ts_up --lua-desync=fake:blob=fake_default_tls:tls_mod=rnd,dupsid,sni=www.google.com:repeats=11:tcp_seq=-10000:tcp_ack=-66000:tcp_ts_up --lua-desync=multidisorder:pos=1,midsld` |
| **`ALT`** | `fake + fakedsplit, ts` | Сети с корректной поддержкой TCP Timestamps | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:repeats=6:tcp_ts=-600000:tcp_ts_up --lua-desync=fakedsplit:pattern=0x00:repeats=6:tcp_ts=-600000:tcp_ts_up` |
| **`ALT2`** | `multisplit seqovl=652 pos=2` | Наложение сегментов | `--filter-tcp=80,443 --filter-l7=http,tls --payload=tls_client_hello --lua-desync=multisplit:pos=2:seqovl=652` |

---

##  Конфигурация и управление

Все конфигурационные файлы после установки находятся в папке модуля:
`/data/adb/modules/zapret2-android/`

### 1. Файл `zapret2.conf`
Содержит главные параметры работы:
```bash
# Режим фильтрации по умолчанию: EXCLUDE
MODE="EXCLUDE"

# Принудительный перевод Telegram/приложений с UDP на TCP (1 - вкл, 0 - выкл)
FORCE_TCP="1"

# Пакеты приложений для перевода на TCP
FORCE_TCP_APPS="org.telegram.messenger com.telegram.messenger org.telegram.messenger.web com.exteragram.messenger com.ayugram.messenger com.ayugram.messenger.beta"

# Перехватываемые TCP порты
PORTS_TCP="80,443"

# Номер очереди NFQUEUE
QNUM="200"
```

---

##  Использование консоли управления (`zapret2-control`)

Вы можете управлять модулем из любой консоли (Termux, ADB Shell) от имени Root:

```bash
su -c zapret2-control [команда]
```

### Доступные команды:
- `su -c zapret2-control status` — показать текущий статус и режим работы демона.
- `su -c zapret2-control json-status` — вернуть JSON статус для WebUI.
- `su -c zapret2-control json-apps` — вернуть полный массив приложений Android для WebUI.
- `su -c zapret2-control mode [exclude|include|global]` — сменить режим фильтрации.
- `su -c zapret2-control forcetcp [1|0]` — включить/выключить принудительный TCP.
- `su -c zapret2-control add <pkg>` — добавить пакет приложения.
- `su -c zapret2-control del <pkg>` — удалить пакет приложения.
- `su -c zapret2-control restart` — перезапустить службу `zapret2`.

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
