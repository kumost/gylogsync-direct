#!/bin/bash
set -e

cd "$(dirname "$0")"

# 0. Build Rust bridge first
echo "=== Step 1: Building Rust bridge ==="
bash build_rust.sh

# 1. Build the Swift binaries in Release mode
# Privacy: use debug-prefix-map so the compiled Mach-O does not embed
# the builder's absolute home / source paths in debug info.
SRC_DIR="$(pwd)"
echo "=== Step 2: Building Swift app ==="
swift build -c release \
    -Xswiftc -Xfrontend -Xswiftc -debug-prefix-map \
    -Xswiftc -Xfrontend -Xswiftc "${HOME}=/home" \
    -Xswiftc -Xfrontend -Xswiftc -debug-prefix-map \
    -Xswiftc -Xfrontend -Xswiftc "${SRC_DIR}=/source" \
    -Xcc -fdebug-prefix-map="${HOME}=/home" \
    -Xcc -fdebug-prefix-map="${SRC_DIR}=/source"

# 2. Create App Bundle Structure
BINARY_NAME="GyLogSync"
APP_NAME="GyLogSync_Direct"
APP_BUNDLE="$APP_NAME.app"
BINARY_PATH=".build/release/$BINARY_NAME"
HELPER_PATH=".build/release/GyroflowSyncHelper"

echo "Creating $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Copy Binaries
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [ -f "$HELPER_PATH" ]; then
    cp "$HELPER_PATH" "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper"
    echo "Copied GyroflowSyncHelper"
fi

# 3a. Copy Resources: license texts (GPL compliance) + bundled lens profiles
cp LICENSE "$APP_BUNDLE/Contents/Resources/LICENSE"
cp THIRD_PARTY_LICENSES.md "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_LICENSES.md"
if [ -d LensProfiles ]; then
    cp -R LensProfiles "$APP_BUNDLE/Contents/Resources/LensProfiles"
    echo "Copied LensProfiles ($(ls LensProfiles | wc -l | tr -d ' ') files)"
fi

# 3b. Generate AppIcon.icns from Resources/glsd_mark.svg
ICON_SOURCE="Resources/glsd_mark.svg"
if [ -f "$ICON_SOURCE" ]; then
    if ! command -v rsvg-convert >/dev/null 2>&1; then
        echo "WARNING: rsvg-convert not found (brew install librsvg). Skipping app icon."
    else
        ICONSET_DIR=".build/AppIcon.iconset"
        rm -rf "$ICONSET_DIR"
        mkdir -p "$ICONSET_DIR"
        for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
                    128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
                    512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
            size="${spec%%:*}"
            name="${spec##*:}"
            rsvg-convert -w "$size" -h "$size" "$ICON_SOURCE" \
                -o "$ICONSET_DIR/${name}.png"
        done
        iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        rm -rf "$ICONSET_DIR"
        echo "Generated AppIcon.icns from $ICON_SOURCE"
    fi
fi

# Strip debug info and private symbols from both binaries to remove
# any leftover host paths and reduce binary size.
echo "Stripping debug symbols for privacy..."
strip -S -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
[ -f "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper" ] && \
    strip -S -x "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper" 2>/dev/null || true

# 4. Create Info.plist
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.kumoinc.gylogsync</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>2.1.1-beta</string>
    <key>CFBundleVersion</key>
    <string>211</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Helper: force Launch Services to re-read this bundle and restart Finder/Dock
# so the new icon appears immediately. Without this, Finder/Dock keep showing
# the generic icon (or a stale cached version) until the next reboot, because
# macOS caches icons keyed by bundle path and we just overwrote the bundle.
refresh_icon_cache() {
    touch "$APP_BUNDLE" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true
    killall Finder Dock 2>/dev/null || true
}

# Optional early exit for pre-signing verification.
# Usage: SKIP_SIGN=1 bash build_app.sh
if [ "${SKIP_SIGN}" = "1" ]; then
    echo "=== SKIP_SIGN=1: build complete, stopping before signing ==="
    echo "App bundle: $APP_BUNDLE (unsigned, not notarized)"
    refresh_icon_cache
    open .
    exit 0
fi

# 6. Create entitlements file (non-sandboxed, hardened runtime compatible)
cat <<EOF > entitlements.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

# 7. Code sign with Developer ID
SIGNING_IDENTITY="Developer ID Application: KUMO, INC. (XVQKFXR37N)"

echo "=== Step 3: Code signing ==="
# Sign helper first
if [ -f "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper" ]; then
    codesign --force --options runtime --entitlements entitlements.plist \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper"
    echo "Signed GyroflowSyncHelper"
fi

# Sign main app bundle
codesign --force --options runtime --entitlements entitlements.plist \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE"
echo "Signed $APP_BUNDLE"

# Verify
codesign -vvv "$APP_BUNDLE"

# 8. Notarize
echo "=== Step 4: Notarization ==="
ZIP_NAME="${APP_NAME}.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

xcrun notarytool submit "$ZIP_NAME" \
    --keychain-profile "notarytool-profile" \
    --wait

# Staple
xcrun stapler staple "$APP_BUNDLE"

# Clean up
rm -f "$ZIP_NAME" entitlements.plist

# Refresh icon cache so Finder/Dock pick up the new icon without a reboot.
echo "=== Step 5: Refreshing icon cache ==="
refresh_icon_cache

echo "=== Done! $APP_BUNDLE v2.1.1-beta is ready (signed + notarized). ==="
open .
