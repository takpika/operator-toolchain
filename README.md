# Operator toolchain

Prebuilt developer tools for the Operator iOS app, built by the scripts in this
repository. The app embeds the frameworks and runs them as commands inside itself (through
[ios_system](https://github.com/holzschu/ios_system)); what they compile runs as WebAssembly (WASI) in the app.

| Release asset | What it is |
| --- | --- |
| `llvm.xcframework.zip` | clang/clang++, wasm-ld, ar/ranlib and nm from LLVM, WebAssembly target only, in one framework |
| `git.xcframework.zip` | `git`: [libgit2](https://github.com/libgit2/libgit2) with [a-Shell](https://github.com/holzschu/a-shell)'s lg2 commands, HTTPS via Apple's Security framework |
| `clang-data.lzma` | A tar (LZMA-compressed by Apple's Compression framework, as the app reads it) of what clang needs at run time, unpacked into the user's folder by the app's `clang-setup`: the [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) wasm32-wasip1 sysroot (wasi-libc, libc++ with and without exceptions) and clang's own headers and builtins |

## Building

```sh
./build.sh
```

Needs Xcode, cmake and ninja. It downloads pinned sources (checked by commit or SHA-256), builds for iOS devices and
the simulator, and writes the assets and `SHA256SUMS` to `dist/`.

## What is changed

- `llvm/patch.py` and `llvm/ios-prefix.h` let the tools run as threads of an app: `exit` and `abort` end only the
  command, output goes to the command's own streams, clang runs the linker in-process instead of starting a process,
  and LLVM installs no process-wide signal handlers and does not shut down its global state, so it can run again.
- `llvm/entry.cpp` is what the app calls. It points clang at the sysroot in the user's folder, enables WASI's
  emulated signal/mman/process-clocks/getpid, setjmp/longjmp, and C++ exceptions (standard WebAssembly exception
  instructions, as wasi-sdk's libraries use).
- `git/patch.py` makes plain `git branch` list branches and removes a debug line from `git status`.

## Licenses

Each framework carries its project's license: LLVM is Apache-2.0 with LLVM exceptions; libgit2 is GPL-2.0 with a
linking exception; the lg2 commands are CC0; wasi-sdk's sysroot is Apache-2.0 with LLVM exceptions (wasi-libc also
includes MIT-licensed musl). The scripts in this repository are MIT-licensed.
