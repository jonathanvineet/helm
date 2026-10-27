#!/bin/zsh
# Builds a self-contained tesseract for release OCR helpers: libpng, Leptonica
# and Tesseract linked statically, targeting macOS 14.0. Homebrew's bottles
# target whatever macOS built them, which can be newer than Helm supports.
# Only PNG input is enabled, since pytesseract hands Tesseract PNGs.
# Usage: api/build_tesseract.sh <prefix>
#   then TESSERACT_CMD=<prefix>/bin/tesseract TESSDATA_PREFIX=<prefix>/share/tessdata
set -euo pipefail

PREFIX=${1:?usage: api/build_tesseract.sh <prefix>}
mkdir -p "$PREFIX"
PREFIX=${PREFIX:A}
WORK=$PREFIX.work
rm -rf "$WORK"
mkdir -p "$WORK"

export MACOSX_DEPLOYMENT_TARGET=14.0
CMAKE=(cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX"
       -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET
       -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DBUILD_SHARED_LIBS=OFF)

fetch() {  # url sha256 file
    curl -sSfL -o "$WORK/$3" "$1"
    echo "$2  $WORK/$3" | shasum -a 256 -c --quiet
}
build() {  # name archive cmake-options...
    local name=$1 archive=$2; shift 2
    mkdir -p "$WORK/$name"
    tar -xzf "$WORK/$archive" -C "$WORK/$name" --strip-components 1
    "${CMAKE[@]}" -S "$WORK/$name" -B "$WORK/$name/build" "$@" >/dev/null
    cmake --build "$WORK/$name/build" --parallel "$(sysctl -n hw.ncpu)" >/dev/null
    cmake --install "$WORK/$name/build" >/dev/null
    mkdir -p "$PREFIX/share/licenses/$name"
    cp "$WORK/$name"/(LICENSE|COPYING|leptonica-license.txt|AUTHORS)(N) "$PREFIX/share/licenses/$name/"
    echo "built $name"
}

fetch https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.58.tar.gz \
    a9d4df463d36a6e5f9c29bd6f4967312d17e996c1854f3511f833924eb1993cf libpng.tgz
fetch https://github.com/DanBloomberg/leptonica/releases/download/1.87.0/leptonica-1.87.0.tar.gz \
    c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7 leptonica.tgz
fetch https://github.com/tesseract-ocr/tesseract/archive/refs/tags/5.5.2.tar.gz \
    6235ea0dae45ea137f59c09320406f5888383741924d98855bd2ce0d16b54f21 tesseract.tgz
fetch https://github.com/tesseract-ocr/tessdata_fast/raw/4.1.0/eng.traineddata \
    7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2 eng.traineddata

build libpng libpng.tgz -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
build leptonica leptonica.tgz -DSW_BUILD=OFF -DBUILD_PROG=OFF -DENABLE_PNG=ON -DENABLE_ZLIB=ON \
    -DENABLE_JPEG=OFF -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF -DENABLE_OPENJPEG=OFF -DENABLE_GIF=OFF
build tesseract tesseract.tgz -DSW_BUILD=OFF -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF \
    -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON -DGRAPHICS_DISABLED=ON -DOPENMP_BUILD=OFF

mkdir -p "$PREFIX/share/tessdata"
cp "$WORK/eng.traineddata" "$PREFIX/share/tessdata/"
rm -rf "$WORK"
otool -L "$PREFIX/bin/tesseract"
