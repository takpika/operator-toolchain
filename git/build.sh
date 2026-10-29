#!/bin/bash
# git.framework: libgit2 (upstream release) with a-Shell's lg2 commands (holzschu/libgit2 examples, CC0) as `git`.
# HTTPS through Apple's Security framework; no SSH. Usage: build.sh iphoneos|iphonesimulator IOS_SYSTEM_XCFRAMEWORK OUT
set -euo pipefail
PLATFORM=$1; IOS_SYSTEM=$2; OUT=$3
HERE=$(cd "$(dirname "$0")" && pwd)
LIBGIT2=1.9.7
LIBGIT2_SHA=1a4fbe7589e814777ae76b64734ad80f4ecad22cd33a22682a2aaea4ae5375e7
LG2=9287439f4cfea698f17f1b2dee7f86639b33e0d0
LG2_SHA=a9c13c7ab36268ddc707cee98ce6e46e0d246593a4f659631870d2da84c6def4
# lg2 includes ios_system's porting header (stdout, exit and the terminal go through the running command).
IOS_ERROR_SHA=51d46b912eb30399cbb5c36c8c8f15eb1a44adcfc9ee581304ac9d3739a84716
SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
case "$PLATFORM" in
    iphoneos) TARGET=arm64-apple-ios17.0; SLICE=ios-arm64;;
    iphonesimulator) TARGET=arm64-apple-ios17.0-simulator; SLICE=ios-arm64_x86_64-simulator;;
esac
CC=$(xcrun -f clang)
WORK="$OUT/git-work"
mkdir -p "$WORK"
# Source paths in the binary (libgit2 reports __FILE__) without the build machine's folders.
# (/tmp and /private/tmp are the same folder on macOS; tools may report either.)
MAP="-ffile-prefix-map=$WORK=. -ffile-prefix-map=${WORK#/private}=. -ffile-prefix-map=$(cd "$WORK" && pwd -P)=."
fetch() { # url sha name
    [ -f "$WORK/$3" ] || curl -fsSL "$1" -o "$WORK/$3"
    echo "$2  $WORK/$3" | shasum -a 256 -c - >/dev/null
}
fetch "https://github.com/libgit2/libgit2/archive/refs/tags/v$LIBGIT2.tar.gz" $LIBGIT2_SHA libgit2.tar.gz
fetch "https://codeload.github.com/holzschu/libgit2/tar.gz/$LG2" $LG2_SHA lg2.tar.gz
mkdir -p "$WORK/include"
fetch "https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_error.h" $IOS_ERROR_SHA include/ios_error.h
rm -rf "$WORK/libgit2" "$WORK/lg2"; mkdir -p "$WORK/libgit2" "$WORK/lg2"
tar -xzf "$WORK/libgit2.tar.gz" -C "$WORK/libgit2" --strip-components=1
tar -xzf "$WORK/lg2.tar.gz" -C "$WORK/lg2" --strip-components=1 "libgit2-$LG2/examples"
/usr/bin/python3 -I "$HERE/patch.py" "$WORK/lg2/examples"
BUILD="$WORK/build-$PLATFORM"
rm -rf "$BUILD"
cmake -G Ninja -S "$WORK/libgit2" -B "$BUILD" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections $MAP" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF \
    -DUSE_SSH=OFF -DUSE_HTTPS=SecureTransport -DUSE_SHA1=CollisionDetection -DUSE_SHA256=CommonCrypto \
    -DREGEX_BACKEND=builtin -DUSE_HTTP_PARSER=builtin -DUSE_BUNDLED_ZLIB=OFF > "$WORK/cmake-$PLATFORM.log"
ninja -C "$BUILD" libgit2package > "$WORK/ninja-$PLATFORM.log"
OBJ="$WORK/obj-$PLATFORM"
rm -rf "$OBJ"; mkdir -p "$OBJ"
for source in "$WORK/lg2/examples"/*.c; do
    "$CC" -target "$TARGET" -isysroot "$SDK" -Os -ffunction-sections -fdata-sections -fvisibility=hidden $MAP \
        -Wno-everything -Dmain=lg2_main -I"$WORK/include" -I"$WORK/libgit2/include" -I"$(dirname "$(find "$BUILD" -name git2_features.h | head -1)")" \
        -I"$IOS_SYSTEM/$SLICE/ios_system.framework/Headers" -c "$source" -o "$OBJ/$(basename "$source" .c).o"
done
"$CC" -target "$TARGET" -isysroot "$SDK" -Os -fvisibility=hidden -c "$HERE/entry.c" -o "$OBJ/entry.o"
FW="$OUT/$PLATFORM/git.framework"
rm -rf "$FW"; mkdir -p "$FW"
"$CC" -target "$TARGET" -isysroot "$SDK" -dynamiclib -install_name @rpath/git.framework/git -Wl,-dead_strip \
    -Wl,-exported_symbol,_operator_git_main -F"$IOS_SYSTEM/$SLICE" -framework ios_system -framework Security \
    -framework CoreFoundation -lz -liconv -o "$FW/git" "$OBJ"/*.o "$BUILD/libgit2.a"
xcrun strip -x "$FW/git"
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>git</string>
<key>CFBundleIdentifier</key><string>org.operator.git</string>
<key>CFBundleName</key><string>git</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$LIBGIT2</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$( [ "$PLATFORM" = iphoneos ] && echo iPhoneOS || echo iPhoneSimulator )</string></array>
<key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
PLIST
cp "$WORK/libgit2/COPYING" "$FW/LICENSE"
echo "$FW: $(du -sh "$FW/git" | cut -f1)"
