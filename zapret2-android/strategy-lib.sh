#!/system/bin/sh

STRATEGY_DIR="${STRATEGY_DIR:-$MODDIR/strategies}"

# ------------------------------------------------------------------------------
# Подпись применённой конфигурации.
#
# Живёт здесь, а не в service.sh, потому что её обязаны считать одинаково три
# места: service.sh (записывает после старта), service-watch.sh (сверяет раз в
# минуту) и on_change.sh (обновляет после лёгкой реконсиляции). Пока формула
# была скопирована в два файла, любое расхождение в списке файлов или их порядке
# превращалось в бесконечный цикл перезагрузок.
#
# Пути берутся от MODDIR, а не от переменных вызывающего: так результат не
# зависит от того, какие имена заведены в конкретном скрипте.
# ------------------------------------------------------------------------------
config_signature() {
  local base="${MODDIR:?}" lists f
  lists="$base/lists"
  [ -d "$lists" ] || lists="$base"
  {
    printf 'CONF\n'; cat "$base/zapret2.conf" 2>/dev/null
    # Набор ОБЯЗАН совпадать с ветками on_change.sh, иначе правка одного и
    # того же файла обрабатывается двумя механизмами по-разному. Списки
    # приложений (apps*.list, exclude.list, auto_apps.list, warp_apps*.list,
    # smart_youtube.list) удалены в v4.0.0 и в подписи больше не нужны;
    # ipset.list и ipset_exclude.list, наоборот, отсутствовали в ней.
    for f in user.list exclude_domains.list ipset.list ipset_exclude.list \
             warp_bypass_nets.list warp_domains.list warp_domains.user.list \
             geo_warp.list geo_warp.user.list apps_black.list \
             dns.list dns.user.list probe_hosts.list wifi_direct_ssids.list; do
      printf 'F=%s\n' "$f"; cat "$lists/$f" 2>/dev/null
    done
    printf 'STRATEGIES=%s\n' "$(strategy_catalog_signature 2>/dev/null)"
  } | cksum 2>/dev/null | awk '{print $1 "-" $2; exit}'
}

# Файлы, которые пишет сам модуль (state/auto.list с выученными доменами,
# state/warp_auto_domains.list), в подпись НЕ входят: иначе каждая запись
# выученного домена выглядела бы как правка конфигурации и вызывала перезапуск.
write_config_signature() {
  local sig tmp file="${RUN_DIR:-$MODDIR/run}/config.sig"
  sig=$(config_signature)
  [ -n "$sig" ] || return 0
  mkdir -p "${file%/*}" 2>/dev/null
  tmp="$file.tmp.$$"
  printf '%s\n' "$sig" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null
  chmod 0600 "$file" 2>/dev/null || true
}

strategy_args_valid() {
  [ -n "$1" ] && [ "${#1}" -le 8192 ] || return 1
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[-A-Za-z0-9_.,:=/@+% /]+$' || return 1
  case " $1 " in
    *' --qnum='*|*' --qnum '*|*' --user='*|*' --user '*|*' --daemon'*|*' --pidfile='*|*' --pidfile '*|*' --lua-init='*|*' --lua-init '*|*' --debug'*|*' --new '*|*' --new') return 1 ;;
  esac
}

strategy_id_valid() {
  local number
  case "$1" in strategy_*) number=$(printf '%s\n' "$1" | cut -d_ -f2-) ;; *) return 1 ;; esac
  case "$number" in ''|0|0*|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

strategy_list() {
  local path id number list_file
  list_file="${RUN_DIR:-${TMPDIR:-/data/local/tmp}}/strategy-list.$$"
  : > "$list_file" 2>/dev/null || return 1
  for path in "$STRATEGY_DIR"/strategy_*; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    id=$(basename "$path")
    strategy_id_valid "$id" || continue
    number=$(printf '%s\n' "$id" | cut -d_ -f2-)
    printf '%s|%s|%s\n' "$number" "$id" "$path" >> "$list_file"
  done
  sort -t '|' -k1,1n "$list_file"
  rm -f "$list_file" 2>/dev/null
}

strategy_read() {
  local id="$1" path size line args="" prefix="" mode=NFQWS name=""
  STRATEGY_FILE_ID=""; STRATEGY_FILE_NAME=""; STRATEGY_FILE_MODE=""; STRATEGY_FILE_ARGS=""
  strategy_id_valid "$id" || return 1
  path="$STRATEGY_DIR/$id"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  size=$(wc -c < "$path" 2>/dev/null)
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -le 16384 ] 2>/dev/null || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$line" in
      *"$(printf '\r')"*) return 1 ;;
      '# NAME='*) name=${line#\# NAME=} ;;
      '# MODE=DIRECT') mode=DIRECT ;;
      ''|'#'*) ;;
      *) args="${args}${args:+ }$line" ;;
    esac
  done < "$path"

  [ -n "$name" ] || name=$id
  [ "${#name}" -le 64 ] || return 1
  printf '%s' "$name" | LC_ALL=C grep -Eq '^[A-Za-z0-9_.-]+$' || return 1
  case "$mode" in
    DIRECT) [ -z "$args" ] || return 1 ;;
    NFQWS)
      strategy_args_valid "$args" || return 1
      case " $args " in *' --filter-tcp='*) ;; *) prefix="$prefix --filter-tcp=443" ;; esac
      case " $args " in *' --filter-l7='*) ;; *) prefix="$prefix --filter-l7=tls" ;; esac
      case " $args " in *' --out-range='*) ;; *) prefix="$prefix --out-range=-d10" ;; esac
      case " $args " in *' --payload='*) ;; *) prefix="$prefix --payload=tls_client_hello" ;; esac
      args="${prefix# } $args"
      ;;
    *) return 1 ;;
  esac
  STRATEGY_FILE_ID=$id; STRATEGY_FILE_NAME=$name; STRATEGY_FILE_MODE=$mode; STRATEGY_FILE_ARGS=$args
}

strategy_first_valid() {
  local number id path
  strategy_list | while IFS='|' read -r number id path; do
    if strategy_read "$id"; then
      printf '%s\n' "$id"
      break
    fi
  done
}

strategy_catalog_signature() {
  {
    strategy_list | while IFS='|' read -r number id path; do
      printf 'FILE=%s\n' "$id"
      cat "$path"
      printf '\n'
    done
  } | cksum 2>/dev/null | awk '{print $1 "-" $2; exit}'
}
