// ios_system entry point for `git`: lg2 (a-Shell's libgit2 command set) under the usual name.
int lg2_main(int argc, char **argv);

__attribute__((visibility("default"))) int operator_git_main(int argc, char **argv) {
    return lg2_main(argc, argv);
}
