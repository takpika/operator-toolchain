#!/bin/bash
# Links the built LLVM libraries and entry.cpp into llvm.framework for one platform.
# Usage: framework.sh SRC BUILD iphoneos|iphonesimulator IOS_SYSTEM_XCFRAMEWORK OUT_DIR
set -euo pipefail
SRC=$1; BUILD=$2; PLATFORM=$3; IOS_SYSTEM=$4; OUT=$5
HERE=$(cd "$(dirname "$0")" && pwd)
SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
case "$PLATFORM" in
    iphoneos) TARGET=arm64-apple-ios17.0; SLICE=ios-arm64;;
    iphonesimulator) TARGET=arm64-apple-ios17.0-simulator; SLICE=ios-arm64_x86_64-simulator;;
esac
CXX=$(xcrun -f clang++)
# Matches data.sh: the folder clang-setup unpacks into.
DATA_ID=$(cat "$HERE/data-id")
MAJOR=$(sed -n 's/^#define CLANG_VERSION_MAJOR \([0-9]*\)/\1/p' "$BUILD/tools/clang/include/clang/Basic/Version.inc")
# Libraries the clang, lld and llvm-ar executables link, in their order.
libraries() {
    grep -A3 "^build $1:" "$BUILD/build.ninja" | sed -n 's/^ *LINK_LIBRARIES = //p' | tr ' ' '\n' | grep -E '\.a$' | sed "s|^|$BUILD/|"
}
LIBS=$( { libraries "bin/clang-$MAJOR"; libraries bin/lld; libraries bin/llvm-ar; libraries bin/llvm-nm; } \
    | grep -v "lldCOFF\|lldELF\|lldMachO\|lldMinGW" | awk '!seen[$0]++')
DRIVER="$BUILD/tools/clang/tools/driver/CMakeFiles/clang.dir"
WORK="$OUT/work-$PLATFORM"
mkdir -p "$WORK"
"$CXX" -target "$TARGET" -isysroot "$SDK" -Os -std=c++17 -fvisibility=hidden -ffile-prefix-map="$SRC"=. -ffile-prefix-map="$HERE"=. -DCLANG_MAJOR="\"$MAJOR\"" -DCLANG_DATA_ID="\"$DATA_ID\"" \
    -I"$SRC/llvm/include" -I"$BUILD/include" -I"$SRC/lld/include" -c "$HERE/entry.cpp" -o "$WORK/entry.o"
FW="$OUT/$PLATFORM/llvm.framework"
rm -rf "$FW"; mkdir -p "$FW"
# Archives twice, so the order between them does not matter.
"$CXX" -target "$TARGET" -isysroot "$SDK" -dynamiclib -install_name @rpath/llvm.framework/llvm \
    -Wl,-dead_strip -Wl,-exported_symbols_list,"$HERE/exports.txt" -F"$IOS_SYSTEM/$SLICE" -framework ios_system \
    -o "$FW/llvm" "$WORK/entry.o" "$DRIVER/driver.cpp.o" "$DRIVER/cc1_main.cpp.o" "$DRIVER/cc1as_main.cpp.o" \
    "$DRIVER/cc1gen_reproducer_main.cpp.o" "$BUILD/tools/llvm-ar/CMakeFiles/llvm-ar.dir/llvm-ar.cpp.o" \
    "$BUILD/tools/llvm-nm/CMakeFiles/llvm-nm.dir/llvm-nm.cpp.o" $LIBS $LIBS
xcrun strip -x "$FW/llvm"
cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>llvm</string>
<key>CFBundleIdentifier</key><string>org.operator.llvm</string>
<key>CFBundleName</key><string>llvm</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$MAJOR</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$( [ "$PLATFORM" = iphoneos ] && echo iPhoneOS || echo iPhoneSimulator )</string></array>
<key>MinimumOSVersion</key><string>17.0</string>
<key>OperatorClangDataID</key><string>$DATA_ID</string>
</dict></plist>
PLIST
cp "$SRC/llvm/LICENSE.TXT" "$FW/LICENSE"
echo "$FW: $(du -sh "$FW/llvm" | cut -f1)"
