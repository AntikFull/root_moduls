# AIUnblock Technical Details

AIUnblock реализует **умную маршрутизацию Android-приложений** через гибрид Smart-DNS/SNI/DNAT механизмов. Системный DNS Android не меняется.

ZIP устанавливается через менеджеры Magisk, KernelSU или APatch Manager.

Универсальный ZIP содержит сборки ядра для:

- `arm64-v8a`
- `armeabi-v7a`
- `x86_64`
- `x86`

Установщик сам определяет нужную архитектуру и запускает `aiunblock-native self-test` прямо во время установки. На устройстве остается только рабочий бинарник.

Исходный код ядра находится в `src/native/main.go` и компилируется через `tools/build-native.sh` без cgo. Для `arm64-v8a` основной вариант — Android PIE с `/system/bin/linker64` и поддержкой ELF `DT_HASH`; также есть статический fallback без `PT_INTERP`. Для `armeabi-v7a`, `x86_64` и `x86` используются статические pure-Go ELF без зависимости от bionic. Установщик проверяет SHA-256 и запускает `self-test` выбранного бинарника прямо на устройстве. Одно native core содержит SNI-router, TLS-проверку gateway, DNS и DoH.

Штатный список находится в `apps.list`. Пользовательские дополнения — в `/data/adb/modules/AIUnblock/apps.user.list`. Правила firewall применяются только к выделенным UID этих пакетов, включая secondary/work profile.

`FAIL_MODE=0` — в случае сбоя шлюза трафик идет напрямую. В худшем сценарии сервисы AIUnblock остаются недоступны.

`FAIL_MODE=1` — при сбое шлюза блокировать трафик, чтобы избежать утечек подключения на заблокированные IP.

Для Google App полный fail-block не применяется, чтобы сбой Gemini-SNI не блокировал весь Google App.

Hosts не является частью базовой схемы и по умолчанию отключен. При конфликте с другим hosts-модулем отменяется только optional hosts AIUnblock; per-app routing продолжает работать.

Файл `system/etc/hosts` создается на mount stage во всех сценариях root. Проверка работы без перезагрузки выполняется через наличие маркера `# AIUnblock-hosts` в `/system/etc/hosts`. Статус виден в `aiunblockctl status`:

| Статус | Значение |
| --- | --- |
| `disabled` | Опция hosts-маршрутизации отключена в `install.conf` |
| `conflict:<id>` | Найден сторонний активный hosts-модуль |
| `prepared` / `prepared:ksu-overlayfs` | Дерево готово, ждет mount stage |
| `active` | Overlay успешно применился |
| `not-mounted` | Прошивка/root не смонтировали overlay; per-app все равно работает |

Энергопотребление оптимизировано по событиям и состояниям:

- сторожевой сон 120с в штатном состоянии и сон 15с только когда состояние не `ok`/`noapps`;
- сетевые события — за ~2 миллисекунды (`ip route get` и `stat` по `packages.list`), никакой нагрузки на процессор;
- таймер самодиагностики (DNS-auth, DoH, TLS-опрос gateway) — раз в 30 минут; при сбое повтор с паузой 30–900с;
- UID приложений считываются из `/data/system/packages.list`, `pm` вызывается только при нехватке данных;
- время берется из `/proc/uptime`, системный таймер не сбивается при настройке времени.

Логирование:

`/sdcard/eCubz/AIUnblock/logs`

Кнопка Action создает расширенный отчет прямо сейчас. `aiunblockctl status` также отображает ABI и результат native self-test.
