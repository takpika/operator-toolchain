/* Included before every LLVM source file built for iOS. The tools run as threads of the app (ios_system), so ending
   one must end only its thread: exit and abort end the command instead of the process. */
#ifndef OPERATOR_IOS_PREFIX_H
#define OPERATOR_IOS_PREFIX_H
#ifdef __cplusplus
#include <cstdlib>
#endif
#include <stdlib.h>
#include <unistd.h>
#ifdef __cplusplus
extern "C" {
#endif
void ios_exit(int code) __attribute__((noreturn));
void operator_llvm_abort(void) __attribute__((noreturn));
#ifdef __cplusplus
}
namespace std { using ::ios_exit; using ::operator_llvm_abort; }
#endif
#define exit ios_exit
#define _exit ios_exit
#define _Exit ios_exit
#define abort operator_llvm_abort
#endif
