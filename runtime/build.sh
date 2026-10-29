#!/bin/bash
# component-runtime.lzma: what the app's web view needs to run WASI 0.2/0.3 components, from Bytecode Alliance's jco
# (pinned npm releases): js-component-bindgen (turns a component into core modules plus JS) and the browser builds of
# the WASI 0.2 and 0.3 shims, with package imports rewritten to relative paths. Usage: build.sh WORK DIST
set -euo pipefail
WORK=$1; DIST=$2
HERE=$(cd "$(dirname "$0")" && pwd)
PACKAGES="jco-transpile:0.21.0:c7ac8f3179da110021d56e674c7c6801136b100064696cb6730e37258c4ddf6f
preview2-shim:0.31.0:7e02ee15d5c36549ead5262e1d4178085701eb62983e1bbe22ba273007c096bd
preview3-shim:0.12.0:56e9192bbee5972d2856556f3b062250cc4b572f87c82acde3ad981691053684"
OUT="$WORK/runtime"
rm -rf "$OUT"; mkdir -p "$OUT/download"
for entry in $PACKAGES; do
    IFS=: read -r name version sha <<< "$entry"
    file="$OUT/download/$name-$version.tgz"
    curl -fsSL "https://registry.npmjs.org/@bytecodealliance/$name/-/$name-$version.tgz" -o "$file"
    echo "$sha  $file" | shasum -a 256 -c - > /dev/null
    mkdir -p "$OUT/download/$name"
    tar -xzf "$file" -C "$OUT/download/$name" --strip-components=1
done
ROOT="$OUT/root"
mkdir -p "$ROOT/bindgen" "$ROOT/p2/dist" "$ROOT/p3/dist"
cp "$OUT/download/jco-transpile/vendor/js-component-bindgen-component".{js,core.wasm,core2.wasm} "$ROOT/bindgen/"
cp "$OUT/download/jco-transpile/LICENSE" "$ROOT/bindgen/LICENSE"
cp -R "$OUT/download/preview2-shim/dist/browser" "$OUT/download/preview2-shim/dist/common" "$ROOT/p2/dist/"
[ -d "$OUT/download/preview2-shim/dist/io" ] && cp -R "$OUT/download/preview2-shim/dist/io" "$ROOT/p2/dist/"
cp "$OUT/download/preview2-shim/LICENSE" "$ROOT/p2/LICENSE"
cp -R "$OUT/download/preview3-shim/dist/browser" "$ROOT/p3/dist/"
cp "$OUT/download/preview3-shim/LICENSE" "$ROOT/p3/LICENSE"
find "$ROOT" -name "*.d.ts" -delete -o -name "*.map" -delete
python3 -I "$HERE/relink.py" "$ROOT"
cp "$HERE/runtime-id" "$ROOT/VERSION"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname wheel \
    -cf "$OUT/component-runtime.tar" -C "$ROOT" .
SDKROOT=$(xcrun --sdk macosx --show-sdk-path) xcrun --sdk macosx swift -module-cache-path "$WORK/ModuleCache" \
    "$HERE/../llvm/compress.swift" "$OUT/component-runtime.tar" "$DIST/component-runtime.lzma"
du -sh "$ROOT" "$DIST/component-runtime.lzma"
