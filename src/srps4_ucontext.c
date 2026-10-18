/* srps4_ucontext.c — makecontext half of srps4_ucontext (see header). */
#include "srps4_ucontext.h"

void srps4_context_fell_off(void);

void srps4_makecontext(srps4_ucontext_t *ucp, void (*func)(void), int argc, ...) {
  (void)argc; /* the fiber backend only ever passes 0 arguments */
  uintptr_t top = (uintptr_t)ucp->uc_stack.ss_sp + ucp->uc_stack.ss_size;
  top &= ~(uintptr_t)15;
  /* At a function's first instruction the SysV ABI expects rsp % 16 == 8,
   * i.e. a 16-aligned stack after the return address was pushed. */
  uint64_t *sp = (uint64_t *)(top - 8);
  *sp = (uint64_t)(uintptr_t)srps4_context_fell_off;
  ucp->rsp = (uint64_t)(uintptr_t)sp;
  ucp->rip = (uint64_t)(uintptr_t)func;
  ucp->rbp = 0;
}
