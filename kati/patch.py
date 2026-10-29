#!/usr/bin/env python3
"""Lets kati (a GNU make clone) run as `make` inside the app. ios_system runs every command on a new thread of the
same process, so kati's global state is made thread-local: each run, including a nested $(MAKE), starts fresh.
Commands run in dash through ios_system instead of posix_spawn, and kati installs no SIGSEGV handler."""
import pathlib, re, sys

src = pathlib.Path(sys.argv[1]) / "src"

def edit(name, old, new, count=1):
    file = src / name
    text = file.read_text()
    if new and new in text:
        return
    if text.count(old) != count:
        sys.exit(f"{name}: expected {count} match(es) for {old[:70]!r}")
    file.write_text(text.replace(old, new))

# Global and static state, by file: (text as written, text with thread_local).
state = {
    "flags.h": ["extern Flags g_flags;"],
    "flags.cc": ["Flags g_flags;"],
    "symtab.h": ["extern std::vector<std::string*>* g_symbols;", "extern Symbol kEmptySym;", "extern Symbol kShellSym;",
                 "extern Symbol kAllowRulesSym;", "extern Symbol kKatiReadonlySym;"],
    "symtab.cc": ["std::vector<std::string*>* g_symbols;", "static std::vector<SymbolData> g_symbol_data;",
                  "Symbol kEmptySym;", "Symbol kShellSym;", "Symbol kAllowRulesSym;", "Symbol kKatiReadonlySym;",
                  "Symbol kVariablesSym;", "Symbol kKatiSymbolsSym;", "static Symtab g_symtab;"],
    "log.h": ["extern bool g_log_no_exit;", "extern std::string* g_last_error;"],
    "log.cc": ["bool g_log_no_exit;", "std::string* g_last_error;"],
    "eval.h": ["  static SymbolSet used_undefined_vars_;"],
    "eval.cc": ["SymbolSet Evaluator::used_undefined_vars_;"],
    "var.h": ["  static std::unordered_map<const Var*, std::string> diagnostic_messages_;", "  static bool is_set_;",
              "  static int shell_status_;", "  static std::string shell_status_string_;", "  static SymbolSet used_env_vars_;"],
    "var.cc": ["std::unordered_map<const Var*, std::string> Var::diagnostic_messages_;", "bool ShellStatusVar::is_set_ = false;",
               "int ShellStatusVar::shell_status_ = 0;", "std::string ShellStatusVar::shell_status_string_;",
               "  static Var* undefined_var;", "SymbolSet Vars::used_env_vars_;"],
    "dep.cc": ["static std::vector<std::unique_ptr<DepNode>> g_dep_node_pool;"],
    "fileutil.cc": ["static GlobCache g_gc;"],
    "find.cc": ["static unsigned int find_emulator_node_cnt = 0;", "static FindEmulator* g_instance;"],
    "func.cc": ["static std::vector<CommandResult*> g_command_results;"],
    "parser.cc": ["  static std::vector<ParseErrorStmt*> parse_errors;", "std::vector<ParseErrorStmt*> Parser::parse_errors;"],
    "stats.cc": ["std::vector<Stats*>* g_stats;"],
    "file_cache.cc": ["  static MakefileCacheManager instance;"],
    "main.cc": ["  static SegfaultHandler* global_handler;", "SegfaultHandler* SegfaultHandler::global_handler = nullptr;"],
}
for name, declarations in state.items():
    for declaration in declarations:
        stripped = declaration.lstrip()
        indent = declaration[: len(declaration) - len(stripped)]
        if stripped.startswith("extern "):
            local = indent + "extern thread_local " + stripped[len("extern "):]
        elif stripped.startswith("static "):
            local = indent + "static thread_local " + stripped[len("static "):]
        else:
            local = indent + "thread_local " + stripped
        file = src / name
        text = file.read_text()
        if local in text:
            continue
        if not re.search(r"^" + re.escape(declaration) + r"$", text, re.M):
            sys.exit(f"{name}: no line {declaration!r}")
        file.write_text(re.sub(r"^" + re.escape(declaration) + r"$", lambda _: local, text, count=1, flags=re.M))

# No process-wide crash handler inside an app.
edit("main.cc", "  sigaction(SIGSEGV, &new_action_, &orig_action_);\n", "")
edit("main.cc", "  sigaction(SIGSEGV, &orig_action_, nullptr);\n", "")
# The app's folder tells makefile from Makefile (upstream assumes Apple file systems do not).
edit("main.cc", '    g_flags.makefile = "GNUmakefile";\n#if !defined(__APPLE__)\n  } else if (Exists("makefile")) {\n'
     '    g_flags.makefile = "makefile";\n#endif\n',
     '    g_flags.makefile = "GNUmakefile";\n  } else if (Exists("makefile")) {\n    g_flags.makefile = "makefile";\n')

# Commands (recipes and $(shell)): one ios_system command in dash, its output collected in a temporary file.
fileutil = src / "fileutil.cc"
text = fileutil.read_text()
start = text.index("int RunCommand(const std::string& shell,")
end = text.index("  return status;\n}\n", start) + len("  return status;\n}\n")
replacement = r'''extern "C" int operator_run_shell(const char* command, FILE* input, FILE* output, FILE* errors);

// In the app (iOS) commands are ios_system commands of the same process: /bin/sh is dash (command/command.c), and
// the output is collected in a temporary file.
int RunCommand(const std::string& shell,
               const std::string& shellflag,
               const std::string& cmd,
               RedirectStderr redirect_stderr,
               std::string* s) {
  FILE* output = tmpfile();
  if (!output)
    PERROR("tmpfile failed");
  FILE* errors = thread_stderr;
  if (redirect_stderr == RedirectStderr::STDOUT)
    errors = output;
  else if (redirect_stderr == RedirectStderr::DEV_NULL)
    errors = fopen("/dev/null", "w");
  int code = operator_run_shell(cmd.c_str(), thread_stdin, output, errors);
  if (errors != output && errors != thread_stderr && errors)
    fclose(errors);
  rewind(output);
  char buffer[4096];
  size_t length;
  while ((length = fread(buffer, 1, sizeof(buffer), output)) > 0)
    s->append(buffer, length);
  fclose(output);
  return (code & 0xff) << 8;
}
'''
fileutil.write_text(text[:start] + replacement + text[end:])
