#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

readonly APP_NAME="XcodeCleaner"
readonly BUNDLE_ID="dev.ltheresi.xcodecleaner"
readonly VERSION="1.0.0"
readonly MIN_OS="15.0"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR=".build/${APP_NAME}.app"

[[ -d "$APP_DIR" ]] && rm -r "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

ICON_KEY=""
if [[ -f Assets/AppIcon.png ]]; then
  ICONSET=".build/AppIcon.iconset"
  [[ -d "$ICONSET" ]] && rm -r "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Assets/AppIcon.png --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Assets/AppIcon.png --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"
  ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_OS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
${ICON_KEY}
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR"

DEST="${HOME}/Desktop/${APP_NAME}.app"
[[ -d "$DEST" ]] && rm -r "$DEST"
cp -R "$APP_DIR" "$DEST"
print "Готово: ${DEST}"
