#!/bin/zsh
# Builds build/Glint.app (release) and signs it with the local Apple Development identity so the
# Screen Recording permission survives rebuilds (ad-hoc signatures change every build).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP="build/Glint.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Glint" "$APP/Contents/MacOS/Glint"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Glint</string>
  <key>CFBundleDisplayName</key><string>Glint</string>
  <key>CFBundleIdentifier</key><string>no.oleeskild.glint</string>
  <key>CFBundleExecutable</key><string>Glint</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.2</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>no.oleeskild.glint</string>
      <key>CFBundleURLSchemes</key><array><string>glint</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

IDENTITY="${GLINT_SIGN_IDENTITY:-$(security find-identity -p codesigning -v | awk -F'"' '/Apple Development/{print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
