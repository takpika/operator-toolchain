#!/bin/bash
# wasi-libc with the app's kernel behind it: the working directory, paths as written, exit codes, processes' identity,
# permissions (operator.patch; the interface is system.wit). Puts it in a wasi-sdk sysroot in place of wasi-sdk's own build.
# component-type.bin is system.wit encoded, by gen (`cd gen && cargo run -- <folder with system.wit> ../component-type.bin`).
# Usage: build.sh SYSROOT BUILTINS WORK   (LLVM_BIN: a clang of the same major version as wasi-sdk's)
set -euo pipefail
SYSROOT=$1; BUILTINS=$2; WORK=$3
HERE=$(cd "$(dirname "$0")" && pwd)
LLVM_BIN=${LLVM_BIN:-/opt/homebrew/opt/llvm/bin}
# The commit wasi-sdk-34's submodule points at.
COMMIT=2e6fb9d8ee0cdf9e431fbcabe8af3115de000a13
SHA=2b3e2dca9825487e35a5ed6867c3e226eb021d948c3288b5dbff112b7d362517
SOURCE="$WORK/wasi-libc"; BUILD="$WORK/wasi-libc-build"
rm -rf "$SOURCE" "$BUILD"; mkdir -p "$SOURCE" "$BUILD"
curl -fsSL "https://api.github.com/repos/WebAssembly/wasi-libc/tarball/$COMMIT" -o "$WORK/wasi-libc.tar.gz"
echo "$SHA  $WORK/wasi-libc.tar.gz" | shasum -a 256 -c -
tar -xzf "$WORK/wasi-libc.tar.gz" -C "$SOURCE" --strip-components=1
patch -d "$SOURCE" -p1 -s < "$HERE/operator.patch"
echo 'void __operator_system_force_link(void) {}' > "$WORK/stub.c"
"$LLVM_BIN/clang" --target=wasm32-wasip3 --sysroot="$SYSROOT" -O2 -fPIC -c "$WORK/stub.c" -o "$WORK/stub.o"
python3 -I "$HERE/component-type.py" "$WORK/stub.o" "$HERE/component-type.bin" "$SOURCE/libc-bottom-half/sources/operator_system_component_type.o"
cmake -G Ninja -S "$SOURCE" -B "$BUILD" -DCMAKE_C_COMPILER="$LLVM_BIN/clang" -DCMAKE_AR="$LLVM_BIN/llvm-ar" \
    -DCMAKE_NM="$LLVM_BIN/llvm-nm" -DCMAKE_RANLIB="$LLVM_BIN/llvm-ranlib" -DTARGET_TRIPLE=wasm32-wasip3 \
    -DBUILTINS_LIB="$BUILTINS" -DCMAKE_BUILD_TYPE=Release > /dev/null
ninja -C "$BUILD" > /dev/null
FROM="$BUILD/sysroot"
for file in libc.a libc.so crt1.o crt1-command.o crt1-reactor.o libwasi-emulated-getpid.a libwasi-emulated-getpid.so \
    libwasi-emulated-signal.a libwasi-emulated-signal.so libwasi-emulated-mman.a libwasi-emulated-mman.so; do
    cp "$FROM/lib/wasm32-wasip3/$file" "$SYSROOT/lib/wasm32-wasip3/"
done
# Headers for what this libc adds: permissions, processes, signals, temporary files.
cp -R "$FROM/include/wasm32-wasip3/" "$SYSROOT/include/wasm32-wasip3/"
