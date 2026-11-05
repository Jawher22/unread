#!/bin/bash
# Build Unread.app: release build, bundle, sign.
# With Xcode installed it also builds the narrator helper (scripts/build-narrator.sh)
# and bundles it, its Metal library and the voice presets.
#
#   scripts/bundle.sh             # → build/Unread.app
#   scripts/bundle.sh --install   # …and copy it to ~/Applications, then restart it
#
# Signing: uses $UNREAD_SIGN_IDENTITY if set, otherwise the first
# "Apple Development" identity in the keychain. macOS ties the Accessibility
# grant to the signing certificate, so a stable identity means you grant it
# once and it survives rebuilds. Ad-hoc signing (the fallback) changes every
# build and you'll have to re-grant Accessibility each time.
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE_ID="com.jawher22.unread"
VERSION="0.1.0"
APP="build/Unread.app"

scripts/build.sh
NARRATOR=""
if [[ -d "${NARRATOR_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" ]]; then
    if scripts/build-narrator.sh; then
        NARRATOR="Narrator/.build/release"
    else
        echo "warning: the narrator helper didn't build, so it isn't in this build" >&2
    fi
else
    echo "warning: no Xcode, so no narrator helper in this build" >&2
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Unread "$APP/Contents/MacOS/Unread"
cp -R Resources/Voices "$APP/Contents/Resources/Voices"
if [[ -n "$NARRATOR" ]]; then
    cp "$NARRATOR/unread-narrator" "$APP/Contents/MacOS/unread-narrator"
    cp "$NARRATOR/mlx.metallib" "$APP/Contents/Resources/mlx.metallib"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>                <string>Unread</string>
    <key>CFBundleDisplayName</key>         <string>Unread</string>
    <key>CFBundleExecutable</key>          <string>Unread</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>${VERSION}</string>
    <key>CFBundleVersion</key>             <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>      <string>15.0</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
</dict>
</plist>
PLIST

IDENTITY="${UNREAD_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
if [[ -n "$IDENTITY" ]]; then
    echo "Signing with: $IDENTITY"
else
    echo "warning: no signing identity found; signing ad-hoc (Accessibility must be re-granted after every rebuild)" >&2
    IDENTITY="-"
fi
# The helper is nested code: sign it before the app that seals it.
if [[ -n "$NARRATOR" ]]; then
    codesign --force --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID.narrator" "$APP/Contents/MacOS/unread-narrator"
fi
codesign --force --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/Unread.app"
    mkdir -p "$HOME/Applications"
    # Quit the running copy so the new build is what's running afterwards.
    if pgrep -xq Unread; then
        pkill -x Unread || true
        for _ in $(seq 1 50); do pgrep -xq Unread || break; sleep 0.1; done
        pgrep -xq Unread && { pkill -9 -x Unread || true; sleep 0.3; }
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    echo "Installed $DEST"
    open "$DEST"
    for _ in $(seq 1 50); do pgrep -xq Unread && break; sleep 0.1; done
    if pgrep -xq Unread; then echo "Restarted Unread (pid $(pgrep -x Unread | head -1))"; else echo "warning: Unread didn't start" >&2; exit 1; fi
fi
