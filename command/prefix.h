/* Included before every source file of the small C tools (pdpmake, toybox, pkgconf) built for iOS. They run as
   ios_system commands inside the app, so their standard streams, exit and child commands go through the running
   command (ios_error.h), and the shell commands they run (system, popen) run in dash, as with `sh -c`. */
#ifndef OPERATOR_COMMAND_PREFIX_H
#define OPERATOR_COMMAND_PREFIX_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <errno.h>
#include "ios_error.h"
#undef stdin
#undef stdout
#undef stderr
#define stdin thread_stdin
#define stdout thread_stdout
#define stderr thread_stderr
/* ios_error.h leaves these to the C library in C++, where they would write to the app's own output. */
#ifdef __cplusplus
#undef printf
#undef puts
#undef putchar
#define printf(...) fprintf(thread_stdout, __VA_ARGS__)
#define vprintf(format, arguments) vfprintf(thread_stdout, format, arguments)
#define puts(text) (fputs(text, thread_stdout), fputc('\n', thread_stdout))
#define putchar(c) fputc(c, thread_stdout)
#endif
#undef perror
#define perror(text) fprintf(thread_stderr, "%s: %s\n", text, strerror(errno))
#undef system
#undef popen
#undef pclose
#define system operator_system
#define popen operator_popen
#define pclose operator_pclose
int operator_system(const char *command);
FILE *operator_popen(const char *command, const char *mode);
int operator_pclose(FILE *stream);
#endif
