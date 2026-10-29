#!/bin/bash
# libcomponent-ld.a for one platform: wasm-component-ld (pinned release) patched to run in-process, as a static
# library that llvm.framework links. Usage: build.sh iphoneos|iphonesimulator WORK
set -euo pipefail
PLATFORM=$1; WORK=$2
HERE=$(cd "$(dirname "$0")" && pwd)
VERSION=0.5.31
SHA=0ff2469fe15d674a1430d1b851f899c5511bc57f917fd7a5949d8c73f417b7b4
SRC="$WORK/wasm-component-ld"
if [ ! -f "$SRC/.operator-$VERSION" ]; then
    curl -fsSL "https://codeload.github.com/bytecodealliance/wasm-component-ld/tar.gz/refs/tags/v$VERSION" -o "$WORK/wasm-component-ld.tar.gz"
    echo "$SHA  $WORK/wasm-component-ld.tar.gz" | shasum -a 256 -c - > /dev/null
    rm -rf "$SRC"; mkdir -p "$SRC"
    tar -xzf "$WORK/wasm-component-ld.tar.gz" -C "$SRC" --strip-components=1
    python3 -I "$HERE/patch.py" "$SRC"
    touch "$SRC/.operator-$VERSION"
fi
case "$PLATFORM" in
    iphoneos) TARGET=aarch64-apple-ios;;
    iphonesimulator) TARGET=aarch64-apple-ios-sim;;
esac
# Source paths in panic messages without the build machine's folders.
REMAP="--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo --remap-path-prefix=$(rustc --print sysroot)=/rustc --remap-path-prefix=$WORK=/work --remap-path-prefix=$HERE=/component"
RUSTFLAGS="$REMAP" IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --manifest-path "$HERE/Cargo.toml" --release --locked --target "$TARGET" \
    --target-dir "$WORK/component-target" -q
mkdir -p "$WORK/out/$PLATFORM"
cp "$WORK/component-target/$TARGET/release/liboperator_component_ld.a" "$WORK/out/$PLATFORM/libcomponent-ld.a"
