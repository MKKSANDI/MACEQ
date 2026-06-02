#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS_DIR="$ROOT_DIR/Assets"

mkdir -p "$ASSETS_DIR"

chmod +x "$ROOT_DIR/script/generate_assets.swift" || true
/usr/bin/env swift "$ROOT_DIR/script/generate_assets.swift" "$ASSETS_DIR"

ICON_PNG="$ASSETS_DIR/MACQ_icon_1024.png"
ICONSET_DIR="$ASSETS_DIR/MACQ.iconset"
ICNS_OUT="$ASSETS_DIR/MACQ.icns"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

make_icon() {
  local size="$1"
  local out="$2"
  /usr/bin/sips -z "$size" "$size" "$ICON_PNG" --out "$out" >/dev/null
}

make_icon 16  "$ICONSET_DIR/icon_16x16.png"
make_icon 32  "$ICONSET_DIR/icon_16x16@2x.png"
make_icon 32  "$ICONSET_DIR/icon_32x32.png"
make_icon 64  "$ICONSET_DIR/icon_32x32@2x.png"
make_icon 128 "$ICONSET_DIR/icon_128x128.png"
make_icon 256 "$ICONSET_DIR/icon_128x128@2x.png"
make_icon 256 "$ICONSET_DIR/icon_256x256.png"
make_icon 512 "$ICONSET_DIR/icon_256x256@2x.png"
make_icon 512 "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_PNG" "$ICONSET_DIR/icon_512x512@2x.png"

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"
rm -rf "$ICONSET_DIR"

echo "Generated:"
echo "  $ASSETS_DIR/MACQ_logo.png"
echo "  $ASSETS_DIR/MACQ_icon_1024.png"
echo "  $ASSETS_DIR/MACQ.icns"

