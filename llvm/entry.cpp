// ios_system entry points: clang/clang++/cc/c++, wasm-ld, ar/ranlib and nm. They run on the calling command's thread
// and write to its streams. LLVM keeps global state, so one tool runs at a time; clang runs wasm-ld in-process.
#include "lld/Common/Driver.h"
#include "llvm/Support/LLVMDriver.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Program.h"
#include "llvm/Support/raw_ostream.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string>
#include <unistd.h>
#include <vector>

extern "C" {
extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;
}

int clang_main(int, char **, const llvm::ToolContext &);
int llvm_ar_main(int, char **, const llvm::ToolContext &);
int llvm_nm_main(int, char **, const llvm::ToolContext &);
LLD_HAS_DRIVER(wasm)

/// wasm-component-ld (component/, Rust): links with wasm-ld, then turns the module into a component.
extern "C" int operator_component_ld_main(int argc, const char **argv, int errors);

namespace {

pthread_mutex_t Lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER;

int linkWasm(llvm::ArrayRef<const char *> Args) {
  return lld::lldMain(Args, llvm::outs(), llvm::errs(), {{lld::Wasm, &lld::wasm::link}}).retCode;
}

/// Programs clang starts: the linkers run here instead of in a new process.
int runChild(llvm::StringRef Program, llvm::ArrayRef<llvm::StringRef> Args, std::string *ErrMsg) {
  llvm::StringRef Name = llvm::sys::path::filename(Program);
  if (Name == "wasm-component-ld") {
    std::vector<std::string> Storage(Args.begin(), Args.end());
    std::vector<const char *> Argv;
    for (const std::string &Arg : Storage)
      Argv.push_back(Arg.c_str());
    llvm::errs().flush();
    return operator_component_ld_main(int(Argv.size()), Argv.data(), llvm::standardFD(2));
  }
  if (Name == "wasm-ld" || Name == "ld" || Name == "lld") {
    std::vector<std::string> Storage(Args.begin(), Args.end());
    Storage[0] = "wasm-ld";
    std::vector<const char *> Argv;
    for (const std::string &Arg : Storage)
      Argv.push_back(Arg.c_str());
    return linkWasm(Argv);
  }
  if (ErrMsg)
    *ErrMsg = "cannot run " + Program.str() + " on this device";
  return -1;
}

void finish(void *) {
  llvm::outs().flush();
  llvm::errs().flush();
  pthread_mutex_unlock(&Lock);
}

int descriptor(FILE *Stream, int Default) { return Stream ? fileno(Stream) : Default; }

/// Runs \p Tool with the command's streams; ios_exit (exit in LLVM) still releases the lock. Cancelling the thread
/// midway could leave LLVM's global state broken, so a stopped command finishes in the background instead.
template <typename F> int run(F Tool) {
  int Result = 1;
  int Previous = 0;
  pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &Previous);
  pthread_mutex_lock(&Lock);
  pthread_cleanup_push(finish, nullptr);
  llvm::setStandardFDs(descriptor(thread_stdin, 0), descriptor(thread_stdout, 1), descriptor(thread_stderr, 2));
  llvm::sys::setExecuteHook(runChild);
  Result = Tool();
  pthread_cleanup_pop(1);
  pthread_setcancelstate(Previous, nullptr);
  return Result;
}

bool hasOption(int Argc, char **Argv, const char *Name) {
  size_t Length = strlen(Name);
  for (int I = 1; I < Argc; ++I)
    if (!strncmp(Argv[I], Name, Length))
      return true;
  return false;
}

} // namespace

