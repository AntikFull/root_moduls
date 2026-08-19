# Архитектура автономного Rewarded QA Engine

## Границы ответственности

- Java AadCore работает в режиме OBSERVE_SUPPRESS_ONLY: наблюдает Activity/View и выполняет best-effort схлопывание известных рекламных поверхностей. Он не подменяет private state сторонних SDK и не генерирует их reward callbacks.
- Детерминированная Java reward-эмуляция доступна только собственному app-owned gateway/test adapter тестовой сборки.
- Native IL2CPP включается только после проверки package/process, текущего signing certificate, SHA-256 DEX, ABI, SHA-256 libil2cpp.so и точных типов метода.
- Любая ошибка проверки оставляет оба backend в состоянии fail-closed.

## Формат target policy

```text
PACKAGE_OR_PROCESS|CURRENT_SIGNER_SHA256|AAD_CORE_DEX_SHA256
```

Принимаются только текущие APK signers. История ротации ключей автоматически не разрешается.

## Формат IL2CPP profile

```text
SCOPE|ABI|LIBIL2CPP_SHA256|TYPE|ASSEMBLY|NAMESPACE|CLASS|METHOD|RETURN_TYPE|PARAM_TYPES[|REWARD_METHOD|REWARD_RETURN_TYPE|REWARD_PARAM_TYPES]
```

PARAM_TYPES содержит точные имена Il2CppType через запятую либо дефис. Поддерживаются только явно проверенные ARM64/ARM32 профили. x86/x86_64 сохраняют Java lifecycle engine, но native trampoline для них отключён.

## Порядок запуска

```text
preAppSpecialize
  -> exact scope
  -> root-read DEX/config
  -> DEX SHA-256
postAppSpecialize
  -> ожидание Application
  -> PackageManager/SigningInfo certificate SHA-256
  -> InMemoryDexClassLoader + defining-loader check
  -> AadCore.init
  -> AUTHORIZED/ACTIVE
  -> libil2cpp SHA-256 + exact signature
  -> native trampoline
```

Для KernelSU/KernelSU Next/APatch требуется совместимый Zygisk implementation.

## App-owned gateway

QA-приложение при необходимости предоставляет класс `ecubz.analytics.disabler.qa.AadGatewayInstaller`
со статическим методом `install(Object facade)`. Объект facade загружен дочерним DEX classloader,
поэтому приложение оборачивает его собственным типизированным adapter и вызывает методы через
контролируемую reflection-границу. Если installer отсутствует, Java-слой остаётся только в
`OBSERVE_SUPPRESS_ONLY` и не создаёт синтетические SDK callbacks.
