//! wasm-component-ld for llvm.framework: clang links wasm32-wasip3 programs with it, in-process.

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