extern "C" {

/// wasm-ld for wasm-component-ld, on the same thread.
int operator_run_wasm_ld(int Argc, const char **Argv) {
  return linkWasm(llvm::ArrayRef<const char *>(Argv, Argc));
}

/// The sysroot, clang's own headers and WASI's emulation libraries live in the user's folder, where clang-setup
/// unpacks them (~/.local/share/operator/clang/<data id>); explicit options still win.
__attribute__((visibility("default"))) int operator_clang_main(int Argc, char **Argv) {
  const char *HomeVariable = getenv("HOME");
  std::string Root = std::string(HomeVariable ? HomeVariable : "") + "/.local/share/operator/clang/" CLANG_DATA_ID;
  if (access((Root + "/.ready").c_str(), F_OK) != 0) {
    fputs("clang is not set up for this app version. Run `clang-setup` first.\n", thread_stderr ? thread_stderr : stderr);
    return 78;
  }
  std::vector<std::string> Extra;
  // Programs are WASI 0.3 components (the sysroot is wasm32-wasip3).
  if (!hasOption(Argc, Argv, "--target") && !hasOption(Argc, Argv, "-target"))
    Extra.push_back("--target=wasm32-wasip3");
  if (!hasOption(Argc, Argv, "--sysroot"))
    Extra.push_back("--sysroot=" + Root + "/wasi-sysroot");
  if (!hasOption(Argc, Argv, "-resource-dir"))
    Extra.push_back("-resource-dir=" + Root + "/lib/clang/" CLANG_MAJOR);
  for (const char *Flag : {"-D_WASI_EMULATED_SIGNAL", "-D_WASI_EMULATED_MMAN", "-D_WASI_EMULATED_PROCESS_CLOCKS",
                           "-D_WASI_EMULATED_GETPID", "-Wno-unused-command-line-argument"})
    Extra.push_back(Flag);
  // C++ code usually expects exceptions: WebAssembly exceptions (with libunwind) unless turned off.
  llvm::StringRef Name = llvm::sys::path::filename(Argv[0]);
  bool CXX = Name.ends_with("++");
  bool NoExceptions = hasOption(Argc, Argv, "-fno-exceptions") || hasOption(Argc, Argv, "-fno-wasm-exceptions") ||
                      hasOption(Argc, Argv, "-fno-cxx-exceptions");
  if (CXX && !NoExceptions && !hasOption(Argc, Argv, "-fwasm-exceptions"))
    Extra.push_back("-fwasm-exceptions");
  bool Exceptions = !NoExceptions && (CXX || hasOption(Argc, Argv, "-fwasm-exceptions"));
  // wasi-sdk's libraries use the standard (exnref) exception instructions; one module cannot mix them with the
  // legacy ones clang emits by default. setjmp/longjmp use the same mechanism.
  for (const char *Flag : {"-mllvm", "-wasm-use-legacy-eh=false", "-mllvm", "-wasm-enable-sjlj"})
    Extra.push_back(Flag);
  std::vector<std::string> Libraries;
  for (const char *Library : {"-lwasi-emulated-signal", "-lwasi-emulated-mman", "-lwasi-emulated-process-clocks",
                              "-lwasi-emulated-getpid"})
    Libraries.push_back(Library);
  Libraries.push_back("-lsetjmp");
  if (Exceptions)
    Libraries.push_back("-lunwind");
  std::vector<char *> Args{Argv[0]};
  for (std::string &Arg : Extra)
    Args.push_back(Arg.data());
  for (int I = 1; I < Argc; ++I)
    Args.push_back(Argv[I]);
  for (std::string &Library : Libraries)
    Args.push_back(Library.data());
  Args.push_back(nullptr);
  return run([&] {
    return clang_main(int(Args.size() - 1), Args.data(), {Args[0], nullptr, false});
  });
}

__attribute__((visibility("default"))) int operator_wasm_ld_main(int Argc, char **Argv) {
  return run([&] { return linkWasm(llvm::ArrayRef<const char *>(Argv, Argc)); });
}

__attribute__((visibility("default"))) int operator_ar_main(int Argc, char **Argv) {
  return run([&] { return llvm_ar_main(Argc, Argv, {Argv[0], nullptr, false}); });
}

__attribute__((visibility("default"))) int operator_nm_main(int Argc, char **Argv) {
  return run([&] { return llvm_nm_main(Argc, Argv, {Argv[0], nullptr, false}); });
}
}
