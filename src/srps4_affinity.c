/* srps4_affinity.c: pin the calling thread to one core (console builds).
 * Kept apart from srps4_main.c because <orbis/libkernel.h> declares
 * scePthreadSetaffinity without a prototype. */
#include <pthread.h>

#if SRPS4_CONSOLE
int scePthreadSetaffinity(pthread_t thread, unsigned long mask);
int scePthreadGetaffinity(pthread_t thread, unsigned long *mask);
pthread_t scePthreadSelf(void);
void srps4_pin_current_thread(unsigned core) {
  scePthreadSetaffinity(scePthreadSelf(), 1ul << core);
}
/* The calling thread's core mask (0 if the query fails). */
unsigned long srps4_current_affinity(void) {
  unsigned long mask = 0;
  if (scePthreadGetaffinity(scePthreadSelf(), &mask) != 0) mask = 0;
  return mask;
}
#else
void srps4_pin_current_thread(unsigned core) { (void)core; }
unsigned long srps4_current_affinity(void) { return 0; }
#endif
