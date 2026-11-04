#!/bin/bash
# Build Unread.app: release build, bundle, sign.
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

swift build -c release
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Unread "$APP/Contents/MacOS/Unread"

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
    codesign --force --timestamp=none --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "warning: no signing identity found; signing ad-hoc (Accessibility must be re-granted after every rebuild)" >&2
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
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
