#!/bin/bash
# The data clang needs, unpacked into the user's folder by clang-setup: the wasm32-wasip3 sysroot (wasi-libc,
# libc++ with and without exceptions) and clang's own headers and builtins. Output: OUT/clang-data.tar
# Usage: data.sh BUILD OUT
set -euo pipefail
BUILD=$1; OUT=$2
WASI_SDK=34
SYSROOT_SHA=9d813544eeebe38b7b8f2244ed591de46b6db812c6dd1a257ff9f0d2a905a2be
BUILTINS_SHA=eee3e634dcf71aa22b1333391623cf5c9965a637dc428a27b1a858c026c587f1
MAJOR=$(sed -n 's/^#define CLANG_VERSION_MAJOR \([0-9]*\)/\1/p' "$BUILD/tools/clang/include/clang/Basic/Version.inc")
WORK="$OUT/data-work"
rm -rf "$WORK"; mkdir -p "$WORK/download"
BASE="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-$WASI_SDK"
for pair in "wasi-sysroot-$WASI_SDK.0.tar.gz:$SYSROOT_SHA" "libclang_rt-$WASI_SDK.0.tar.gz:$BUILTINS_SHA"; do
    name=${pair%%:*}
    curl -fsSL "$BASE/$name" -o "$WORK/download/$name"
    echo "${pair##*:}  $WORK/download/$name" | shasum -a 256 -c -
    tar -xzf "$WORK/download/$name" -C "$WORK/download"
done
ROOT="$WORK/root"
SYSROOT="$ROOT/wasi-sysroot"
mkdir -p "$SYSROOT/include" "$SYSROOT/lib" "$SYSROOT/share"
FROM="$WORK/download/wasi-sysroot-$WASI_SDK.0"
cp -R "$FROM/include/wasm32-wasip3" "$SYSROOT/include/"
# Empty, but clang reads the libc++ version (v1) from it before using the per-target headers.
mkdir -p "$SYSROOT/include/c++/v1"
cp -R "$FROM/lib/wasm32-wasip3" "$SYSROOT/lib/"
cp -R "$FROM/share/wasm32-wasip3" "$SYSROOT/share/" 2>/dev/null || true
# Static linking only; LTO libraries are only for -flto.
find "$SYSROOT/lib" -name "*.so" -delete
rm -rf "$SYSROOT/lib/wasm32-wasip3/llvm-lto" "$SYSROOT/lib/wasm32-wasip3"/*/llvm-lto
RESOURCE="$ROOT/lib/clang/$MAJOR"
mkdir -p "$RESOURCE/lib/wasm32-unknown-wasip3"
cp -R "$BUILD/lib/clang/$MAJOR/include" "$RESOURCE/"
# Intrinsics and wrappers for other CPUs and GPUs.
( cd "$RESOURCE/include" && rm -rf cuda_wrappers openmp_wrappers ppc_wrappers llvm_libc_wrappers zos_wrappers \
    hlsl hlsl*.h *intrin*.h arm_*.h avx*.h amx*.h riscv_*.h sifive_*.h hexagon_*.h hvx_*.h __clang_cuda_*.h \
    __clang_hip_*.h cuda*.h opencl-c*.h htm*.h altivec.h s390intrin.h vecintrin.h velintrin*.h lasx*.h lsx*.h \
    larchintrin.h msa.h mmintrin.h xmmintrin.h emmintrin.h pmmintrin.h tmmintrin.h smmintrin.h nmmintrin.h \
    wmmintrin.h ammintrin.h mm3dnow.h mm_malloc.h cpuid.h gfni*.h sha*.h vaes*.h vpclmul*.h prfchw*.h \
    __wmmintrin_*.h 2>/dev/null || true )
cp "$WORK/download/libclang_rt-$WASI_SDK.0/wasm32-unknown-wasip3/libclang_rt.builtins.a" \
    "$RESOURCE/lib/wasm32-unknown-wasip3/"
cp "$(dirname "$0")/data-id" "$ROOT/VERSION"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 --uname root --gname wheel -cf "$OUT/clang-data.tar" -C "$ROOT" .
du -sh "$ROOT" "$OUT/clang-data.tar"
