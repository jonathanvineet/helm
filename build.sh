#!/bin/zsh
# Builds build/Helm.saver (the screensaver) and build/helm-render (frame preview tool).
# Usage: ./build.sh [--install]
#   PHOTOS=/path/to/folder ./build.sh   bundles a different photo folder
set -euo pipefail
cd "$(dirname "$0")"

TARGET="$(uname -m)-apple-macos14.0"
PHOTOS="${PHOTOS:-$HOME/Downloads/wallpaper}"
SAVER=build/Helm.saver

rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"
cp Resources/Saver-Info.plist "$SAVER/Contents/Info.plist"

swiftc -O -swift-version 5 -target "$TARGET" -module-name HelmSaver -emit-library \
    -framework AppKit -framework SwiftUI -framework ScreenSaver -framework IOKit \
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

swiftc -O -swift-version 5 -target "$TARGET" -module-name HelmRender \
    -framework AppKit -framework SwiftUI -framework IOKit \
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
fi
