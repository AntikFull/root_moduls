#!/system/bin/sh
MODDIR=${0%/*}
CTL="$MODDIR/bin/aiunblockctl"
PUBLIC_LOG_DIR="/sdcard/eCubz/AIUnblock/logs"

echo "AI Unblock: РСРРРССС СРССРСРРР..."
if [ ! -x "$CTL" ]; then
  echo "РСРРРР: РРРРРРРРС РРРРРРССРРР РССССССРСРС."
  exit 1
fi

"$CTL" refresh >/dev/null 2>&1 || true
"$CTL" diag manual

echo "-----------------------------------"
echo "РРСРРР."
echo "РСРСРРССР Р РРРРРСРРС РРРРС:"
echo "$PUBLIC_LOG_DIR"
