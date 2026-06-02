#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="MACQ"
BUNDLE_ID="com.macq.app"
MIN_SYSTEM_VERSION="13.0"
CODESIGN_ID="${CODESIGN_ID:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS_PLIST="$APP_CONTENTS/$APP_NAME.entitlements"

DRIVER_BUILD_DIR="$ROOT_DIR/MicEQDriver/build"
DRIVER_BUNDLE="$DRIVER_BUILD_DIR/MicEQ.driver"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-$ROOT_DIR/.swift-build}"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

if [[ -f "$ROOT_DIR/script/generate_assets.sh" ]]; then
  /bin/bash "$ROOT_DIR/script/generate_assets.sh" >/dev/null 2>&1 || true
fi

if [[ -z "$CODESIGN_ID" ]]; then
  CODESIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk '/\"Apple Development:/{print $2; exit}')"
fi
if [[ -z "$CODESIGN_ID" ]]; then
  CODESIGN_ID="-"
  echo "warning: no macOS code signing identity found; using ad-hoc signing (permissions may re-prompt on new builds)" >&2
fi

cmake -S "$ROOT_DIR/MicEQDriver" -B "$DRIVER_BUILD_DIR" -DCODESIGN_ID="$CODESIGN_ID"
cmake --build "$DRIVER_BUILD_DIR" -j

swift build --scratch-path "$SWIFT_SCRATCH_PATH" --disable-index-store --jobs 1 --product "$APP_NAME"
BUILD_BINARY=""
while IFS= read -r candidate; do
  if [[ -x "$candidate" && "$candidate" != *".dSYM"* ]]; then
    BUILD_BINARY="$candidate"
    break
  fi
done < <(find "$SWIFT_SCRATCH_PATH" -type f -name "$APP_NAME" -print)
if [[ -z "$BUILD_BINARY" || ! -x "$BUILD_BINARY" ]]; then
  echo "error: built binary for $APP_NAME was not found under $SWIFT_SCRATCH_PATH" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cp -R "$DRIVER_BUNDLE" "$APP_RESOURCES/MicEQ.driver"
if [[ -f "$ROOT_DIR/Assets/MACQ.icns" ]]; then
  cp "$ROOT_DIR/Assets/MACQ.icns" "$APP_RESOURCES/MACQ.icns"
fi
if [[ -f "$ROOT_DIR/Assets/MACQ_logo.png" ]]; then
  cp "$ROOT_DIR/Assets/MACQ_logo.png" "$APP_RESOURCES/MACQ_logo.png"
fi
if [[ -f "$ROOT_DIR/Assets/MACQMenubarTemplate.png" ]]; then
  cp "$ROOT_DIR/Assets/MACQMenubarTemplate.png" "$APP_RESOURCES/MACQMenubarTemplate.png"
fi
if [[ -f "$ROOT_DIR/Assets/MACQMenubarMutedTemplate.png" ]]; then
  cp "$ROOT_DIR/Assets/MACQMenubarMutedTemplate.png" "$APP_RESOURCES/MACQMenubarMutedTemplate.png"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>MACQ.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>0.1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
    <string>MACQ needs microphone access to capture and process audio.</string>
  <key>NSAudioCaptureUsageDescription</key>
    <string>MACQ needs system audio capture to route selected app audio into MicEQ.</string>
  <key>NSScreenCaptureUsageDescription</key>
    <string>MACQ uses macOS audio capture to route selected app audio into MicEQ.</string>

  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>com.macq.preset</string>
      <key>UTTypeDescription</key>
      <string>MACQ EQ Preset</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.json</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>macqeq</string>
        </array>
      </dict>
    </dict>
  </array>

  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>MACQ Preset</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.macq.preset</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

cat >"$ENTITLEMENTS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.system-audio-capture</key>
  <true/>
</dict>
</plist>
PLIST

xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
codesign --force --deep --entitlements "$ENTITLEMENTS_PLIST" -s "$CODESIGN_ID" "$APP_BUNDLE" >/dev/null 2>&1 || true

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
