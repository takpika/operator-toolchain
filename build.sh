#!/bin/bash
# Builds the release assets into dist/: llvm.xcframework.zip, git.xcframework.zip and clang-data.lzma, plus
# SHA256SUMS. Needs Xcode, cmake, ninja and git; takes about 20 minutes and 15GB on a recent Mac.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HERE/work}
DIST=$HERE/dist
LLVM_TAG=llvmorg-23.1.4
LLVM_COMMIT=7a941dfb2877a0b8cf30323fefa85ad019e0b0f5
IOS_SYSTEM=v3.0.6
IOS_SYSTEM_SHA=c9c6dc4cde45cc271ccc8bd0553ce4d3149eced1f0ee3d9e0ce01885d93526e6
mkdir -p "$WORK"
rm -rf "$DIST"; mkdir -p "$DIST"

# ios_system (linked against, not shipped).
if [ ! -d "$WORK/ios_system.xcframework" ]; then
    curl -fsSL "https://github.com/holzschu/ios_system/releases/download/$IOS_SYSTEM/ios_system.xcframework.zip" -o "$WORK/ios_system.zip"
    echo "$IOS_SYSTEM_SHA  $WORK/ios_system.zip" | shasum -a 256 -c -
    unzip -q -o "$WORK/ios_system.zip" -d "$WORK"
fi
IOS_SYSTEM_FW="$WORK/ios_system.xcframework"

# LLVM: clang, lld and the libc/runtimes headers its build reads.
SRC="$WORK/llvm-project"
if [ ! -d "$SRC" ]; then
    git clone -q --depth 1 --branch "$LLVM_TAG" --filter=blob:none --sparse https://github.com/llvm/llvm-project.git "$SRC"
    git -C "$SRC" sparse-checkout set llvm clang lld cmake third-party libunwind/include libc runtimes
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$LLVM_COMMIT" ] || { echo "error: $LLVM_TAG is not $LLVM_COMMIT"; exit 1; }
python3 -I "$HERE/llvm/patch.py" "$SRC"
for PLATFORM in iphoneos iphonesimulator; do
    BUILD="$WORK/build-$PLATFORM"
    [ -f "$BUILD/build.ninja" ] || "$HERE/llvm/configure.sh" "$SRC" "$BUILD" "$PLATFORM" "$IOS_SYSTEM_FW" > "$WORK/configure-$PLATFORM.log"
    ninja -C "$BUILD" clang lld llvm-ar llvm-nm > "$WORK/ninja-$PLATFORM.log"
    "$HERE/llvm/framework.sh" "$SRC" "$BUILD" "$PLATFORM" "$IOS_SYSTEM_FW" "$WORK/out"
    "$HERE/git/build.sh" "$PLATFORM" "$IOS_SYSTEM_FW" "$WORK/out"
done
"$HERE/llvm/data.sh" "$WORK/build-iphoneos" "$WORK/out"

for NAME in llvm git; do
    rm -rf "$WORK/out/$NAME.xcframework"
    xcodebuild -create-xcframework -framework "$WORK/out/iphoneos/$NAME.framework" \
        -framework "$WORK/out/iphonesimulator/$NAME.framework" -output "$WORK/out/$NAME.xcframework" > /dev/null
    (cd "$WORK/out" && ditto -c -k --keepParent "$NAME.xcframework" "$DIST/$NAME.xcframework.zip")
done
SDKROOT=$(xcrun --sdk macosx --show-sdk-path) xcrun --sdk macosx swift -module-cache-path "$WORK/ModuleCache" \
    "$HERE/llvm/compress.swift" "$WORK/out/clang-data.tar" "$DIST/clang-data.lzma"
(cd "$DIST" && shasum -a 256 *.zip *.lzma > SHA256SUMS && cat SHA256SUMS)
