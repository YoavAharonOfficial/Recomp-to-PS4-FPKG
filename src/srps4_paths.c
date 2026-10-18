/* srps4_paths.c — relative paths resolve against the title's data directory.
 *
 * The desktop host does all its I/O relative to the working directory, which
 * it anchors with chdir() to "beside the executable" (our /data/<Title>). How
 * far a PS4 process's kernel-side cwd can be relied on under every exploit
 * and loader is not something we want stability to hinge on, so the port
 * keeps a cwd of its own. The linker redirects (--wrap) the path-taking libc
 * entry points the binary imports; a relative path is joined to that cwd
 * before the real call. Absolute paths pass through untouched.
 *
 * On a host where chdir() works this is behaviour-neutral. The native smoke
 * build links it too, so the shipping code path is exercised headlessly. */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include "srps4_platform.h"

#define SRPS4_PATH_MAX 1024

static char s_cwd[SRPS4_PATH_MAX];

/* Collapse "." and ".." segments of an absolute path in place. */
static void normalize(char *path) {
  char out[SRPS4_PATH_MAX];
  size_t n = 0;
  const char *p = path;
  out[0] = '\0';
  while (*p) {
    while (*p == '/') ++p;
    if (!*p) break;
    const char *seg = p;
    while (*p && *p != '/') ++p;
    size_t len = (size_t)(p - seg);
    if (len == 1 && seg[0] == '.') continue;
    if (len == 2 && seg[0] == '.' && seg[1] == '.') {
      while (n > 0 && out[n - 1] != '/') --n;
      if (n > 0) --n;
      out[n] = '\0';
      continue;
    }
    if (n + 1 + len >= sizeof(out)) break;
    out[n++] = '/';
    memcpy(out + n, seg, len);
    n += len;
    out[n] = '\0';
  }
  if (n == 0) { out[0] = '/'; out[1] = '\0'; }
  memcpy(path, out, strlen(out) + 1);
}

static const char *resolve(const char *path, char *buf) {
  if (!path || !*path || path[0] == '/') return path;
  const char *base = s_cwd[0] ? s_cwd : srps4_data_dir();
  if (!base || !*base) return path;
  if (snprintf(buf, SRPS4_PATH_MAX, "%s/%s", base, path) >= SRPS4_PATH_MAX) return path;
  normalize(buf);
  return buf;
}

void srps4_paths_init(const char *cwd) {
  snprintf(s_cwd, sizeof(s_cwd), "%s", cwd);
  normalize(s_cwd);
}

int __real_open(const char *path, int flags, ...);
int __wrap_open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  char b[SRPS4_PATH_MAX];
  return __real_open(resolve(path, b), flags, mode);
}

int __real_stat(const char *path, struct stat *st);
int __wrap_stat(const char *path, struct stat *st) {
  char b[SRPS4_PATH_MAX];
  return __real_stat(resolve(path, b), st);
}

int __real_lstat(const char *path, struct stat *st);
int __wrap_lstat(const char *path, struct stat *st) {
  char b[SRPS4_PATH_MAX];
  return __real_lstat(resolve(path, b), st);
}

int __real_mkdir(const char *path, mode_t mode);
int __wrap_mkdir(const char *path, mode_t mode) {
  char b[SRPS4_PATH_MAX];
  return __real_mkdir(resolve(path, b), mode);
}

int __real_rename(const char *from, const char *to);
int __wrap_rename(const char *from, const char *to) {
  char a[SRPS4_PATH_MAX], b[SRPS4_PATH_MAX];
  return __real_rename(resolve(from, a), resolve(to, b));
}

int __real_unlink(const char *path);
int __wrap_unlink(const char *path) {
  char b[SRPS4_PATH_MAX];
  return __real_unlink(resolve(path, b));
}

int __real_rmdir(const char *path);
int __wrap_rmdir(const char *path) {
  char b[SRPS4_PATH_MAX];
  return __real_rmdir(resolve(path, b));
}

int __real_truncate(const char *path, off_t length);
int __wrap_truncate(const char *path, off_t length) {
  char b[SRPS4_PATH_MAX];
  return __real_truncate(resolve(path, b), length);
}

int __real_chdir(const char *path);
int __wrap_chdir(const char *path) {
  char b[SRPS4_PATH_MAX];
  const char *abs = resolve(path, b);
  struct stat st;
  if (!abs || __real_stat(abs, &st) != 0) return -1;      /* errno from stat */
  if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
  (void)__real_chdir(abs);   /* best effort; our own cwd is authoritative */
  srps4_paths_init(abs);
  return 0;
}

char *__real_getcwd(char *buf, size_t size);
char *__wrap_getcwd(char *buf, size_t size) {
  if (!s_cwd[0]) return __real_getcwd(buf, size);
  size_t len = strlen(s_cwd);
  if (!buf) {                       /* POSIX extension: allocate */
    buf = (char *)malloc(len + 1);
    if (!buf) { errno = ENOMEM; return NULL; }
    memcpy(buf, s_cwd, len + 1);
    return buf;
  }
  if (size <= len) { errno = ERANGE; return NULL; }
  memcpy(buf, s_cwd, len + 1);
  return buf;
}
