// The ios_system side of the shell: its entry point as a command, and running one command of a script.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int ios_system(const char *command);
pid_t ios_fork(void);
int ios_getCommandStatus(void);
pthread_t ios_getThreadId(pid_t pid);
void ios_releaseThreadId(pid_t pid);
void ios_storeThreadId(pthread_t thread);
pid_t ios_currentPid(void);
void ios_setStreams(FILE *input, FILE *output, FILE *errors);
int ios_executable(const char *command);
int ios_setenv(const char *name, const char *value, int overwrite);
char *ios_getenv(const char *name);
char **environmentVariables(pid_t pid);
const void *ios_getContext(void);
void ios_switchSession(const void *session);
extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;
extern __thread void *thread_context;

int operatorShRun(int argc, char **argv, int input, int output, int errors, void *context, char **environment);

/// Go's runtime, starting on iOS, moves the process into the app bundle (runtime/cgo's init_working_dir): that would
/// pull the directory from under every command running, and ios_system's chdir, which the call binds to, fails without
/// a session then. This image's chdir (what runtime/cgo binds to) leaves the directory alone; the shell changes it
/// through ios_system's (set_directory).
int chdir(const char *path) {
    (void)path;
    return 0;
}

/// ios_system's chdir: keeps its session's directory and its limits on where to go.
static int set_directory(const char *path) {
    static int (*ios_chdir)(const char *);
    if (!ios_chdir) {
        void *image = dlopen("@rpath/ios_system.framework/ios_system", RTLD_LAZY | RTLD_NOLOAD);
        if (image) ios_chdir = (int (*)(const char *))dlsym(image, "chdir");
    }
    return ios_chdir ? ios_chdir(path) : -1;
}

/// `operator-sh` (and `sh` and `bash`, aliases of it) as an ios_system command. Not registered as `sh`: ios_system
/// closes the streams of a command so named itself when it ends, the caller's copies included. Each runs its own interpreter, so any number run at once.
__attribute__((visibility("default"))) int operator_sh_main(int argc, char **argv) {
    // ios_system stops a command with pthread_cancel; unwinding through Go frames would take the app down. The shell
    // is stopped through the interrupts its commands see instead (operator_sh_interrupts).
    int previous;
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &previous);
    fflush(thread_stdout);
    fflush(thread_stderr);
    int code = operatorShRun(argc, argv, dup(fileno(thread_stdin)), dup(fileno(thread_stdout)),
                             dup(fileno(thread_stderr)), (void *)ios_getContext(), environmentVariables(ios_currentPid()));
    pthread_setcancelstate(previous, NULL);
    return code;
}

/// How many times the app was asked to stop what runs in this session (Ctrl-C, a timeout): a count that grows, read by
/// the shell before and while its commands run. The app provides it (LocalProcess.swift); 0 without it.
int operator_sh_interrupts(const void *context) {
    static int (*count)(const void *);
    static int looked;
    if (!looked) {
        count = (int (*)(const void *))dlsym(RTLD_DEFAULT, "operator_shell_interrupts");
        looked = 1;
    }
    return count ? count(context) : 0;
}

int operator_sh_executable(const char *name) { return ios_executable(name); }

/// Runs one command (`argv`, NULL-terminated) as ios_system would from a shell, in `directory` with these variables
/// set for it, on copies of these descriptors, and returns its exit code. It is stopped when `*stop` becomes nonzero
/// or the session's interrupt count is no longer `interrupts` (the count when the shell's line started).
int operator_sh_exec(char **argv, char **environment, const char *directory, int input, int output, int errors,
                     const void *context, int interrupts, volatile int *stop) {
    // ios_system takes the text between two record separators (0x1e) as one literal argument.
    size_t length = 1;
    for (char **arg = argv; *arg; arg++) {
        if (strchr(*arg, '\x1e')) return 126;
        length += strlen(*arg) + 3;
    }
    char *line = malloc(length);
    if (!line) return 126;
    char *end = line;
    for (char **arg = argv; *arg; arg++) {
        end += sprintf(end, "%s\x1e%s\x1e", arg == argv ? "" : " ", *arg);
    }
    FILE *in = fdopen(dup(input), "r"), *out = fdopen(dup(output), "w");
    FILE *err = errors == output ? out : fdopen(dup(errors), "w");
    if (!in || !out || !err) { free(line); return 126; }
    // The stages of a pipeline start at the same time, on threads of their own; ios_system's session (its streams,
    // directory, current pid) is shared, so one command starts at a time.
    static pthread_mutex_t starting = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&starting);
    ios_switchSession(context);
    set_directory(directory);
    thread_context = (void *)context;
    ios_setStreams(in, out, err);
    thread_stdin = in;
    thread_stdout = out;
    thread_stderr = err;
    pid_t pid = ios_fork();
    // The new process's environment: the shell's exported variables.
    for (char **variable = environment; variable && *variable; variable++) {
        char *equals = strchr(*variable, '=');
        if (!equals) continue;
        *equals = 0;
        const char *now = ios_getenv(*variable);
        if (!now || strcmp(now, equals + 1) != 0) ios_setenv(*variable, equals + 1, 1);
        *equals = '=';
    }
    ios_system(line);
    pthread_mutex_unlock(&starting);
    // ios_system can return before the command ends: wait for it (sleeping, not spinning), stopping it when asked.
    // A pid never started (ios_system could not run it) is released after 2 seconds. A command asked to stop gets a
    // second to end by itself (the app stops WebAssembly programs and Python itself on an interrupt) before its thread
    // is cancelled: cancelling a thread in the middle of NSLog leaves NSLog's lock broken for the whole app.
    int stopped = 0, waited = 0;
    for (int unstarted = 0; ios_getThreadId(pid) != 0; usleep(1000)) {
        pthread_t thread = ios_getThreadId(pid);
        if ((long)thread == -1) {
            if (++unstarted > 2000) {
                if (ios_currentPid() == pid) ios_storeThreadId(pthread_self());
                ios_releaseThreadId(pid);
                break;
            }
            continue;
        }
        if (!stopped && (*stop || operator_sh_interrupts(context) != interrupts)) {
            stopped = 1;
            if (!*stop) *stop = 2;  // the session was interrupted (see main.go)
        }
        if (stopped && ++waited == 1000) pthread_cancel(thread);
    }
    // ios_system closes a command's streams only for pipes it parsed itself: these copies are the shell's to close
    // (the end of input for whatever reads the other end of a pipe).
    int code = stopped ? 130 : ios_getCommandStatus();
    fclose(in);
    fclose(out);
    if (err != out) fclose(err);
    free(line);
    return code;
}
