#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release -debug-info-format none --disable-sandbox --cache-path "$PWD/.build/cache"
BIN_DIR="$(swift build -c release -debug-info-format none --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache")"
APP="$PWD/build/BasedFTP.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/BasedFTP" "$APP/Contents/MacOS/BasedFTP"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BasedFTP</string>
<key>CFBundleIdentifier</key><string>app.basedftp.client</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>BasedFTP</string>
<key>CFBundleDisplayName</key><string>BasedFTP</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Startbare App: %s\n' "$APP"
