#!/system/bin/sh

load_module_metadata() {
  local metadata_file="${1:-$MODDIR/module.prop}"

  MODULE_VERSION_LABEL="$(sed -n 's/^version=//p' "$metadata_file" 2>/dev/null | tr -d '\r' | head -n 1)"
  MODULE_VERSION_CODE="$(sed -n 's/^versionCode=//p' "$metadata_file" 2>/dev/null | tr -d '\r' | head -n 1)"

  [ -n "$MODULE_VERSION_LABEL" ] || MODULE_VERSION_LABEL="unknown"
  [ -n "$MODULE_VERSION_CODE" ] || MODULE_VERSION_CODE="0"
}
