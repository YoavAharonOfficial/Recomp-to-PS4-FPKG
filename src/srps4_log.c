/* srps4_log.c: capture everything written to stdout/stderr without touching
 * file descriptors.
 *
 * Retail firmware does not honour freopen()/dup2() onto fds 1 and 2: both the
 * port's freopen and the game's own dup2 left their log files empty while
 * ordinary fopen'd files worked. So instead of redirecting descriptors, the
 * link wraps the stdio entry points (--wrap=fprintf etc., see
 * srps4_helpers.cmake). Any call aimed at stdout/stderr, from the game, the
 * framework or SDL, is diverted here, appended to a plain fopen'd log file, and
 * mirrored line by line to the kernel log (GoldHEN klog, port 3232). Calls on
 * any other FILE go straight to the real function.
 *
 * Note: clang lowers printf("x\n") to puts() and fprintf(f, "%s", s) to
 * fputs(), so the whole family is wrapped, not just the printf variants. */
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

int __real_fprintf(FILE *f, const char *fmt, ...);
int __real_vfprintf(FILE *f, const char *fmt, va_list ap);
int __real_fputs(const char *s, FILE *f);
int __real_fputc(int c, FILE *f);
size_t __real_fwrite(const void *p, size_t sz, size_t n, FILE *f);
int __real_fflush(FILE *f);

#if SRPS4_CONSOLE
int sceKernelDebugOutText(int channel, const char *text);
#endif

static FILE *s_log;               /* NULL until srps4_log_open() */
static atomic_flag s_lock = ATOMIC_FLAG_INIT;
static char s_line[1024];         /* pending klog line */
static size_t s_line_len;

static void lock(void) { while (atomic_flag_test_and_set_explicit(&s_lock, memory_order_acquire)) {} }
static void unlock(void) { atomic_flag_clear_explicit(&s_lock, memory_order_release); }

static int is_std(FILE *f) { return f == stdout || f == stderr; }

static void klog_flush_line(void) {
#if SRPS4_CONSOLE
  if (s_line_len) {
    s_line[s_line_len] = '\0';
    sceKernelDebugOutText(0, s_line);
  }
#endif
  s_line_len = 0;
}

/* Called with the lock held. */
static void emit(const char *p, size_t n) {
  if (s_log) {
    __real_fwrite(p, 1, n, s_log);
  } else {
    /* Before the log is open (native builds, or very early): pass through. */
    __real_fwrite(p, 1, n, stderr);
  }
  for (size_t i = 0; i < n; ++i) {
    char c = p[i];
    if (s_line_len < sizeof(s_line) - 2) s_line[s_line_len++] = c;
    if (c == '\n' || s_line_len >= sizeof(s_line) - 2) klog_flush_line();
  }
  /* Flush per call: a crash must not swallow the last lines. */
  if (s_log && memchr(p, '\n', n)) __real_fflush(s_log);
}

int srps4_log_open(const char *path) {
  FILE *f = fopen(path, "w");
  if (!f) return -1;
  setvbuf(f, NULL, _IOFBF, 1 << 14);
  lock();
  s_log = f;
  unlock();
  return 0;
}

int __wrap_vfprintf(FILE *f, const char *fmt, va_list ap) {
  if (!is_std(f)) return __real_vfprintf(f, fmt, ap);
  char buf[2048];
  int n = vsnprintf(buf, sizeof(buf), fmt, ap);
  if (n < 0) return n;
  size_t len = (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1;
  lock(); emit(buf, len); unlock();
  return n;
}

int __wrap_fprintf(FILE *f, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = __wrap_vfprintf(f, fmt, ap);
  va_end(ap);
  return r;
}

int __wrap_vprintf(const char *fmt, va_list ap) { return __wrap_vfprintf(stdout, fmt, ap); }

int __wrap_printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = __wrap_vfprintf(stdout, fmt, ap);
  va_end(ap);
  return r;
}

int __wrap_fputs(const char *s, FILE *f) {
  if (!is_std(f)) return __real_fputs(s, f);
  lock(); emit(s, strlen(s)); unlock();
  return 1;
}

int __wrap_puts(const char *s) {
  lock(); emit(s, strlen(s)); emit("\n", 1); unlock();
  return 1;
}

int __wrap_fputc(int c, FILE *f) {
  if (!is_std(f)) return __real_fputc(c, f);
  char ch = (char)c;
  lock(); emit(&ch, 1); unlock();
  return (unsigned char)c;
}

int __wrap_putc(int c, FILE *f) { return __wrap_fputc(c, f); }
int __wrap_putchar(int c) { return __wrap_fputc(c, stdout); }

size_t __wrap_fwrite(const void *p, size_t sz, size_t n, FILE *f) {
  if (!is_std(f)) return __real_fwrite(p, sz, n, f);
  lock(); emit((const char *)p, sz * n); unlock();
  return n;
}

void __wrap_perror(const char *s) {
  /* strerror is safe here: errno is still the caller's. */
  extern int *__errno_location(void);
  const char *e = strerror(*__errno_location());
  lock();
  if (s && *s) { emit(s, strlen(s)); emit(": ", 2); }
  emit(e, strlen(e)); emit("\n", 1);
  unlock();
}

int __wrap_fflush(FILE *f) {
  if (f == NULL || is_std(f)) {
    lock();
    if (s_log) __real_fflush(s_log);
    unlock();
    if (f) return 0;
  }
  return __real_fflush(f);
}
