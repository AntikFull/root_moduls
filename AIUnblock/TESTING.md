# AIUnblock Testing Protocol

После установки и перезагрузки устройства убедитесь, что создана папка `/sdcard/eCubz/AIUnblock/logs` и файл `AIUnblock_report.txt`. Проверка работы проводится по пунктам.

1. **Архитектура CPU:** при установке проверяются `arm64-v8a`, `armeabi-v7a`, `x86_64` и `x86`; установщик выбирает правильный `aiunblock-native`, `self-test` должен проходить успешно.
2. **Magisk:** Android 14, 15, 16 — установка, reboot, проверка доступа к ChatGPT/Gemini/Claude/Grok/NotebookLM, переключение Wi-Fi/mobile.
3. **KernelSU / KernelSU Next:** core-only или metamodule должны работать; hosts должен учитывать `no-metamodule`.
4. **APatch:** установка, reboot, UID-правила, перезапуск роутера, uninstall.
5. **Сторонние hosts-модули:** в bindhosts/Systemless Hosts/AdAway: AIUnblock core остается рабочим, `.hosts_status` показывает корректный статус, чужой `/system/etc/hosts` не ломается при uninstall.
6. **Multi-user / Work Profile:** если целевые приложения установлены у другого пользователя, `status` должен подхватывать корректный UID.
7. **Работа сети:** проверка при старте без сети (offline boot), captive portal, переключение на мобильную сеть. Supervisor не должен падать или вызывать утечек.
8. **Шлюзы:** проверка режимов `fail 0` и `fail 1`.
9. **Watchdog роутера:** при принудительном завершении процесса роутер должен автоматически перезапускаться супервизором.
10. **Логирование:** ротация логов без бесконечного роста файлов.
11. **Удаление (Uninstall):** при удалении модуля должны корректно очищаться все созданные правила firewall (`AIUNBLOCK_*`).

Отчет об ошибке должен включать:
- Логи из папки `/sdcard/eCubz/AIUnblock/logs` (`AIUnblock_report.txt` и архивы диагностики при наличии);
- Название и версию Root-менеджера;
- Версию Android / API и модель устройства.
