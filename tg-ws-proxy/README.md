# Telegram WS Proxy (Magisk / KernelSU / APatch модуль)

Модуль для стабильной работы и ускорения загрузки Telegram на Android без использования системного VPN.

---

## Архитектура и принцип работы

Модуль поднимает на устройстве локальный MTProto-прокси, к которому Telegram подключается штатно (через встроенные настройки прокси):

1. **Основной маршрут (Direct WebSocket)**:
   * Локальный MTProto-трафик от Telegram перехватывается демоном и передаётся по защищённому протоколу **WebSocket поверх TLS (`wss://`)** напрямую к дата-центрам Telegram (`kws<DC>.web.telegram.org:443`, путь `/apiws`).
   * Это позволяет обходить сигнатурные блокировки MTProto со стороны ТСПУ и операторов связи.
2. **Резервные маршруты (Fallback)**:
   * Если прямой WebSocket недоступен, демон по очереди пробует:
     1. **Собственный Cloudflare Worker** (если указан в `CFPROXY_WORKER_DOMAIN`);
     2. **Пул проксирующих Cloudflare-доменов** (с авто-обновлением из GitHub);
     3. **Прямое TCP-соединение** к дата-центрам Telegram.

> [!NOTE]
> **Статус Cloudflare-доменов апстрима:**  
> На 2026-08-23 резервные домены апстрима из GitHub временно не имеют A-записей. Основной рабочий маршрут — прямой WebSocket к Telegram, а также собственный Cloudflare Worker (при наличии). Модуль автоматически загрузит обновлённые домены, как только они станут активны в апстриме.

---

## Быстрый старт

1. Установите ZIP-архив модуля через Magisk / KernelSU / APatch Manager.
2. Перезагрузите устройство.
3. В менеджере root на карточке модуля нажмите кнопку **«Действие»** (Action):
   * При установленном `KsuWebUIStandalone` или `MMRL` откроется удобный **WebUI**.
   * При их отсутствии сразу откроется диалог подключения в Telegram.
4. В открывшемся окне Telegram нажмите **«Включить»**.

---

## Управление через терминал и WebUI

* **Встроенный WebUI**: доступен во вкладке модуля в KernelSU Manager / MMRL / APatch.
* `su -c sh /data/adb/modules/tg-ws-proxy/action.sh status` — просмотр статуса службы, сокета и ссылки подключения.
* `su -c sh /data/adb/modules/tg-ws-proxy/action.sh ping` — экспресс-проверка задержки (RTT) до Cloudflare-доменов.
* `su -c sh /data/adb/modules/tg-ws-proxy/action.sh restart` — перезапуск службы.
* `su -c sh /data/adb/modules/tg-ws-proxy/action.sh stop` — остановка службы.
* `su -c sh /data/adb/modules/tg-ws-proxy/action.sh start` — запуск службы.
* `su -c sh /data/adb/modules/tg-ws-proxy/action.sh link` — вывод актуальной ссылки подключения.
* `su -c sh /data/adb/modules/tg-ws-proxy/action.sh open` — открытие прокси в Telegram.

---

## Структура файлов и состояние

* Каталог модуля (только чтение): `/data/adb/modules/tg-ws-proxy/`
* Каталог состояния (мутабельные данные): `/data/adb/tg-ws-proxy/`
  * `config.conf` — пользовательская конфигурация (0600).
  * `secret.conf` — постоянный 32-значный ключ MTProto (0600).
  * `logs/tg-ws-proxy.log` — журнал работы прокси (ротация до 2 МБ).
  * `logs/stderr.log` — журнал ошибок старта и паник рантайма.
  * `run/proxy_link.txt` — актуальная ссылка `tg://proxy` (0644).
  * `run/health.env` — текущий статус здоровья службы.

---

## Сборка бинарников и воспроизводимость

Бинарники скомпилированы из исходников `spatiumstas/tg-ws-proxy-go` (коммит `a334786`, Go 1.26.5):
```sh
# ARM64 (arm64-v8a)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o bin/arm64-v8a/tg-ws-proxy .

# ARM32 (armeabi-v7a)
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o bin/armeabi-v7a/tg-ws-proxy .

# x86_64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o bin/x86_64/tg-ws-proxy .

# x86
CGO_ENABLED=0 GOOS=linux GOARCH=386 go build -trimpath -ldflags="-s -w" -o bin/x86/tg-ws-proxy .
```

### Контрольные суммы бинарников (SHA-256):
* `bin/arm64-v8a/tg-ws-proxy`: `1e5347c6d30f42ef92d1cf0c3eec4917b9779f53fb2a18464a240abef617a1de`
* `bin/armeabi-v7a/tg-ws-proxy`: `62aabb3a5e8ae669cf5d96cbc8f3df22465bffac5421fd0868d3eda6e7a09f7b`
* `bin/x86_64/tg-ws-proxy`: `f78f97d76b10c0d865dc00e821e23502a5596c3690cb3b765f2c6250566e3a9a`
* `bin/x86/tg-ws-proxy`: `95187185552bf133052a9c09b0dc4ca6b25e1d6cf246bc8ff23d8771ec850bab`

---

## Поддержать разработчика eCubz / Support & Donations

Ваша поддержка мотивирует развивать проекты, поддерживать прокси-узлы и выпускать регулярные обновления!

* **Ю.Money (Яндекс) — Предпочтительно:**
  * Номер счёта: `4100 1149 4875 904`
  * [Перевод через ЮMoney (410011494875904)](https://yoomoney.ru/to/410011494875904)
* **СБП (Россия) / Т-Банк:**
  * Номер: `+7 923 618-89-93`
  * [Перевод по ссылке Т-Банк](https://www.tinkoff.ru/rm/r_qoRUrMgqrw.gQAquXjKzF/ca7Vm7131)
* **Crypto Bot (Telegram):**
  * USDT / TON / GRAM: [Открыть Crypto Bot](http://t.me/send?start=IVjCT8LiszJ2)
* **TON Wallet:**
  * Адрес: `UQCLyovMu5882XPekfUqXOLFbYFHROaB9uoWMsIaifvMqEC4`

---

## Лицензия и благодарности

Проект основан на наработках:
* **Flowseal** ([Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy)) — оригинальная концепция MTProto WS Proxy.
* **spatiumstas** ([spatiumstas/tg-ws-proxy-go](https://github.com/spatiumstas/tg-ws-proxy-go)) — реализация высокопроизводительного Go-демона.

Распространяется под лицензией **MIT** (см. файл `LICENSE`).

**Автор сборки модуля:** eCubz (https://t.me/eCubz)  
**Канал проекта:** https://t.me/module_ecubz
