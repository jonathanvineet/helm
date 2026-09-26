#!/bin/zsh
# Builds:
#   build/Helm.saver      the screensaver (slideshow + notes/reminders board)
#   build/Helm Sync.app   helper that exports Notes' Helm folder + Reminders for it
#   build/helm-render     draws one frame to a PNG, for checking layout
# Usage: ./build.sh [--install]
#   PHOTOS=/path/to/folder ./build.sh   bundles a different photo folder
set -euo pipefail
cd "$(dirname "$0")"

TARGET="$(uname -m)-apple-macos14.0"
FLAGS=(-O -swift-version 5 -target "$TARGET")
PHOTOS="${PHOTOS:-$HOME/Downloads/wallpaper}"
SAVER=build/Helm.saver
SYNC="build/Helm Sync.app"

# Screensaver
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp Resources/Saver-Info.plist "$SAVER/Contents/Info.plist"
swiftc "${FLAGS[@]}" -module-name HelmSaver -emit-library \
    -framework AppKit -framework SwiftUI -framework ScreenSaver \
    Sources/Shared/*.swift Sources/Saver/*.swift -o "$SAVER/Contents/MacOS/Helm"
# The screensaver sandbox may not be allowed to read the photo folder, so ship a copy.
if [[ -d "$PHOTOS" ]]; then
    mkdir -p "$SAVER/Contents/Resources/Photos"
    find "$PHOTOS" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) \
        -exec cp {} "$SAVER/Contents/Resources/Photos/" \;
fi
xattr -cr "$SAVER"
codesign --force --sign - "$SAVER" >/dev/null
echo "built $SAVER"

# Sync helper
rm -rf "$SYNC"
mkdir -p "$SYNC/Contents/MacOS"
cp Resources/Sync-Info.plist "$SYNC/Contents/Info.plist"
swiftc "${FLAGS[@]}" -module-name HelmSync -framework EventKit -framework OSAKit \
    Sources/Shared/BoardModel.swift Sources/Sync/main.swift -o "$SYNC/Contents/MacOS/HelmSync"
codesign --force --sign - "$SYNC" >/dev/null
echo "built $SYNC"

# Preview tool
swiftc "${FLAGS[@]}" -module-name HelmRender -framework AppKit -framework SwiftUI \
    Sources/Shared/*.swift Sources/Tool/main.swift -o build/helm-render
echo "built build/helm-render"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Library/Screen Savers"
    mkdir -p "$DEST"
    rm -rf "$DEST/Helm.saver"
    cp -R "$SAVER" "$DEST/"
    # Make the screensaver host pick up the new build.
    killall legacyScreenSaver 2>/dev/null || true
    echo "installed $DEST/Helm.saver"

    # macOS ties Notes/Reminders permission to the exact binary of an ad-hoc
    # signed app, so only replace the helper when it actually changed.
    APPS="$HOME/Applications"
    mkdir -p "$APPS"
    if ! cmp -s "$SYNC/Contents/MacOS/HelmSync" "$APPS/Helm Sync.app/Contents/MacOS/HelmSync"; then
        rm -rf "$APPS/Helm Sync.app"
        cp -R "$SYNC" "$APPS/"
        echo "installed $APPS/Helm Sync.app (changed: Notes/Reminders access may be asked for again)"
    fi

    LABEL=com.jonathanvineet.helm.sync
    AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    sed "s|__BIN__|$APPS/Helm Sync.app/Contents/MacOS/HelmSync|; s|__LOG__|$HOME/Library/Logs/HelmSync.log|" \
        Resources/sync-agent.plist > "$AGENT"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT"
    echo "Helm Sync running, syncing every 10s ($AGENT)"
fi
