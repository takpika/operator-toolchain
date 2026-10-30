#!/bin/bash
# make.framework: kati (Apache-2.0), Google's GNU make clone, as `make`: GNU make syntax and functions, recipes and
# $(shell) run in sh (the app's shell). Usage: build.sh iphoneos|iphonesimulator IOS_SYSTEM_XCFRAMEWORK WORK
set -euo pipefail
PLATFORM=$1; IOS_SYSTEM=$2; WORK=$3
HERE=$(cd "$(dirname "$0")" && pwd)
COMMIT=7a3ee413e1cfc230a597ac33034d2f478351e432
SHA=3fb18dfc6a65a903cf7b680eed91b6d17e3cddf9267ebc7a9fb91c857356ee6b
# kati has no releases: the framework's version is the commit's date.
VERSION=2026.10.23
. "$HERE/../command/common.sh"
fetch "https://codeload.github.com/google/kati/tar.gz/$COMMIT" $SHA kati.tar.gz kati
python3 -I "$HERE/patch.py" "$WORK/kati"
printf '// +build ignore\n\nconst char* kGitVersion = "%s";\n' "$COMMIT" > "$WORK/kati/src/version.cc"
CXX=$(xcrun -f clang++)
OBJ="$WORK/obj-make-$PLATFORM"
rm -rf "$OBJ"; mkdir -p "$OBJ"
for source in "$WORK/kati/src"/*.cc; do
    case "$source" in *_test.cc|*_bench.cc|*/version_unknown.cc) continue;; esac
    name=$(basename "$source" .cc)
    flags=()
    [ "$name" = main ] && flags=(-Dmain=kati_main)
    "$CXX" -target "$TARGET" -isysroot "$SDK" -std=c++17 -Os -DNOLOG -ffunction-sections -fdata-sections \
        -fvisibility=hidden -ffile-prefix-map="$WORK"=. -ffile-prefix-map="${WORK#/private}"=. -Wno-everything \
        -I"$WORK/include" -I"$COMMAND/include" -include "$COMMAND/prefix.h" ${flags[@]+"${flags[@]}"} \
        -c "$source" -o "$OBJ/$name.o"
done
"$CXX" -target "$TARGET" -isysroot "$SDK" -std=c++17 -Os -fvisibility=hidden -c "$HERE/entry.cc" -o "$OBJ/entry.o"
CC="$CXX" LINK_LIBRARIES="-lc++" framework make operator_kati_main "$VERSION" "$WORK/kati/LICENSE" "$OBJ"/*.o
