/* srps4_threads.c — keep helper threads off the emulation core.
 *
 * The main thread is pinned to core 0 before the title starts, and FreeBSD
 * threads inherit their creator's cpuset, so every thread a title or SDL
 * creates afterwards (audio, engine workers, file writers) also landed on
 * core 0 and competed with emulation for it: audio crackle and frame dips
 * while a writer was busy. Threads created through pthread_create (SDL's
 * threads among them) now start on cores 2-5. The mask is applied by the new
 * thread itself before the title's entry runs, so a thread that pins itself
 * (the snesrecomp compose workers, the Genesis audio callback) still wins.
 *
 * SRPS4_THREAD_CORES=<hex mask> (srps4_env.txt) overrides the mask; 0 leaves
 * new threads where they were created. Linked with --wrap=pthread_create on
 * the console. */
#include <pthread.h>
#include <stdlib.h>

#if SRPS4_CONSOLE
int __real_pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg);
int scePthreadSetaffinity(pthread_t thread, unsigned long mask);
pthread_t scePthreadSelf(void);

typedef struct { void *(*fn)(void *); void *arg; unsigned long mask; } Start;

static void *start(void *p) {
  Start s = *(Start *)p;
  free(p);
  scePthreadSetaffinity(scePthreadSelf(), s.mask);
  return s.fn(s.arg);
}

int __wrap_pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg) {
  unsigned long mask = 0x3Cul;                   /* cores 2-5 */
  const char *env = getenv("SRPS4_THREAD_CORES");
  if (env && *env) mask = strtoul(env, NULL, 16);
  Start *s = mask ? (Start *)malloc(sizeof *s) : NULL;
  if (!s) return __real_pthread_create(t, a, fn, arg);
  s->fn = fn; s->arg = arg; s->mask = mask;
  int r = __real_pthread_create(t, a, start, s);
  if (r != 0) free(s);
  return r;
}
#endif
