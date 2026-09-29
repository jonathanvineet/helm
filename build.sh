#!/bin/zsh
# Builds:
#   build/Helm.saver    the screensaver (slideshow + notes/reminders board)
#   build/Helm.app      menu bar app: keeps the board in sync, Customize window
#   build/helm-render   draws one frame to a PNG, for checking layout
# Usage: ./build.sh [--install]
#   ARCHS="arm64 x86_64"  build universal binaries (release.sh does this)
#   SIGN_IDENTITY=-       sign Helm.app ad hoc instead of with the local identity
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(${=ARCHS:-$(uname -m)})
SAVER=build/Helm.saver
APP=build/Helm.app
# A stable signing identity keeps macOS permissions (Full Disk Access, Reminders)
# across rebuilds; ad-hoc signatures change every build.
IDENTITY="${SIGN_IDENTITY:-Helm Local Signing}"
[[ "$IDENTITY" == "-" ]] || security find-identity -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"

# swiftc once per architecture, then lipo the slices together.
compile() {
    local out=$1; shift
    local slices=()
    for arch in $ARCHS; do
        swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" "$@" -o "$out.$arch"
        slices+=("$out.$arch")
    done
    lipo -create $slices -output "$out"
    rm -f $slices
}

# Screensaver
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp Resources/Saver-Info.plist "$SAVER/Contents/Info.plist"
compile "$SAVER/Contents/MacOS/Helm" -module-name HelmSaver -emit-library \
    -framework AppKit -framework SwiftUI -framework ScreenSaver \
    Sources/Shared/*.swift Sources/Saver/*.swift
xattr -cr "$SAVER"
codesign --force --sign - "$SAVER" >/dev/null
echo "built $SAVER"

# Menu bar app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/App-Info.plist "$APP/Contents/Info.plist"
cp Resources/logo-mask.png "$APP/Contents/Resources/"
compile "$APP/Contents/MacOS/Helm" -module-name Helm -lsqlite3 \
    -framework AppKit -framework SwiftUI -framework EventKit -framework OSAKit \
    Sources/Shared/*.swift Sources/App/*.swift
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$APP/Contents/MacOS/Helm" --write-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$IDENTITY" "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "built $APP (signed: $IDENTITY)"

# Preview tool
compile build/helm-render -module-name HelmRender -framework AppKit -framework SwiftUI \
    Sources/Shared/*.swift Sources/Tool/main.swift
echo "built build/helm-render"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/Helm.saver"
    cp -R "$SAVER" "$DEST/"
    killall legacyScreenSaver 2>/dev/null || true  # pick up the new build
    echo "installed $DEST/Helm.saver"

    # Retire the old standalone sync helper (Helm.app does its job now).
    OLD=com.jonathanvineet.helm.sync
    launchctl bootout "gui/$(id -u)/$OLD" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$OLD.plist"
    rm -rf "$HOME/Applications/Helm Sync.app"

    APPS="$HOME/Applications"
    LABEL=com.jonathanvineet.helm
    mkdir -p "$APPS" "$HOME/Library/LaunchAgents"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -rf "$APPS/Helm.app"
    cp -R "$APP" "$APPS/"
    AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
    cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$APPS/Helm.app/Contents/MacOS/Helm</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/Helm.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/Helm.log</string>
</dict>
</plist>
PLIST
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "installed $APPS/Helm.app (in the menu bar, opens at login)"
fi
