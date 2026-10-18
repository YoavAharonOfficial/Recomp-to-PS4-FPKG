/* srps4_ucontext.h — minimal x86-64 user contexts for PS4 homebrew.
 *
 * The OpenOrbis musl ships no getcontext/makecontext/swapcontext, but
 * snesrecomp's fiber backend (and the snapshot support it offers to rewind,
 * run-ahead and save states) is built on exactly those three calls. This is
 * a drop-in with the same contract for the subset the backend uses:
 * cooperative switching between stacks on one thread, no signal masks.
 * Saved state: callee-saved GPRs, rsp, rip, MXCSR and the x87 control word
 * — everything the SysV ABI requires to survive a call.
 *
 * The native smoke-test build uses it too (instead of glibc's), so the
 * exact code that ships to the console is exercised by the headless runs.
 */
#ifndef SRPS4_UCONTEXT_H
#define SRPS4_UCONTEXT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct srps4_stack {
  void  *ss_sp;
  size_t ss_size;
  int    ss_flags;
} srps4_stack_t;

typedef struct srps4_ucontext {
  /* Offsets are fixed: srps4_ucontext.S addresses these directly. */
  uint64_t rbx;    /*  0 */
  uint64_t rbp;    /*  8 */
  uint64_t r12;    /* 16 */
  uint64_t r13;    /* 24 */
  uint64_t r14;    /* 32 */
  uint64_t r15;    /* 40 */
  uint64_t rsp;    /* 48 */
  uint64_t rip;    /* 56 */
  uint32_t mxcsr;  /* 64 */
  uint16_t fpucw;  /* 68 */
  uint16_t pad;
  srps4_stack_t uc_stack;
  struct srps4_ucontext *uc_link;
} srps4_ucontext_t;

int  srps4_getcontext(srps4_ucontext_t *ucp);
int  srps4_swapcontext(srps4_ucontext_t *oucp, const srps4_ucontext_t *ucp);
void srps4_makecontext(srps4_ucontext_t *ucp, void (*func)(void), int argc, ...);

#define ucontext_t  srps4_ucontext_t
#define getcontext  srps4_getcontext
#define swapcontext srps4_swapcontext
#define makecontext srps4_makecontext

#ifdef __cplusplus
}
#endif
#endif
