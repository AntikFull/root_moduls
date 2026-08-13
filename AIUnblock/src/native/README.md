
РСРССССР РРСРРРСР РРРРРРРРС AIUnblock. РРРР Р СРС РР РССРРРРР СРРРСРРССС РРС:

- arm64-v8a (`android/arm64` primary + `linux/arm64` static fallback)
- armeabi-v7a (`linux/arm`, GOARM=7)
- x86_64 (`linux/amd64`)
- x86 (`linux/386`)

РРРСРР РРРРСРРРР РРР cgo. РРС ARM64 СРРРРСССС РСРРРРРР Android PIE С `/system/bin/linker64` Р РРССРРСРРР `DT_HASH`, Р СРРРР ССРСРСРСРРР fallback РРР `PT_INTERP`. РРС ARMv7/x86_64/x86 РСРРРСРССССС ССРСРСРСРРР pure-Go ELF. РССРРРРСРР РРСРРСРРСРР РСРРРРСРС on-device `self-test`, РРССРРС РРСРРРРССРРСР ELF РР РРРРС РССС РСРРСС РРРСР. РСРССР stripped Android ELF С РСРРРРР `DT_HASH/DT_GNU_HASH` РРРССР РР РСРРРСРСРССС.

РРРРРРС: `router`, `tls-probe`, `dns`, `doh`, `self-test`, `version`.
