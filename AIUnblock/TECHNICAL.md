
AIUnblock РРРСРРРСРС **СРРСРР РСРСРРРСР Android-РСРРРРРРРС** СРСРР РСРРСР Smart-DNS/SNI/DNAT РРСССССС. РРССРРРСР DNS Android РР РРРСРССС.

ZIP СССРРРРРРРРРССС СРСРР РСРРРРРРРР Magisk, KernelSU РРР APatch Manager. Legacy `META-INF/update-binary` СРРРСР: РР РСР Magisk-only Р РР РСРРР РСР СССРРРРРР СРСРР СРРСРРРРРСР manager-РСРРРРРРРС. Recovery-flash РРС ССРР СРРРРССРРСРРР СРРСРР РР РРСРРСРССС.

РРРРРССРРСРСР ZIP СРРРСРРС РРСРРРРР СРСР РРС:

- `arm64-v8a`
- `armeabi-v7a`
- `x86_64`
- `x86`

РССРРРРСРР СРР РСРРСРРС РСРРСР РРСРРРС Р РСРРРРСРС `aiunblock-native self-test` РСС РР РРРРССРРРС СССРРРРРР. РР ССССРРССРР РССРСССС СРРСРР РСРСРРРСР РРРРСРРР.

РРСРРРСР РРРРРРРРС РРСРРРССС Р `src/native/main.go` Р РРСРСРРРРРРРРР СРРРСРРССС `tools/build-native.sh` РРР cgo. РРС `arm64-v8a` РСРРРРРР РРСРРРС в Android PIE С `/system/bin/linker64` Р РРССРРСРРР ELF `DT_HASH`; ССРРР РРРРС ССРСРСРСРРР fallback РРР `PT_INTERP`. РРС `armeabi-v7a`, `x86_64` Р `x86` РСРРРСРССССС ССРСРСРСРРР pure-Go ELF РРР РРРРСРРРССР РС bionic. РССРРРРСРР РСРРРССРС SHA-256 Р РРРССРРРС `self-test` РСРСРРРРРР РРРРСРРРР РССРР РР ССССРРССРР. РСРССР РСРРРРРРСР stripped `aiunblock-router` Р bundled curl РРРССР РР РСРРРСРССССС. РРРР native core СРРРРРСРС SNI-router, TLS-РСРРРСРС gateway, DNS Р DoH.

РЁСРСРСР СРРСРР РРСРРРССС Р `apps.list`. РРРСРРРРСРРССРРР РРРРРРРРРС в Р `/data/adb/modules/AIUnblock/apps.user.list`. РСРРРРРР firewall РСРРРРСРССС СРРСРР Р РРРРРРРСР UID ССРС РРРРСРР, РРРССРС secondary/work profile.

`FAIL_MODE=0` в СРРСРР РСР РРРСРР РРСРРР СРРСРСРСС РССРРР РРРРРССРРРР. Р РРСРРРСРРР СРССРСРРР РСРРРРР AIUnblock РССРСССС РРСРРРСРР.

`FAIL_MODE=1` в РСР РРРСРР РРСРРР РРРРРСРРРСС РССРРР РССРР РСРСРРРСС РСРРРРРРРР РР РРСССРРРРРРРРС.

РРС Google App РРРРСР fail-block РР РСРРРРСРССС, ССРРС СРРР Gemini-SNI РР РРРРРСРРРР РРСС Google App.

Hosts РР СРРСРССС СРСССС СРСРРРРР СРСР Р РР СРРРСРРРС РСРРССРР. РСР РРРСРРРСР С РССРРР hosts-РРРСРРР РСРРССРРССС СРРСРР optional hosts AIUnblock; per-app routing РСРРРРРРРС СРРРСРСС.

РРСРРР `system/etc/hosts` РРСРРРССС РР mount stage РР РСРРР РРРРРРРСР root. РРРРСРСРРРРР РРР РСРСРРРР РРР РРС в РСРРРССРССС РРСРР РРРССРРР РР РРСРРСС `# AIUnblock-hosts` Р `/system/etc/hosts`. РСРССС РРРРР Р `aiunblockctl status` Р Р РССССР:

| РСРССС | РРРСРРРР |
| --- | --- |
| `disabled` | РРР hosts-ССРРСРР РСРРССРРС Р `install.conf` |
| `conflict:<id>` | РРРРРР РССРРР РРСРРРСР hosts-РРРСРС |
| `prepared` / `prepared:ksu-overlayfs` | РРСРРР РРСРРР, РРСР mount stage |
| `active` | overlay СРРРСРР РСРРРРРРСС |
| `not-mounted` | РСРСРРРР/РРРРРРРС root РР СРРРСРСРРРР overlay; per-app РРСРР СРРРСРРС |

РСРРСРРРРС СРСССРСРР РР РРРРРРРСРРР СРСРР РСРРСРРРРРР Р РСРСРССРР:

- РСРРСРРРРРР СРР Р 120С Р ССРСРРР СРССРСРРР Р СРР Р 15С СРРСРР РРРР СРССРСРРР РР `ok`/`noapps`;
- ССРСРРР РСРРСРРРРРР в ССР ~2 РСРСРССР (`ip route get` Р `stat` РР `packages.list`), РСРРРСРР СРССРСР РРСС ССРРССРРРР СРРРР;
- РРРРРС РРСРРСРРРСРР (DNS-auth, DoH, TLS-РСРРС gateway) в СРР Р 30 РРРСС; РСР РРРСРР РРРСРСС С РСРРСРР 30 в 900С;
- UID РСРРРРРРРР СРСРСССС РР `/data/system/packages.list`, `pm` РСРСРРРССС СРРСРР РРР РРРРСРРР РССС;
- РСРРС РРССССС РР `/proc/uptime`, РРССРРС СРСРРСРРРР РР РРРРРССС РСР РРССРРСРР СРСРР.

РРССРРРС РРРСРРРРСРРС СРСРРРРР РР РСРРР. РРРР РРСРРРРСССССС Р:

`/sdcard/eCubz/AIUnblock/logs`

РРРРРР Action СРРРСРРС СРССРСРРРСС РРРРРРССРРС ССРР РР. `aiunblockctl status` СРРРР РРРРРСРРРС ABI Р СРРСРССРС native self-test.

РРС `gemini_sni` РРСС TCP/443 РСРСРРРРРР UID РРРРРРРС Р РРРРРСРСР SNI-router. Exact-SNI РР `sni_routes.conf` РСРСРРРССССС СРСРР РСРСРРРСР gateway, РССРРСРСР СРРРРРРРРС РРРРСРСРСССС РР РССРРРСР IPv4 destination, РРРССРРРСР СРСРР `SO_ORIGINAL_DST`. РРСРРРС С rc5 РРРССРРРР original destination РСРРРСРСРС СРССРРРСР Go `getsockopt` wrapper РРС РРРРРР ABI, РРР hard-coded syscall numbers.
