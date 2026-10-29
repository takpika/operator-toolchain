# Shared by the small C tools' build scripts (make, toybox, pkgconf): sourced with PLATFORM, IOS_SYSTEM and WORK set.
SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
case "$PLATFORM" in
    iphoneos) TARGET=arm64-apple-ios17.0; SLICE=ios-arm64;;
    iphonesimulator) TARGET=arm64-apple-ios17.0-simulator; SLICE=ios-arm64_x86_64-simulator;;
esac
CC=$(xcrun -f clang)
COMMAND=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$WORK/include"
IOS_ERROR_SHA=51d46b912eb30399cbb5c36c8c8f15eb1a44adcfc9ee581304ac9d3739a84716

fetch() { # url sha file folder: downloads (once), checks and unpacks into WORK/folder
    [ -f "$WORK/$3" ] || curl -fsSL "$1" -o "$WORK/$3"
    echo "$2  $WORK/$3" | shasum -a 256 -c - > /dev/null
    if [ -n "${4:-}" ]; then
        rm -rf "$WORK/$4"; mkdir -p "$WORK/$4"
        tar -xzf "$WORK/$3" -C "$WORK/$4" --strip-components=1
    fi
}
fetch "https://github.com/holzschu/ios_system/releases/download/v3.0.6/ios_error.h" $IOS_ERROR_SHA include/ios_error.h

compile() { # source object [flags...]: one C file, with the command prefix
    local source=$1 object=$2; shift 2
    "$CC" -target "$TARGET" -isysroot "$SDK" -Os -ffunction-sections -fdata-sections -fvisibility=hidden \
        -ffile-prefix-map="$WORK"=. -ffile-prefix-map="${WORK#/private}"=. -Wno-everything \
        -I"$WORK/include" -I"$COMMAND/include" -include "$COMMAND/prefix.h" "$@" -c "$source" -o "$object"
}

framework() { # name entry version license objects...: links NAME.framework exporting only the entry point
    local name=$1 entry=$2 version=$3 license=$4; shift 4
    local fw="$WORK/out/$PLATFORM/$name.framework"
    "$(xcrun -f clang)" -target "$TARGET" -isysroot "$SDK" -Os -fvisibility=hidden -ffile-prefix-map="$COMMAND"=. \
        -c "$COMMAND/command.c" -o "$WORK/command-$PLATFORM.o"
    rm -rf "$fw"; mkdir -p "$fw"
    "$CC" -target "$TARGET" -isysroot "$SDK" -dynamiclib -install_name "@rpath/$name.framework/$name" -Wl,-dead_strip \
        -Wl,-exported_symbol,"_$entry" -F"$IOS_SYSTEM/$SLICE" -framework ios_system -o "$fw/$name" \
        "$WORK/command-$PLATFORM.o" "$@" ${LINK_LIBRARIES:-}
    xcrun strip -x "$fw/$name"
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>org.operator.$name</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$( [ "$PLATFORM" = iphoneos ] && echo iPhoneOS || echo iPhoneSimulator )</string></array>
<key>MinimumOSVersion</key><string>17.0</string>
</dict></plist>
PLIST
    cp "$license" "$fw/LICENSE"
    echo "$fw: $(du -sh "$fw/$name" | cut -f1)"
}
