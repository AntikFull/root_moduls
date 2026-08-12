# NFQTTL Stealth Header & TTL Fix — eCubz

Root-модуль для Android, ориентированный на маскировку трафика клиентов мобильной точки доступа.

## Основной режим

По умолчанию модуль делает только необходимые для tethering вещи:

- уменьшает Android-side DUN/provisioning/entitlement signaling (`tether_dun_required`, `net.tethering.noprovisioning`, entitlement state) и сохраняет исходные значения для rollback;
- меняет IPv4 TTL пересылаемого трафика клиентов точки доступа на `64`;
- меняет IPv6 Hop Limit пересылаемого трафика клиентов точки доступа на `64`;
- применяет правила только к направлению `tether-client -> cellular upstream`, а не ко всему `FORWARD`;
- защищается от входящих TTL/Hop-Limit=1 probes на cellular-интерфейсах;
- отключает tethering offload без изменения persistent property и сохраняет исходные настройки вне каталога модуля (`/data/adb/nfqttl-ecubz/state`) для корректного rollback даже после обновлений;
- использует нативные `TTL`/`HL` targets ядра, когда они доступны;
- запускает NFQUEUE daemon только как fallback; controller следит за backlog/drop counters и при перегрузке открывает путь, сохраняя связь.

`tun+` намеренно не считается cellular upstream по умолчанию, чтобы не вмешиваться в VPN.

CarrierConfig на современных Android всё ещё может иметь собственную entitlement-политику, поэтому provisioning bypass — дополнительный слой, а не гарантия сам по себе.

> В legacy NFQUEUE fallback из текущих prebuilt-бинарников фактическая TTL/HL остаётся `64`. Пользовательское `TTL_VALUE` гарантированно применяется в native TTL-target режиме; полноценный custom TTL в NFQUEUE будет доступен после чистой пересборки уже исправленного `src/nfqttl.c`.

## Дополнительные функции

В `config.conf` есть выключенные по умолчанию опции:

- DNS redirect 53;
- блокировка DoT/853;
- блокировка NTP/123;
- блокировка mDNS/LLMNR/SSDP/NetBIOS discovery;
- строковый `blocklist.txt`;
- TCP MSS clamp.

Они не включены в базовый профиль, потому что могут ломать обычные функции клиентов и не являются обязательными для TTL/HL masking.

## Диагностика

Кнопка Action переключает расширенный debug-режим. При включении формируется отчёт:

`/sdcard/eCubz/nfqttl-ecubz_debug.log`

Постоянный компактный service log:

`/data/local/tmp/nfqttl-ecubz/service.log`

Отчёт включает состояние NFQUEUE, counters правил, route/policy routing, tethering/offload, ANR/crash indicators и последние сетевые ошибки.

## Версия

Единственный источник версии модуля — `module.prop`. `service.sh`, `customize.sh`, `action.sh` и диагностика читают `version`/`versionCode` оттуда.

## Поддерживаемые ABI

- arm64-v8a
- x86
- x86_64
- armeabi-v7a — **временно заблокирован в installer**: у бинарника из v8.4 обнаружено структурное повреждение; его нельзя безопасно «починить» дописыванием байтов. Нужна чистая пересборка из `src/`.

Во время установки выбранный native binary реально запускается с `-h`. При неизвестной/заблокированной ABI установка прекращается вместо небезопасного fallback на arm64.

## Root managers

Структура рассчитана на Magisk, KernelSU и APatch: `customize.sh`, `service.sh`, `action.sh`, `uninstall.sh`.

## Лицензия

Исходная native-часть `nfqttl` и включённые производные распространяются на условиях GNU GPL v3 согласно файлу `LICENSE`. Сохраняйте уведомления об авторстве и условия соответствующих upstream-компонентов.

## Native build status

Исходник `src/nfqttl.c` уже содержит hardening для следующей чистой пересборки: queue maxlen, `NFQA_CFG_F_FAIL_OPEN`, GSO flag, исправленный `-t`, безопасные error paths и отсутствие legacy protocol-family unbind/bind. В текущем ZIP arm64/x86/x86_64 остаются проверенными prebuilt-бинарниками предыдущей native-сборки; поэтому service-side overload circuit breaker оставлен включённым по умолчанию.

## Установка

ZIP рассчитан на установку **из менеджера Magisk / KernelSU / APatch**. Legacy `META-INF/update-binary` удалён: он был Magisk-only и мешал универсальности; recovery-flash для этого пакета не является целевым способом установки.

При обновлении известные значения `config.conf` переносятся из предыдущей версии автоматически; новые параметры получают новые значения по умолчанию.
