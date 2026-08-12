# Changelog

## v8.5

- Версия и `versionCode` читаются shell-компонентами только из `module.prop`; исправленный native source тоже получает версию через environment/sibling `module.prop`, без собственной версии модуля.
- TTL/HL больше не применяются глобально ко всему `FORWARD`: только `tether-client -> cellular upstream`.
- `tun+` исключён из cellular upstream по умолчанию.
- Добавлен обратимый DUN/provisioning/entitlement bypass как второй слой anti-tethering; исходные значения переживают обновление и восстанавливаются при удалении.
- Native `TTL`/`HL` используются при наличии; NFQUEUE запускается только как fallback.
- Watchdog заменён на self-healing controller, который не запускает daemon в native mode и не форсирует `ip_forward`.
- Controller проверяет содержимое цепочек, состояние reversible offload/provisioning параметров и NFQUEUE backlog/drop counters.
- Добавлен NFQUEUE circuit breaker: при повторной перегрузке fallback-путь открывается до перезагрузки вместо деградации/обрывов tethering.
- Удалены глобальные persistent изменения `persist.sys.tether.offload.enable`.
- Исходные tether offload settings сохраняются вне каталога модуля и восстанавливаются через `uninstall.sh`.
- DNS/DoT/NTP/discovery/blocklist/MSS вынесены в `config.conf` и по умолчанию отключены.
- Добавлены собственные именованные цепочки `ECUBZ_*` и fail-safe поведение при отсутствии NFQUEUE.
- Исправлены пути debug log и создание каталога до записи.
- Диагностика расширена: NFQUEUE stats, iptables-save, routing/policy rules, provisioning/tethering/offload, ANR/crash indicators, controller/service logs.
- Installer больше не подставляет arm64 для неизвестной ABI и проверяет запуск выбранного binary.
- `armeabi-v7a` временно заблокирован: у унаследованного ELF обнаружено структурное повреждение; небезопасный byte-padding не используется.
- Native source подготовлен к чистой NDK-пересборке: `NFQA_CFG_F_FAIL_OPEN`, queue maxlen, GSO, исправленный `-t`, safer error paths, удалены obsolete protocol-family bind/unbind и неиспользуемый route tracker.
- Удалён obsolete Magisk-only recovery `META-INF/update-binary`; ZIP ориентирован на manager installation Magisk/KernelSU/APatch.
- Известные значения `config.conf` и debug marker автоматически переносятся при обновлении, новые параметры получают новые defaults.
- README/license приведены в соответствие с GPLv3 `LICENSE`.

## v8.4

Предыдущая версия.
