# AI Unblock RU

Модуль для Magisk, KernelSU и APatch с выборочной маршрутизацией Gemini, NotebookLM, ChatGPT, Claude и Grok через шлюзы Smart DNS. Обычный трафик устройства не перенаправляется.

## Возможности

- динамическое получение актуальных шлюзов через DoH;
- независимый failover для поддерживаемых AI-сервисов;
- точная SNI-маршрутизация Gemini и NotebookLM;
- отдельные правила по UID приложений;
- блокировка QUIC и IPv6 только для управляемых приложений;
- резервный статический список шлюзов;
- опциональные hosts и AdBlock;
- сохранение пользовательской конфигурации при обновлении.

## Конфигурация Smart DNS

Штатные резолверы находятся в `smartdns.conf`:

```text
DOH https://dns.malw.link/dns-query
DOT dns.malw.link
DNS 95.216.204.218
```

Для собственных серверов скопируйте `smartdns.user.conf.example` в `smartdns.user.conf` и добавьте строки того же формата. Штатный и пользовательский списки объединяются, дубли удаляются. `smartdns.user.conf` сохраняется установщиком при обновлении.

- `DOH` используется для динамического получения и TLS-проверки шлюза.
- `DOT` хранит опубликованную защищённую точку сервиса и учитывается диагностикой.
- `DNS` используется для обычного DNS-запроса и авторизации Smart DNS.

Системный DNS Android модуль не изменяет.

## Установка

Установите `AIUnblock-v2.2.1.zip` через Magisk, KernelSU или APatch и перезагрузите устройство.

## Журналы

Основной журнал:

```text
/data/adb/modules/AIUnblock/dnat.log
```

Журнал SNI-router:

```text
/data/adb/modules/AIUnblock/router.log
```

## Автор и поддержка

- Автор: eCubz — https://t.me/eCubz
- Группа модуля: https://t.me/module_ecubz

## Донаты и поддержка

- СБП: `+7 923 618-89-93`
- Т-Банк: https://www.tinkoff.ru/rm/r_qoRUrMgqrw.gQAquXjKzF/ca7Vm7131
- USDT / GRAM: http://t.me/send?start=IVjCT8LiszJ2
- TON Wallet (USDT): `UQCLyovMu5882XPekfUqXOLFbYFHROaB9uoWMsIaifvMqEC4`

---

## English

AI Unblock RU is a Magisk, KernelSU and APatch module that selectively routes Gemini, NotebookLM, ChatGPT, Claude and Grok through Smart DNS gateways without redirecting all device traffic.

Version 2.2.1 adds dynamic DoH gateway discovery and separate `smartdns.conf` / persistent `smartdns.user.conf` configuration files. Supported record formats are `DOH URL`, `DOT HOST`, and `DNS IPv4`.
