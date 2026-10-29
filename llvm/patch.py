#!/usr/bin/env python3
"""Lets clang, wasm-ld, ar and nm run as commands inside an iOS app (ios_system threads): no process-wide signal
handlers or shutdown, standard streams that follow the running command, and child programs run in-process."""
import pathlib, sys

root = pathlib.Path(sys.argv[1])

def patch(path, old, new, count=1):
    file = root / path
    text = file.read_text()
    if new and new in text:
        return
    if text.count(old) != count:
        sys.exit(f"{path}: expected {count} match(es) for {old[:60]!r}")
    file.write_text(text.replace(old, new))

IOS = "#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n"

# Standard streams: the command's descriptors, set before each run.
patch("llvm/include/llvm/Support/raw_ostream.h", "LLVM_ABI raw_fd_ostream &outs();",
      "LLVM_ABI raw_fd_ostream &outs();\n\n"
      "/// The descriptors outs(), errs(), \"-\" and stdin use (0, 1, 2 unless an embedding host sets others).\n"
      "LLVM_ABI int standardFD(int Which);\nLLVM_ABI void setStandardFDs(int In, int Out, int Err);")
patch("llvm/include/llvm/Support/raw_ostream.h", "  void close();",
      "  void close();\n\n  /// Writes to \\p NewFD from now on (after flushing), without owning it.\n  void resetFD(int NewFD);", count=1)
patch("llvm/lib/Support/raw_ostream.cpp", "    sys::ChangeStdoutMode(Flags);\n    return STDOUT_FILENO;",
      "    sys::ChangeStdoutMode(Flags);\n    return standardFD(1);")
patch("llvm/lib/Support/raw_ostream.cpp", "  if (FD <= STDERR_FILENO)\n    ShouldClose = false;",
      "  if (FD <= STDERR_FILENO || FD == standardFD(1) || FD == standardFD(2))\n    ShouldClose = false;")
patch("llvm/lib/Support/raw_ostream.cpp", "  static raw_fd_ostream S(STDERR_FILENO, false, true);\n  return S;\n}",
      "  static raw_fd_ostream S(standardFD(2), false, true);\n  return S;\n}\n\n"
      "static int StandardFDs[3] = {0, 1, 2};\n\n"
      "int llvm::standardFD(int Which) { return StandardFDs[Which]; }\n\n"
      "void llvm::setStandardFDs(int In, int Out, int Err) {\n"
      "  StandardFDs[0] = In;\n  StandardFDs[1] = Out;\n  StandardFDs[2] = Err;\n"
      "  outs().resetFD(Out);\n  errs().resetFD(Err);\n}\n\n"
      "void raw_fd_ostream::resetFD(int NewFD) {\n  flush();\n  FD = NewFD;\n  ShouldClose = false;\n"
      "  SupportsSeeking = false;\n  IsRegularFile = false;\n  pos = 0;\n  EC = std::error_code();\n}")
patch("llvm/lib/Support/Unix/Path.inc",
      "file_t getStdinHandle() { return 0; }\nfile_t getStdoutHandle() { return 1; }\nfile_t getStderrHandle() { return 2; }",
      "file_t getStdinHandle() { return llvm::standardFD(0); }\nfile_t getStdoutHandle() { return llvm::standardFD(1); }\n"
      "file_t getStderrHandle() { return llvm::standardFD(2); }")
patch("llvm/lib/Support/Path.cpp", '#include "llvm/Support/Process.h"',
      '#include "llvm/Support/Process.h"\n#include "llvm/Support/raw_ostream.h"')

# Child programs (clang running wasm-ld): an embedding host can run them itself.
patch("llvm/include/llvm/Support/Program.h", "LLVM_ABI int ExecuteAndWait(",
      "/// Runs programs for ExecuteAndWait instead of spawning processes, when set: returns the exit code, or -1 with\n"
      "/// \\p ErrMsg set.\n"
      "using ExecuteHook = int (*)(StringRef Program, ArrayRef<StringRef> Args, std::string *ErrMsg);\n"
      "LLVM_ABI void setExecuteHook(ExecuteHook Hook);\n\nLLVM_ABI int ExecuteAndWait(")
