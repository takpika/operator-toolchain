// Shell commands for the tools (system, popen, kati's recipes): each runs in dash (`dash -c`, so ios_system resets
// and reuses it) as an ios_system command of its own.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int ios_system(const char *command);
pid_t ios_fork(void);
void ios_waitpid(pid_t pid);
int ios_getCommandStatus(void);
void ios_setStreams(FILE *input, FILE *output, FILE *errors);
extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;

static FILE *copy(FILE *stream, const char *mode) {
    fflush(stream);
    int descriptor = dup(fileno(stream));
    return descriptor < 0 ? NULL : fdopen(descriptor, mode);
}

/// Runs `command` in dash with these streams and returns its exit code. ios_system closes a shell's streams when it
/// ends (end of input for a pipe), so dash gets copies; `errors` may be `output`.
int operator_run_shell(const char *command, FILE *input, FILE *output, FILE *errors) {
    // ios_system takes the text between two record separators (0x1e) as one literal argument.
    if (strchr(command, '\x1e')) return 127;
    size_t length = strlen(command) + sizeof("dash -c \x1e\x1e");
    char *line = malloc(length);
    if (!line) return 127;
    snprintf(line, length, "dash -c \x1e%s\x1e", command);
    FILE *in = copy(input, "r"), *out = copy(output, "w");
    FILE *err = errors == output ? out : copy(errors, "w");
    FILE *savedIn = thread_stdin, *savedOut = thread_stdout, *savedErr = thread_stderr;
    // ios_system gives a command this thread's streams, and the session's to commands it starts.
    ios_setStreams(in, out, err);
    thread_stdin = in;
    thread_stdout = out;
    thread_stderr = err;
    // ios_system can return while dash still runs: wait for it, then take its status (as ios_system does for &&).
    pid_t pid = ios_fork();
    ios_system(line);
    ios_waitpid(pid);
    int code = ios_getCommandStatus();
    ios_setStreams(savedIn, savedOut, savedErr);
    thread_stdin = savedIn;
    thread_stdout = savedOut;
    thread_stderr = savedErr;
    free(line);
    return code;
}

/// Returns a wait status, as system() does.
int operator_system(const char *command) {
    if (!command) return 1;
    int code = operator_run_shell(command, thread_stdin, thread_stdout, thread_stderr);
    return (code & 0xff) << 8;
}

/// Reading only: the command runs to completion first, its output in a temporary file, so a shell still finishing in
/// the background (as with ios_popen) cannot overlap the next one.
FILE *operator_popen(const char *command, const char *mode) {
    if (mode[0] != 'r') return NULL;
    FILE *output = tmpfile();
    if (!output) return NULL;
    operator_run_shell(command, thread_stdin, output, thread_stderr);
    rewind(output);
    return output;
}

/// The exit status is not kept.
int operator_pclose(FILE *stream) { return fclose(stream) == 0 ? 0 : -1; }
