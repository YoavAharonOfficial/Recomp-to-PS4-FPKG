/* srps4_affinity.c: pin the calling thread to one core (console builds).
 * Kept apart from srps4_main.c because <orbis/libkernel.h> declares
 * scePthreadSetaffinity without a prototype. */
#include <pthread.h>

#if SRPS4_CONSOLE
int scePthreadSetaffinity(pthread_t thread, unsigned long mask);
pthread_t scePthreadSelf(void);
void srps4_pin_current_thread(unsigned core) {
  scePthreadSetaffinity(scePthreadSelf(), 1ul << core);
}
#else
void srps4_pin_current_thread(unsigned core) { (void)core; }
#endif
