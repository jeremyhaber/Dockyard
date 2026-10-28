#!/usr/bin/env bash
# Builds rclone's C library (librclone) for the current platform.
#
#   scripts/build-librclone.sh [shared|static]
#
# Output (default build/librclone, override with OUT_DIR):
#   Linux : librclone.so
#   macOS : librclone.dylib (universal arm64+x86_64, install name @rpath/librclone.dylib)
#           or, in static mode, librclone.a (universal)
#   plus the generated librclone.h and VERSION.
#
# Requires Go (>= 1.24) and a C toolchain (clang on macOS, gcc on Linux).
# See docs/internal/rclone.md for how the app embeds the result.
set -euo pipefail

RCLONE_VERSION="${RCLONE_VERSION:-v1.70.3}"
RCLONE_MODULE="github.com/rclone/rclone"
MODE="${1:-shared}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/build/librclone}"
export PATH="$PATH:/usr/local/go/bin"

case "$MODE" in
  shared) BUILDMODE=c-shared ;;
  static) BUILDMODE=c-archive ;;
  *) echo "usage: $0 [shared|static]" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"

(
  cd "$WORK"
  go mod init dockyard.local/librclone-build >/dev/null 2>&1
  go get "$RCLONE_MODULE@$RCLONE_VERSION"
)

build() { # goarch, output file, extra ldflags
  local goarch=$1 out=$2 ldflags=${3:-}
  local cc="${CC:-}"
  if [ "$(uname -s)" = Darwin ]; then
    local arch=$goarch
    [ "$arch" = amd64 ] && arch=x86_64
    cc="clang -arch $arch -mmacosx-version-min=14.0"
  fi
  (
    cd "$WORK"
    CGO_ENABLED=1 GOARCH="$goarch" CC="$cc" \
      go build -trimpath -buildmode="$BUILDMODE" -ldflags "-s -w $ldflags" \
      -o "$out" "$RCLONE_MODULE/librclone"
  )
}

if [ "$(uname -s)" = Darwin ]; then
  ext=dylib
  [ "$MODE" = static ] && ext=a
  ld=""
  [ "$MODE" = shared ] && ld='-extldflags "-install_name @rpath/librclone.dylib"'
  for arch in arm64 amd64; do
    build "$arch" "$WORK/librclone-$arch.$ext" "$ld"
  done
  lipo -create "$WORK/librclone-arm64.$ext" "$WORK/librclone-amd64.$ext" -output "$OUT_DIR/librclone.$ext"
  cp "$WORK/librclone-arm64.h" "$OUT_DIR/librclone.h"
else
  ext=so
  [ "$MODE" = static ] && ext=a
  build "$(go env GOARCH)" "$WORK/librclone.$ext"
  cp "$WORK/librclone.$ext" "$WORK/librclone.h" "$OUT_DIR/"
fi

echo "$RCLONE_VERSION" > "$OUT_DIR/VERSION"
echo "Built librclone $RCLONE_VERSION ($MODE) in $OUT_DIR"
ls -la "$OUT_DIR"
