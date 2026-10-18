/* srps4_ucontext.S — see srps4_ucontext.h. x86-64 SysV, AT&T syntax. */
    .text

/* int srps4_getcontext(srps4_ucontext_t *ucp)  -- rdi = ucp */
    .globl srps4_getcontext
    .type  srps4_getcontext,@function
srps4_getcontext:
    movq   %rbx,  0(%rdi)
    movq   %rbp,  8(%rdi)
    movq   %r12, 16(%rdi)
    movq   %r13, 24(%rdi)
    movq   %r14, 32(%rdi)
    movq   %r15, 40(%rdi)
    leaq   8(%rsp), %rax          /* rsp as seen by our caller after return */
    movq   %rax, 48(%rdi)
    movq   (%rsp), %rax           /* resume at our return address */
    movq   %rax, 56(%rdi)
    stmxcsr 64(%rdi)
    fnstcw  68(%rdi)
    xorl   %eax, %eax
    ret
    .size srps4_getcontext, .-srps4_getcontext

/* int srps4_swapcontext(srps4_ucontext_t *oucp, const srps4_ucontext_t *ucp)
 *   rdi = oucp (saved), rsi = ucp (resumed) */
    .globl srps4_swapcontext
    .type  srps4_swapcontext,@function
srps4_swapcontext:
    movq   %rbx,  0(%rdi)
    movq   %rbp,  8(%rdi)
    movq   %r12, 16(%rdi)
    movq   %r13, 24(%rdi)
    movq   %r14, 32(%rdi)
    movq   %r15, 40(%rdi)
    leaq   8(%rsp), %rax
    movq   %rax, 48(%rdi)
    movq   (%rsp), %rax
    movq   %rax, 56(%rdi)
    stmxcsr 64(%rdi)
    fnstcw  68(%rdi)

    movq    0(%rsi), %rbx
    movq    8(%rsi), %rbp
    movq   16(%rsi), %r12
    movq   24(%rsi), %r13
    movq   32(%rsi), %r14
    movq   40(%rsi), %r15
    ldmxcsr 64(%rsi)
    fldcw   68(%rsi)
    movq   48(%rsi), %rsp
    movq   56(%rsi), %rax
    pushq  %rax                   /* resume as if returning from swapcontext */
    xorl   %eax, %eax
    ret
    .size srps4_swapcontext, .-srps4_swapcontext

/* Landing pad if a context's function ever returns: there is no uc_link
 * chaining in this subset, so stop loudly. */
    .globl srps4_context_fell_off
    .type  srps4_context_fell_off,@function
srps4_context_fell_off:
    andq   $-16, %rsp
    call   abort
    ud2
    .size srps4_context_fell_off, .-srps4_context_fell_off

    .section .note.GNU-stack,"",@progbits
