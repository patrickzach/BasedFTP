#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
# Cross-compile each slice against the same minimum macOS version.
UNIVERSAL_ROOT="$PWD/.build/universal"
mkdir -p "$UNIVERSAL_ROOT"
for TARGET_ARCH in arm64 x86_64; do
    TARGET_TRIPLE="${TARGET_ARCH}-apple-macosx14.0"
    TARGET_SCRATCH="$UNIVERSAL_ROOT/$TARGET_ARCH"
    swift build -c release -debug-info-format none --triple "$TARGET_TRIPLE" \
        --scratch-path "$TARGET_SCRATCH" --disable-sandbox --cache-path "$PWD/.build/cache"
    BIN_DIR="$(swift build -c release -debug-info-format none --triple "$TARGET_TRIPLE" \
        --scratch-path "$TARGET_SCRATCH" --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache")"
    cp "$BIN_DIR/BasedFTP" "$UNIVERSAL_ROOT/BasedFTP.$TARGET_ARCH"
done
lipo -create "$UNIVERSAL_ROOT/BasedFTP.arm64" "$UNIVERSAL_ROOT/BasedFTP.x86_64" \
    -output "$UNIVERSAL_ROOT/BasedFTP.universal"
for TARGET_ARCH in arm64 x86_64; do
    lipo "$UNIVERSAL_ROOT/BasedFTP.universal" -verify_arch "$TARGET_ARCH"
done
APP="$PWD/build/BasedFTP.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# Replace the executable inode so an already-running app retains its old mapping.
cp "$UNIVERSAL_ROOT/BasedFTP.universal" "$APP/Contents/MacOS/BasedFTP.new"
mv -f "$APP/Contents/MacOS/BasedFTP.new" "$APP/Contents/MacOS/BasedFTP"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BasedFTP</string>
<key>CFBundleIdentifier</key><string>app.basedftp.client</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>BasedFTP</string>
<key>CFBundleDisplayName</key><string>BasedFTP</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string></array>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Universal app (arm64 + x86_64): %s\n' "$APP"
