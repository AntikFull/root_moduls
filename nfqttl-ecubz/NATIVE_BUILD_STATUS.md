# Native engine build status

The shell/rules/controller layer in this package reads module version metadata from `module.prop`; there is no separate hardcoded runtime module version in these scripts.

## Active prebuilt engines

The shipped executables for these ABIs are inherited prebuilt Android 21 / NDK r26b binaries and pass ELF structural checks:

- arm64-v8a
- x86
- x86_64

They are kept only as the compatibility NFQUEUE fallback when the kernel has no native `TTL` / `HL` xtables target. The default path does not start `nfqttl` when native targets work.

Because these prebuilt executables were built before the current `src/nfqttl.c` hardening, service-side queue overload monitoring and circuit breaking remain enabled by default.

## armeabi-v7a

The inherited v8.4 `armeabi-v7a` ELF is structurally damaged. It is intentionally not shipped as an executable and the installer aborts on ARMv7 instead of pretending support. Appending two bytes to the file was tested and rejected as unsafe because the corruption is not simply an EOF truncation.

## Source ready for a clean Android NDK rebuild

`src/nfqttl.c` now includes:

- module version resolved from `NFQTTL_MODULE_VERSION`, `NFQTTL_MODULE_PROP`, or sibling `module.prop` (no hardcoded module version);
- `-t` updates the TTL actually used by the callback;
- `--split-tcp` disabled instead of exposing the old broken injection path;
- safer socket/error paths;
- larger receive buffer;
- per-queue `nfq_set_queue_maxlen(4096)`;
- `NFQA_CFG_F_FAIL_OPEN`;
- best-effort `NFQA_CFG_F_GSO`;
- no legacy route-handle initialization that could assert/crash;
- no obsolete protocol-family `nfq_unbind_pf` / `nfq_bind_pf` setup.

A clean rebuild requires an Android NDK. This execution environment did not contain an Android NDK/cross sysroot, so the source changes were syntax-checked but could not be compiled into replacement Android binaries here.

Recommended rebuild command from the module root with Android NDK installed:

```sh
ndk-build NDK_PROJECT_PATH=. \
  APP_BUILD_SCRIPT=jni/Android.mk \
  NDK_APPLICATION_MK=jni/Application.mk \
  -j$(nproc)
```

Then validate every `libs/<abi>/nfqttl` both with ELF tools and by actually executing `nfqttl -h` on the corresponding Android ABI before re-enabling ARMv7.
