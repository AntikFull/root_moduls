#!/system/bin/sh
umask 077

MODDIR="${0%/*}"
CONTROL="$MODDIR/bin/zapret2-control"

echo "РРСРРРРССР Zapret2 eCubz..."
sh "$MODDIR/service.sh" reload
sleep 1
if [ -x "$CONTROL" ]; then
  echo ""
  "$CONTROL" status
  echo ""
  echo "РСРР health РР OK: WebUI -> РРРРРРССРРР -> РРРСРСС РРРРРРССРРС."
fi
echo "WebUI РСРССРРРССС ССРСРР СР СССРРРСС РРРСРС Р KernelSU Next; HTTP-СРСРРС РР РСРРРСРСРССС."
