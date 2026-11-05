//! wasm-component-ld for llvm.framework: clang links wasm32-wasip3 programs with it, in-process. Also the app's
//! dynamic linker: a program built against shared libraries is linked with them into a component when it starts.

use std::ffi::{CStr, OsString, c_char};
use std::fs::File;
use std::io::Write;
use std::mem::ManuallyDrop;
use std::os::fd::FromRawFd;
use std::os::unix::ffi::OsStringExt;

/// `wasm-component-ld` with these arguments; errors go to `errors` (a descriptor the caller keeps open).
#[unsafe(no_mangle)]
pub extern "C" fn operator_component_ld_main(argc: i32, argv: *const *const c_char, errors: i32) -> i32 {
    let arguments: Vec<OsString> = (0..argc as usize)
        .map(|i| OsString::from_vec(unsafe { CStr::from_ptr(*argv.add(i)) }.to_bytes().to_vec()))
        .collect();
    let mut stream = ManuallyDrop::new(unsafe { File::from_raw_fd(errors) });
    let code = wasm_component_ld::run_with(arguments, &mut *stream);
    let _ = stream.flush();
    code
}

/// Links `count` WebAssembly shared libraries (`dylink.0` modules: a program and every library it needs, by
/// `names[i]` as `dylink.0` names them, read from `paths[i]`) into one component at `output`, with wit-component's
/// shared-everything linker. A library with `dl_openable[i]` set can also be found by `dlopen`/`dlsym`;
/// wit-component's own libdl takes the place of any `libdl.so`. Returns 0, or 1 with the error written to `errors`.
#[unsafe(no_mangle)]
pub extern "C" fn operator_component_link(output: *const c_char, count: i32, names: *const *const c_char,
                                          paths: *const *const c_char, dl_openable: *const u8, errors: i32) -> i32 {
    let string = |pointer: *const c_char| unsafe { CStr::from_ptr(pointer) }.to_string_lossy().into_owned();
    let result = (|| -> anyhow::Result<()> {
        let mut linker = wit_component::Linker::default();
        linker.use_built_in_libdl(true);
        linker.encoder().validate(true);
        for i in 0..count as usize {
            let name = string(unsafe { *names.add(i) });
            if name == "libdl.so" {
                continue;
            }
            let path = string(unsafe { *paths.add(i) });
            let module = std::fs::read(&path).map_err(|e| anyhow::anyhow!("{path}: {e}"))?;
            linker.library(&name, &module, unsafe { *dl_openable.add(i) } != 0)?;
        }
        std::fs::write(string(output), linker.encode()?)?;
        Ok(())
    })();
    match result {
        Ok(()) => 0,
        Err(error) => {
            let mut stream = ManuallyDrop::new(unsafe { File::from_raw_fd(errors) });
            let _ = writeln!(stream, "{error:#}");
            let _ = stream.flush();
            1
        }
    }
}
