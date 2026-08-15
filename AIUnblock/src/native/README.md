# AIUnblock Native Core

Единое нативное ядро AIUnblock. Собирается для платформ:

- `arm64-v8a` (`android/arm64` primary + `linux/arm64` static fallback)
- `armeabi-v7a` (`linux/arm`, GOARM=7)
- `x86_64` (`linux/amd64`)
- `x86` (`linux/386`)

Сборка выполняется без cgo. Для ARM64 создается Android PIE с `/system/bin/linker64` и поддержкой `DT_HASH`, а также статический fallback без `PT_INTERP`. Для ARMv7/x86_64/x86 используются статические pure-Go ELF. Установщик выполняет on-device `self-test` перед запуском.

Команды: `router`, `tls-probe`, `dns`, `doh`, `self-test`, `version`.
