#!/bin/bash
# sh.framework: mvdan.cc/sh (BSD-3-Clause), a POSIX and bash interpreter written as a Go library, as `sh` and `bash`.
# Its state lives in each interpreter rather than in globals, so any number run at once (dash needs a copy of its
# framework for each, and ios_system takes six). Module versions are pinned by go.sum. Needs Go 1.24 or later.
# Usage: build.sh iphoneos|iphonesimulator IOS_SYSTEM_XCFRAMEWORK WORK
set -euo pipefail
PLATFORM=$1; IOS_SYSTEM=$2; WORK=$3
HERE=$(cd "$(dirname "$0")" && pwd)
# The framework's version: mvdan.cc/sh's.
VERSION=3.12.0
. "$HERE/../command/common.sh"
export GOPATH="$WORK/go" GOMODCACHE="$WORK/go/mod" GOFLAGS="-modcacherw -trimpath" GOTOOLCHAIN=local GOTELEMETRY=off
OBJ="$WORK/obj-sh-$PLATFORM"
rm -rf "$OBJ"; mkdir -p "$OBJ"
(cd "$HERE" && go mod verify > /dev/null && GOOS=ios GOARCH=arm64 CGO_ENABLED=1 CC="$CC -target $TARGET -isysroot $SDK" \
    CGO_CFLAGS="-Os -fvisibility=hidden" CGO_LDFLAGS="-target $TARGET -isysroot $SDK" \
    go build -buildmode=c-archive -ldflags="-s -w" -o "$OBJ/sh.a" .)
# The license from the module go.sum checked.
LINK_LIBRARIES="-Wl,-force_load,$OBJ/sh.a -framework CoreFoundation -lresolv" \
    framework sh operator_sh_main "$VERSION" "$GOMODCACHE/mvdan.cc/sh/v3@v$VERSION/LICENSE"
