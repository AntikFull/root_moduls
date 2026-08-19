# Rewarded QA Architecture Guide

Этот файл описывает только **app-owned QA/test** сценарий rewarded-рекламы. В production/сторонних приложениях AAD не должен генерировать reward callbacks, подменять приватное состояние рекламных SDK или обещать начисление награды.

## Границы

- Java `AadCore` работает как `OBSERVE_SUPPRESS_ONLY`: наблюдение и best-effort схлопывание известных рекламных поверхностей.
- Детерминированная reward-эмуляция разрешена только собственному test adapter/gateway QA-приложения.
- Native IL2CPP активируется только для явно разрешённого QA target после проверки package/process, signer SHA-256, DEX SHA-256, ABI, `libil2cpp.so` SHA-256 и точной сигнатуры метода.
- Любая неоднозначность или ошибка проверки = fail-closed, без hook/эмуляции.
- Shipped `qa_targets.list` по умолчанию не содержит активных target-записей.

## Target policy

```text
PACKAGE_OR_PROCESS|CURRENT_SIGNER_SHA256|AAD_CORE_DEX_SHA256
```

## IL2CPP profile

```text
SCOPE|ABI|LIBIL2CPP_SHA256|TYPE|ASSEMBLY|NAMESPACE|CLASS|METHOD|RETURN_TYPE|PARAM_TYPES[|REWARD_METHOD|REWARD_RETURN_TYPE|REWARD_PARAM_TYPES]
```

Профиль должен описывать точный QA-owned target. Wildcard/heuristic reward hooks не допускаются.

## Порядок допуска

```text
exact target scope
  -> root-owned config/DEX
  -> DEX SHA-256
  -> current signing certificate SHA-256
  -> controlled InMemoryDexClassLoader
  -> app-owned QA gateway (если он есть)
  -> exact libil2cpp hash/signature (только для разрешённого native QA profile)
```

Если app-owned gateway отсутствует, Java-слой остаётся в `OBSERVE_SUPPRESS_ONLY`.

Подробная спецификация границ находится также в `QA_MOCK_ARCHITECTURE.md`.
