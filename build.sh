#!/bin/zsh
# Builds InfraLauncher.app into build/. Needs only the Command Line Tools.
#   ./build.sh           build
#   ./build.sh install   build and copy to /Applications
set -euo pipefail
cd "${0:A:h}"

APP=build/InfraLauncher.app
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal: one pass each for Apple Silicon and Intel, then merge.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos14.0 \
    Sources/*.swift -o build/InfraLauncher-$arch
done
lipo -create build/InfraLauncher-arm64 build/InfraLauncher-x86_64 -output "$APP/Contents/MacOS/InfraLauncher"
rm build/InfraLauncher-arm64 build/InfraLauncher-x86_64

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
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key>          <string>2</string>
  <key>LSMinimumSystemVersion</key>   <string>14.0</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSAppleEventsUsageDescription</key><string>InfraLauncher opens shell services in iTerm2 when you pick it as your terminal.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "built: $PWD/$APP"

if [[ "${1:-}" == install ]]; then
  rm -rf /Applications/InfraLauncher.app
  cp -R "$APP" /Applications/
  echo "installed: /Applications/InfraLauncher.app"
fi
