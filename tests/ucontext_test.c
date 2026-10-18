#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "srps4_ucontext.h"
static ucontext_t main_ctx, f_ctx;
static volatile int counter;
static double acc = 1.0;
static void fiber(void) {
  for (;;) {
    double local = acc * 1.5;           /* SSE use across switches */
    counter++;
    acc = local;
    swapcontext(&f_ctx, &main_ctx);
  }
}
int main(void) {
  char *stack = malloc(1 << 16);
  getcontext(&f_ctx);
  f_ctx.uc_stack.ss_sp = stack; f_ctx.uc_stack.ss_size = 1 << 16; f_ctx.uc_link = NULL;
  makecontext(&f_ctx, fiber, 0);
  for (int i = 0; i < 100000; ++i) {
    int before = counter;
    swapcontext(&main_ctx, &f_ctx);
    if (counter != before + 1) { printf("FAIL at %d\n", i); return 1; }
    if (i < 20) acc = 1.0;
  }
  /* snapshot semantics: copy ctx+stack, run, restore, re-run -> same result */
  ucontext_t saved = f_ctx; char *copy = malloc(1 << 16); memcpy(copy, stack, 1 << 16);
  int c0 = counter; double a0 = acc;
  swapcontext(&main_ctx, &f_ctx); swapcontext(&main_ctx, &f_ctx);
  int c2 = counter; double a2 = acc;
  memcpy(stack, copy, 1 << 16); f_ctx = saved; counter = c0; acc = a0;
  swapcontext(&main_ctx, &f_ctx); swapcontext(&main_ctx, &f_ctx);
  if (counter != c2 || acc != a2) { printf("FAIL snapshot\n"); return 1; }
  printf("PASS: %d switches, snapshot restore ok\n", counter);
  return 0;
}
