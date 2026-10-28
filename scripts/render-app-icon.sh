#!/usr/bin/env bash
# Renders App/Icon/AppIcon.svg into the asset catalog's AppIcon.appiconset.
#
#   scripts/render-app-icon.sh
#
# Requires rsvg-convert (brew install librsvg).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/Icon/AppIcon.svg"
OUT="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$OUT"

images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    suffix=""; [ "$scale" = 2 ] && suffix="@2x"
    name="icon_${size}x${size}${suffix}.png"
    rsvg-convert -w "$px" -h "$px" "$SRC" -o "$OUT/$name"
    [ -n "$images" ] && images+=$',\n'
    images+="    { \"idiom\" : \"mac\", \"size\" : \"${size}x${size}\", \"scale\" : \"${scale}x\", \"filename\" : \"$name\" }"
  done
done

cat > "$OUT/Contents.json" <<JSON
{
  "images" : [
$images
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
echo "Rendered $OUT"
