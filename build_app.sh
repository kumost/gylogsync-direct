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
mkdir -p "$APP_BUNDLE/Contents/Resources/LensProfiles"

# 3. Copy Binaries
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if [ -f "$HELPER_PATH" ]; then
    cp "$HELPER_PATH" "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper"
    echo "Copied GyroflowSyncHelper"
fi

# Strip debug info and private symbols from both binaries to remove
# any leftover host paths and reduce binary size.
echo "Stripping debug symbols for privacy..."
strip -S -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
[ -f "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper" ] && \
    strip -S -x "$APP_BUNDLE/Contents/MacOS/GyroflowSyncHelper" 2>/dev/null || true

# 4. Copy Lens Profiles
if [ -d "Resources/LensProfiles" ]; then
    cp Resources/LensProfiles/*.json "$APP_BUNDLE/Contents/Resources/LensProfiles/"
    echo "Copied lens profiles"
fi

# 5. Create Info.plist
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
    <key>CFBundleShortVersionString</key>
    <string>3.1</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

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

echo "=== Done! $APP_BUNDLE v3.1 is ready (signed + notarized). ==="
open .
