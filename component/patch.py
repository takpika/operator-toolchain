#!/usr/bin/env python3
"""Lets wasm-component-ld run inside the app: arguments come from the caller instead of the process, wasm-ld runs
in-process (operator_run_wasm_ld, in llvm.framework) instead of as a child process, and errors are returned."""
import pathlib, sys

root = pathlib.Path(sys.argv[1])

def patch(name, old, new):
    file = root / name
    text = file.read_text()
    if new and new in text:
        return
    if text.count(old) != 1:
        sys.exit(f"{name}: expected one match for {old[:60]!r}")
    file.write_text(text.replace(old, new))

patch("src/argfile.rs", "pub fn expand() -> Result<Vec<OsString>> {", "pub fn expand(arguments: Vec<OsString>) -> Result<Vec<OsString>> {")
patch("src/argfile.rs", "    for arg in std::env::args_os() {", "    for arg in arguments {")
patch("src/lib.rs", "    fn parse() -> Result<App> {\n        let mut args = argfile::expand().context(",
      "    fn parse(arguments: Vec<OsString>) -> Result<App> {\n        let first = arguments[0].clone();\n"
      "        let mut args = argfile::expand(arguments).context(")
patch("src/lib.rs", "let mut component_ld_args = vec![std::env::args_os().nth(0).unwrap()];",
      "let mut component_ld_args = vec![first];")
patch("src/lib.rs", "fn run() -> Result<()> {\n    App::parse()?.run()\n}",
      "fn run(arguments: Vec<OsString>) -> Result<()> {\n    App::parse(arguments)?.run()\n}\n\n"
      "/// Links like `main` with these arguments, writing errors to `errors` and returning the exit code.\n"
      "pub fn run_with(arguments: Vec<OsString>, errors: &mut dyn std::io::Write) -> i32 {\n"
      "    let err = match run(arguments) {\n        Ok(()) => return 0,\n        Err(e) => e,\n    };\n"
      "    let _ = writeln!(errors, \"error: {err}\");\n"
      "    if err.chain().len() > 1 {\n        let _ = writeln!(errors, \"\\nCaused by:\");\n"
      "        for (i, err) in err.chain().skip(1).enumerate() {\n"
      "            let _ = writeln!(errors, \"{i:>5}: {}\", err.to_string().replace(\"\\n\", \"\\n       \"));\n        }\n    }\n    1\n}\n\n"
      "unsafe extern \"C\" {\n    /// wasm-ld in the same process (llvm.framework).\n"
      "    fn operator_run_wasm_ld(argc: i32, argv: *const *const std::ffi::c_char) -> i32;\n}")
patch("src/lib.rs", "    let err = match run() {", "    let err = match run(std::env::args_os().collect()) {")
patch("src/lib.rs", """    fn run(&self, args: &[&OsString]) -> std::io::Result<ExitStatus> {
        let mut cmd = Command::new(&self.exe);
        if self.needs_flavor {
            cmd.arg("-flavor").arg("wasm");
        }
        cmd.args(args);
        if self.verbose {
            cmd.arg("--verbose");
        }
        if let Some(output) = &self.output {
            cmd.arg("-o").arg(output);
        }
        if self.verbose {
            eprintln!("running {cmd:?}");
        }
        cmd.status()
    }""", """    fn run(&self, args: &[&OsString]) -> std::io::Result<ExitStatus> {
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::process::ExitStatusExt;
        let mut words: Vec<Vec<u8>> = vec![b"wasm-ld".to_vec()];
        words.extend(args.iter().map(|arg| arg.as_bytes().to_vec()));
        if self.verbose {
            words.push(b"--verbose".to_vec());
        }
        if let Some(output) = &self.output {
            words.push(b"-o".to_vec());
            words.push(output.as_os_str().as_bytes().to_vec());
        }
        let strings = words
            .into_iter()
            .map(|word| std::ffi::CString::new(word).map_err(std::io::Error::other))
            .collect::<std::io::Result<Vec<_>>>()?;
        let pointers: Vec<_> = strings.iter().map(|s| s.as_ptr()).collect();
        let code = unsafe { operator_run_wasm_ld(pointers.len() as i32, pointers.as_ptr()) };
        Ok(ExitStatus::from_raw((code & 0xff) << 8))
    }""")
patch("src/lib.rs", "use std::process::{Command, ExitStatus};", "use std::process::ExitStatus;")
print("patched", root)
