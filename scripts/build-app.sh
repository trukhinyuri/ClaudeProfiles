#!/bin/sh
# Builds ClaudeUnlimited.app into ./build. Usage: scripts/build-app.sh [version]
set -eu

cd "$(dirname "$0")/.."
VERSION="${1:-$(git describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
APP="build/ClaudeUnlimited.app"

swift build -c release --product ClaudeUnlimited
swift build -c release --product claude-unlimited
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ClaudeUnlimited" "$APP/Contents/MacOS/ClaudeUnlimited"
cp "$BIN/claude-unlimited" "$APP/Contents/Helpers/claude-unlimited"
"$BIN/claude-unlimited" __render-app-icon "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.trukhinyuri.claudeunlimited</string>
  <key>CFBundleName</key><string>ClaudeUnlimited</string>
  <key>CFBundleDisplayName</key><string>ClaudeUnlimited</string>
  <key>CFBundleExecutable</key><string>ClaudeUnlimited</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for apps you build yourself. Distributed builds should use a Developer ID.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/Helpers/claude-unlimited"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP ($VERSION)"
