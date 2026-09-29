#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

RESTART=false
for arg in "$@"; do
  case "$arg" in
    --restart) RESTART=true ;;
    *) print -u2 "Неизвестный аргумент: $arg (поддерживается только --restart)"; exit 2 ;;
  esac
done

readonly APP_NAME="XcodeCleaner"
readonly BUNDLE_ID="dev.ltheresi.xcodecleaner"
readonly VERSION="1.0.0"
readonly MIN_OS="15.0"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR=".build/${APP_NAME}.app"

rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

ICON_KEY=""
if [[ -f Assets/AppIcon.png ]]; then
  ICONSET=".build/AppIcon.iconset"
  rm -rf "$ICONSET"
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
rm -rf "$DEST"
cp -R "$APP_DIR" "$DEST"
print "Готово: ${DEST}"

if [[ "$RESTART" == true ]] && pgrep -x "$APP_NAME" >/dev/null; then
  print "Закрываю запущенную версию…"
  osascript -e "quit app id \"${BUNDLE_ID}\"" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.5
  done
fi

if pgrep -x "$APP_NAME" >/dev/null; then
  print "${APP_NAME} уже запущен, и это старая сборка: новая откроется только после его закрытия."
  print "Закройте его (⌘Q) и откройте ${DEST}, либо запустите ./build.sh --restart."
else
  open "$DEST"
fi
