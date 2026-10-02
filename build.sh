#!/bin/zsh
# Baut InfraLauncher.app nach build/. Braucht nur die Command Line Tools.
#   ./build.sh           bauen
#   ./build.sh install   bauen und nach /Applications kopieren
set -euo pipefail
cd "${0:A:h}"

APP=build/InfraLauncher.app
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  InfraLauncher.swift -o "$APP/Contents/MacOS/InfraLauncher"

swift icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>InfraLauncher</string>
  <key>CFBundleDisplayName</key>      <string>InfraLauncher</string>
  <key>CFBundleIdentifier</key>       <string>io.github.corrooli.infralauncher</string>
  <key>CFBundleExecutable</key>       <string>InfraLauncher</string>
  <key>CFBundleIconFile</key>         <string>AppIcon</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key>          <string>1</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "gebaut: $PWD/$APP"

if [[ "${1:-}" == install ]]; then
  rm -rf /Applications/InfraLauncher.app
  cp -R "$APP" /Applications/
  echo "installiert: /Applications/InfraLauncher.app"
fi
