# Operator toolchain

Prebuilt developer tools for the Operator iOS app, built by the scripts in this
repository. The app embeds the frameworks and runs them as commands inside itself (through
[ios_system](https://github.com/holzschu/ios_system)); what they compile runs as WebAssembly (WASI) in the app.

| Release asset | What it is |
| --- | --- |
| `llvm.xcframework.zip` | clang/clang++, wasm-ld, ar/ranlib and nm from LLVM, WebAssembly target only, plus [wasm-component-ld](https://github.com/bytecodealliance/wasm-component-ld) (which turns linked programs into WASI 0.3 components), in one framework |
| `git.xcframework.zip` | `git`: [libgit2](https://github.com/libgit2/libgit2) with [a-Shell](https://github.com/holzschu/a-shell)'s lg2 commands, HTTPS via Apple's Security framework |
| `make.xcframework.zip` | `make`: [kati](https://github.com/google/kati), Google's GNU make clone (GNU Makefile syntax and functions); recipes and `$(shell)` run in the app's `sh` (dash) |
| `clang-data.lzma` | A tar (LZMA-compressed by Apple's Compression framework, as the app reads it) of what clang needs at run time, unpacked into the user's folder by the app's `clang-setup`: the [wasi-sdk](https://github.com/WebAssembly/wasi-sdk) wasm32-wasip3 sysroot (wasi-libc, libc++ with and without exceptions) and clang's own headers and builtins |
| `component-runtime.lzma` | A tar (compressed the same way) of what the app's web view needs to run WASI 0.2/0.3 components: [jco](https://github.com/bytecodealliance/jco)'s js-component-bindgen and its browser WASI 0.2 and 0.3 shims, with package imports rewritten to relative paths |

## Building

```sh
./build.sh
```

Needs Xcode, cmake, ninja and Rust (with the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets). It downloads pinned sources (checked by commit or SHA-256), builds for iOS devices and
the simulator, and writes the assets and `SHA256SUMS` to `dist/`.

## What is changed

- `llvm/patch.py` and `llvm/ios-prefix.h` let the tools run as threads of an app: `exit` and `abort` end only the
  command, output goes to the command's own streams, clang runs the linker in-process instead of starting a process,
  and LLVM installs no process-wide signal handlers and does not shut down its global state, so it can run again.
- `llvm/entry.cpp` is what the app calls. It makes clang build WASI 0.3 components (`wasm32-wasip3`), points it at the sysroot in the user's folder, enables WASI's
  emulated signal/mman/process-clocks/getpid, setjmp/longjmp, and C++ exceptions (standard WebAssembly exception
  instructions, as wasi-sdk's libraries use).
- `component/patch.py` lets wasm-component-ld run in-process: it gets its arguments from the caller, runs the
  framework's own wasm-ld instead of starting a process, and returns errors instead of exiting.
- `git/patch.py` makes plain `git branch` list branches and removes a debug line from `git status`; `git/entry.c`
  adds git's leading `-C <dir>`.
- `kati/patch.py` makes kati's globals thread-local (each run is a new thread, so it starts fresh), removes its
  SIGSEGV handler and runs its commands through `command/command.c`.
- `command/` is shared by tools that run shell commands: `prefix.h` sends their standard streams to the running
  command's and their `system`/`popen` to `command.c`, which runs each command in `dash -c` as an ios_system command
  and waits for it.

## Licenses

Each framework carries its project's license: LLVM and wasm-component-ld are Apache-2.0 with LLVM exceptions; jco and its shims are Apache-2.0 with LLVM exceptions; libgit2 is GPL-2.0 with a
linking exception; the lg2 commands are CC0; kati is Apache-2.0; wasi-sdk's sysroot is Apache-2.0 with LLVM exceptions (wasi-libc also
includes MIT-licensed musl). The scripts in this repository are MIT-licensed.
