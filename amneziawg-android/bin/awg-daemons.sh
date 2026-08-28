#!/system/bin/sh
# awg-daemons.sh — единая точка запуска фоновых мониторов (SSOT)
# Подключается из service.sh, action.sh и customize.sh.
#
# Ключевой момент: nohup здесь недостаточно. Процесс, запущенный из сессии su
# или из установщика ZIP, убивается вместе с группой процессов при завершении
# сессии. Отвязка выполняется через setsid, чтобы демон получил ppid=1.

AWG_LIVE_DIR="/data/adb/modules/amneziawg-android"
AWG_LOG_DIR="/data/adb/amneziawg/logs"
BIN_DIR="${MODPATH:-$AWG_LIVE_DIR}/bin"

export PATH="/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$BIN_DIR:/system/bin:/system/xbin:/apex/com.android.runtime/bin:$PATH"

# Каталог с исполняемыми файлами: приоритет у каталога установки MODPATH,
# запасной вариант — рабочий каталог модуля AWG_LIVE_DIR.
awg_daemon_bin_dir() {
  if [ -n "$MODPATH" ] && [ -x "$MODPATH/bin/awg-netmon" ]; then
    printf '%s' "$MODPATH/bin"
  elif [ -x "$AWG_LIVE_DIR/bin/awg-netmon" ]; then
    printf '%s' "$AWG_LIVE_DIR/bin"
  else
    printf '%s' "${MODPATH:-$AWG_LIVE_DIR}/bin"
  fi
}

awg_stop_daemon() {
  # Селектор по полному пути, чтобы не задеть посторонние процессы
  pkill -f "/bin/$1" 2>/dev/null || true
  # pkill асинхронен: даем процессу завершиться, чтобы не поднять дубль
  local w=0
  while [ $w -lt 10 ] && pgrep -f "/bin/$1" >/dev/null 2>&1; do
    sleep 0.2
    w=$((w + 1))
  done
}

awg_start_daemon() {
  local name="$1"
  local bin_dir
  bin_dir="$(awg_daemon_bin_dir)"
  [ -x "$bin_dir/$name" ] || return 1
  mkdir -p "$AWG_LOG_DIR" 2>/dev/null
  local log_file="$AWG_LOG_DIR/${name#awg-}.log"

  # Двойной фон обязателен: внутри фоновой подоболочки процесс гарантированно
  # не является лидером группы, поэтому setsid() отрабатывает и демон уходит
  # в новую сессию. Вызов "setsid cmd &" напрямую срабатывает не всегда.
  if command -v setsid >/dev/null 2>&1; then
    ( setsid "$bin_dir/$name" >>"$log_file" 2>&1 </dev/null & ) &
  else
    ( nohup "$bin_dir/$name" >>"$log_file" 2>&1 </dev/null & ) &
  fi

  # Подтверждение запуска: молчаливый сбой демона недопустим
  local w=0
  while [ $w -lt 15 ]; do
    if pgrep -f "/bin/$name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
    w=$((w + 1))
  done
  return 1
}

restart_monitors() {
  local rc=0
  awg_stop_daemon awg-netmon
  awg_stop_daemon awg-appmon
  awg_start_daemon awg-netmon || rc=1
  awg_start_daemon awg-appmon || rc=1
  return $rc
}
