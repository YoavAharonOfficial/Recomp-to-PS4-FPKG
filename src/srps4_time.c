/* srps4_time.c: translate clock ids for libkernel (console builds only).
 *
 * The PS4's clock_gettime is FreeBSD's, but everything here is compiled
 * against musl, whose clock ids are Linux's. Unmapped, CLOCK_MONOTONIC (1)
 * reaches the kernel as FreeBSD's CLOCK_VIRTUAL, i.e. process CPU time: it
 * runs fast while several threads compute and stops while the process
 * sleeps. That corrupted every "monotonic" timer (libc++ steady_clock, the
 * benchmark/report timers, render-worker stats). The link wraps
 * clock_gettime (srps4_helpers.cmake) and maps the ids. */
#include <time.h>

#if SRPS4_CONSOLE

int __real_clock_gettime(clockid_t clock, struct timespec *ts);

/* FreeBSD <sys/time.h> ids. */
enum {
  FBSD_CLOCK_REALTIME = 0, FBSD_CLOCK_PROF = 2, FBSD_CLOCK_MONOTONIC = 4,
  FBSD_CLOCK_UPTIME = 5, FBSD_CLOCK_REALTIME_FAST = 10,
  FBSD_CLOCK_MONOTONIC_FAST = 12, FBSD_CLOCK_THREAD_CPUTIME_ID = 14,
};

static clockid_t to_freebsd(clockid_t linux_id) {
  switch (linux_id) {
    case 0: return FBSD_CLOCK_REALTIME;          /* CLOCK_REALTIME */
    case 1: return FBSD_CLOCK_MONOTONIC;         /* CLOCK_MONOTONIC */
    case 2: return FBSD_CLOCK_PROF;              /* CLOCK_PROCESS_CPUTIME_ID */
    case 3: return FBSD_CLOCK_THREAD_CPUTIME_ID; /* CLOCK_THREAD_CPUTIME_ID */
    case 4: return FBSD_CLOCK_MONOTONIC;         /* CLOCK_MONOTONIC_RAW */
    case 5: return FBSD_CLOCK_REALTIME_FAST;     /* CLOCK_REALTIME_COARSE */
    case 6: return FBSD_CLOCK_MONOTONIC_FAST;    /* CLOCK_MONOTONIC_COARSE */
    case 7: return FBSD_CLOCK_UPTIME;            /* CLOCK_BOOTTIME */
    default: return linux_id;
  }
}

int __wrap_clock_gettime(clockid_t clock, struct timespec *ts) {
  return __real_clock_gettime(to_freebsd(clock), ts);
}
#endif /* SRPS4_CONSOLE */
