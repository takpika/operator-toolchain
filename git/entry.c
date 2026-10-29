// ios_system entry point for `git`: lg2 (a-Shell's libgit2 command set) under the usual name.
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int lg2_main(int argc, char **argv);
extern __thread FILE *thread_stderr;

__attribute__((visibility("default"))) int operator_git_main(int argc, char **argv) {
    // git's own leading `-C <dir>` (lg2 has none): run in that folder, then go back, as ios_system keeps one
    // working directory per session.
    char previous[PATH_MAX];
    int changed = 0;
    while (argc > 2 && strncmp(argv[1], "-C", 2) == 0) {
        const char *folder = argv[1][2] ? argv[1] + 2 : argv[2];
        int used = argv[1][2] ? 1 : 2;
        if (!changed && !getcwd(previous, sizeof previous)) return 128;
        if (chdir(folder) != 0) {
            fprintf(thread_stderr, "fatal: cannot change to '%s': %s\n", folder, strerror(errno));
            if (changed) chdir(previous);
            return 128;
        }
        changed = 1;
        argv[used] = argv[0];
        argv += used;
        argc -= used;
    }
    int code = lg2_main(argc, argv);
    if (changed) chdir(previous);
    return code;
}
