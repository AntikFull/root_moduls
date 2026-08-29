#!/system/bin/sh
# customize.sh — Установщик модуля AmneziaWG Multi-Profile
# Выполняется менеджером root при установке ZIP-архива

ui_print "**********************************************"
ui_print "*   AmneziaWG Multi-Profile (Root and App)   *"
ui_print "*      Разработка: eCubz (t.me/eCubz)        *"
ui_print "**********************************************"

[ "$ARCH" = "x64" ] && ARCH="x86_64"

ui_print "- Архитектура процессора: $ARCH"

case "$ARCH" in
  arm64)
    SRC_DIR="$MODPATH/binaries/android-arm64"
    ;;
  arm)
    SRC_DIR="$MODPATH/binaries/android-arm"
    ;;
  x86)
    SRC_DIR="$MODPATH/binaries/android-x86"
    ;;
  x86_64)
    SRC_DIR="$MODPATH/binaries/android-x86_64"
    ;;
  *)
    ui_print "! Неизвестная архитектура: $ARCH. Попытка использования arm64..."
    SRC_DIR="$MODPATH/binaries/android-arm64"
    ;;
esac

mkdir -p "$MODPATH/bin" 2>/dev/null # глушение-обосновано: каталог уже есть в архиве модуля
if [ ! -d "$SRC_DIR" ]; then
  ui_print "! Каталог бинарных файлов $SRC_DIR отсутствует в архиве."
  abort "! Установка прервана: нет исполняемых файлов для архитектуры $ARCH."
fi

# Неудачное копирование означает неработоспособный модуль, поэтому ошибка
# не подавляется, а прерывает установку. Прежняя редакция гасила ее в
# /dev/null и завершалась сообщением об успехе с пустым каталогом bin.
ui_print "- Установка исполняемых файлов из $SRC_DIR..."
for f in amneziawg-go awg; do
  if ! cp -f "$SRC_DIR/$f" "$MODPATH/bin/$f"; then
    abort "! Установка прервана: не удалось скопировать $f."
  fi
  if [ ! -s "$MODPATH/bin/$f" ]; then
    abort "! Установка прервана: файл $f скопирован пустым."
  fi
done

rm -rf "$MODPATH/binaries" 2>/dev/null # глушение-обосновано: каталог удаляется после копирования и мог отсутствовать при повторном запуске

ui_print "- Настройка прав доступа (0755)..."
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

DATA_DIR="/data/adb/amneziawg"
mkdir -p "$DATA_DIR/profiles" "$DATA_DIR/run" "$DATA_DIR/logs" "$DATA_DIR/state" 2>/dev/null # глушение-обосновано: при обновлении каталоги уже существуют
chmod 755 "$DATA_DIR" "$DATA_DIR/run" "$DATA_DIR/logs" "$DATA_DIR/state" 2>/dev/null # глушение-обосновано: права уже выставлены прошлой установкой
# Каталог профилей содержит PrivateKey интерфейсов: доступ только владельцу.
chmod 700 "$DATA_DIR/profiles" 2>/dev/null # глушение-обосновано: см. выше
chmod 600 "$DATA_DIR/profiles"/*.conf "$DATA_DIR/profiles"/*.json 2>/dev/null # глушение-обосновано: при первой установке профилей еще нет

# Создание недостающих .conf и .json для конфигураций, положенных в каталог
# вручную. Раньше это делалось внутри пути чтения (audit-conflicts), который
# WebUI вызывает каждые несколько секунд.
if [ -x "$MODPATH/bin/awg" ]; then
  "$MODPATH/bin/awg" init-profiles "$DATA_DIR/profiles" >/dev/null 2>&1 || \
    ui_print "! Инициализация профилей не выполнена, каталог пуст или недоступен."
fi


# Горячий перезапуск мониторов: обновление подменяет файлы скриптов под
# работающим shell, из-за чего awg-netmon умирает и watchdog перестает работать.
if [ -f "$MODPATH/bin/awg-daemons.sh" ]; then
  ui_print "- Перезапуск фоновых мониторов..."
  # shellcheck disable=SC1090
  . "$MODPATH/bin/awg-daemons.sh"
  if restart_monitors; then
    ui_print "- Мониторы awg-netmon и awg-appmon запущены."
  else
    ui_print "! Мониторы не стартовали, watchdog заработает после перезагрузки."
  fi
  # Остановка монитора могла прервать перезапуск профиля на середине:
  # синхронизация поднимает все, что осталось выключенным.
  LIVE_BIN="/data/adb/modules/amneziawg-android/bin/awg-controller"
  [ -x "$LIVE_BIN" ] && "$LIVE_BIN" sync-rules >/dev/null 2>&1
fi

ui_print "- Установка успешно завершена!"
ui_print "- WebUI доступен в менеджере KernelSU / APatch / Magisk."
