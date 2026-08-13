#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/src/native"
VERSION=$(sed -n 's/^version=//p' "$ROOT/module.prop" | head -n1)
OUT="$ROOT/bin"
command -v go >/dev/null 2>&1 || { echo "Go is required" >&2; exit 1; }
rm -rf "$OUT/arm64-v8a" "$OUT/armeabi-v7a" "$OUT/x86_64" "$OUT/x86"
mkdir -p "$OUT/arm64-v8a" "$OUT/armeabi-v7a" "$OUT/x86_64" "$OUT/x86"
LDFLAGS="-s -w -buildid= -X main.version=$VERSION"

cd "$SRC"

GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="$LDFLAGS" -o "$OUT/arm64-v8a/aiunblock-native" .
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="$LDFLAGS" -o "$OUT/arm64-v8a/aiunblock-native.static" .

GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="$LDFLAGS" -o "$OUT/armeabi-v7a/aiunblock-native" .
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="$LDFLAGS" -o "$OUT/x86_64/aiunblock-native" .
GOOS=linux GOARCH=386 GO386=sse2 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags="$LDFLAGS" -o "$OUT/x86/aiunblock-native" .

(
  cd "$OUT"
  : > SHA256SUMS.all
  for f in arm64-v8a/aiunblock-native arm64-v8a/aiunblock-native.static armeabi-v7a/aiunblock-native x86_64/aiunblock-native x86/aiunblock-native; do
    sha256sum "$f" | sed 's/ \*/  /' >> SHA256SUMS.all
  done
  {
    echo "AIUnblock native build"
    echo "module_version=$VERSION"
    echo "builder=$(go version)"
    echo "arm64-v8a=android/arm64 primary + linux/arm64 static fallback"
    echo "armeabi-v7a=linux/arm GOARM=7 static"
    echo "x86_64=linux/amd64 static"
    echo "x86=linux/386 GO386=sse2 static"
    echo "cgo=disabled"
  } > BUILDINFO.txt
)