patch("llvm/lib/Support/Program.cpp", "  assert(Redirects.empty() || Redirects.size() == 3);\n  ProcessInfo PI;\n  if (Execute(PI, Program, Args, Env, Redirects, MemoryLimit, ErrMsg,\n              AffinityMask, /*DetachProcess=*/false)) {",
      "  assert(Redirects.empty() || Redirects.size() == 3);\n"
      "  if (CurrentExecuteHook) {\n    int Result = CurrentExecuteHook(Program, Args, ErrMsg);\n"
      "    if (ExecutionFailed)\n      *ExecutionFailed = Result == -1;\n    return Result;\n  }\n"
      "  ProcessInfo PI;\n  if (Execute(PI, Program, Args, Env, Redirects, MemoryLimit, ErrMsg,\n              AffinityMask, /*DetachProcess=*/false)) {")
patch("llvm/lib/Support/Program.cpp", "int sys::ExecuteAndWait(StringRef Program, ArrayRef<StringRef> Args,",
      "static sys::ExecuteHook CurrentExecuteHook = nullptr;\n\n"
      "void sys::setExecuteHook(ExecuteHook Hook) { CurrentExecuteHook = Hook; }\n\n"
      "int sys::ExecuteAndWait(StringRef Program, ArrayRef<StringRef> Args,")

# Inside an app: no process-wide signal or new handlers, and no shutdown, so the tools can run again.
patch("llvm/lib/Support/InitLLVM.cpp", '#include "llvm/Support/InitLLVM.h"\n',
      '#include "llvm/Support/InitLLVM.h"\n' + IOS)
patch("llvm/lib/Support/InitLLVM.cpp", "  // Bring stdin/stdout/stderr into a known state.\n#ifdef _WIN32",
      "#if TARGET_OS_IPHONE\n  (void)InstallPipeSignalExitHandler;\n  (void)NeedsPOSIXUtilitySignalHandling;\n  return;\n#endif\n"
      "  // Bring stdin/stdout/stderr into a known state.\n#ifdef _WIN32")
patch("llvm/lib/Support/InitLLVM.cpp", "InitLLVM::~InitLLVM() {\n  CleanupStdHandles(nullptr);\n  llvm_shutdown();\n}",
      "InitLLVM::~InitLLVM() {\n  CleanupStdHandles(nullptr);\n#if !TARGET_OS_IPHONE\n  llvm_shutdown();\n#endif\n}")
patch("lld/Common/ErrorHandler.cpp", "  if (!CrashRecoveryContext::GetCurrent())\n    llvm_shutdown();",
      "#if !(defined(__APPLE__) && TARGET_OS_IPHONE)\n  if (!CrashRecoveryContext::GetCurrent())\n    llvm_shutdown();\n#endif")
patch("lld/Common/ErrorHandler.cpp", '#include "lld/Common/ErrorHandler.h"\n',
      '#include "lld/Common/ErrorHandler.h"\n' + IOS)
# clang runs cc1 in-process only for single-job commands; compiling and linking at once must stay in-process too.
patch("clang/lib/Driver/Driver.cpp", "  if (C.getJobs().size() > 1 || CCPrintProcessStats)\n    for (auto &J : C.getJobs())\n      J.InProcess = false;",
      "#if !TARGET_OS_IPHONE\n  if (C.getJobs().size() > 1 || CCPrintProcessStats)\n    for (auto &J : C.getJobs())\n      J.InProcess = false;\n#endif")
patch("clang/lib/Driver/Driver.cpp", "#include <unistd.h> // getpid", "#include <unistd.h> // getpid\n" + IOS.rstrip("\n"))
# abort() (renamed by ios-prefix.h, including in libc++'s inline code) ends the command, not the app.
with open(root / "llvm/lib/Support/ErrorHandling.cpp") as f:
    text = f.read()
if "operator_llvm_abort" not in text:
    with open(root / "llvm/lib/Support/ErrorHandling.cpp", "a") as f:
        f.write("\n#if defined(__APPLE__)\n#include <TargetConditionals.h>\n#endif\n#if TARGET_OS_IPHONE\n"
                "extern \"C\" void operator_llvm_abort(void) {\n  llvm::errs() << \"LLVM aborted.\\n\";\n"
                "  llvm::errs().flush();\n  ios_exit(134);\n}\n#endif\n")
print("patched", root)
