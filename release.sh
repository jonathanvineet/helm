#!/bin/zsh
# Packages a release for Homebrew:
#   dist/Helm-<version>.zip   Helm.app + Helm.saver, universal, signed ad hoc
#   dist/helm.rb              the cask, pointing at the GitHub release
# Usage: ./release.sh 0.3.0
# Then upload the zip to a GitHub release tagged v<version> and copy helm.rb
# into the tap repo (jonathanvineet/homebrew-tap, Casks/helm.rb).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=${1:?usage: ./release.sh <version>}
REPO=jonathanvineet/helm

for plist in Resources/App-Info.plist Resources/Saver-Info.plist; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$plist"
done

ARCHS="arm64 x86_64" SIGN_IDENTITY=- ./build.sh

STAGE=dist/stage
ZIP=dist/Helm-$VERSION.zip
rm -rf dist
mkdir -p "$STAGE"
cp -R build/Helm.app build/Helm.saver "$STAGE/"
xattr -cr "$STAGE"
ditto -c -k --norsrc "$STAGE" "$ZIP"
rm -rf "$STAGE"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" -e "s|@REPO@|$REPO|" Packaging/helm.rb > dist/helm.rb

echo "built $ZIP ($SHA)"
echo "built dist/helm.rb"
