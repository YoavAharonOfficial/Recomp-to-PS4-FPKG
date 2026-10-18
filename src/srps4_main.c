/* srps4_main.c — process entry for snesrecomp titles on PS4 (and the native
 * smoke-test build of the same code path).
 *
 * The desktop host (runner/src/desktop/host_main.c) treats "the directory
 * beside the executable" as the home of config.ini, saves, mods and the ROM.
 * On PS4 the package mount (/app0) is read-only, so the port gives the host a
 * writable stand-in: /data/<title>/. On first run (and whenever the package
 * version changes) the read-only defaults shipped in /app0 are copied there;
 * anything the player has since edited (config.ini, keybinds.ini, saves, mod
 * state) is never overwritten.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <unistd.h>

#include "srps4_platform.h"

#if SRPS4_CONSOLE
#include <orbis/libkernel.h>
#include <orbis/UserService.h>
#include <orbis/SystemService.h>
#endif

#ifndef SRPS4_DATA_DIR
#  error "SRPS4_DATA_DIR must be defined by the game profile"
#endif

int SRPS4_GAME_ENTRY(int argc, char **argv);

static char s_data_dir[512];
static char s_pkg_dir[512];

const char *srps4_data_dir(void) { return s_data_dir; }
const char *srps4_pkg_dir(void) { return s_pkg_dir; }

/* Every message also goes to the kernel log, so GoldHEN's klog (port 3232)
 * shows a live trace without the player having to fetch a file. */
void srps4_log(const char *fmt, ...) {
  char buf[1024];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
#if SRPS4_CONSOLE
  sceKernelDebugOutText(0, "[srps4] ");
  sceKernelDebugOutText(0, buf);
  sceKernelDebugOutText(0, "\n");
#endif
  fprintf(stderr, "[srps4] %s\n", buf);
  fflush(stderr);
}

static int mkdir_p(const char *path) {
  char tmp[512];
  snprintf(tmp, sizeof(tmp), "%s", path);
  for (char *p = tmp + 1; *p; ++p) {
    if (*p != '/') continue;
    *p = '\0';
    if (mkdir(tmp, 0777) != 0 && errno != EEXIST) return -1;
    *p = '/';
  }
  if (mkdir(tmp, 0777) != 0 && errno != EEXIST) return -1;
  return 0;
}

static int file_exists(const char *path) {
  struct stat st;
  return stat(path, &st) == 0;
}

static int is_dir(const char *path) {
  struct stat st;
  return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int copy_file(const char *src, const char *dst) {
  FILE *in = fopen(src, "rb");
  if (!in) return -1;
  char tmp[600];
  snprintf(tmp, sizeof(tmp), "%s.part", dst);
  FILE *out = fopen(tmp, "wb");
  if (!out) { fclose(in); return -1; }
  static char buf[1 << 16];
  size_t n;
  int failed = 0;
  while ((n = fread(buf, 1, sizeof(buf), in)) > 0)
    if (fwrite(buf, 1, n, out) != n) { failed = 1; break; }
  if (ferror(in)) failed = 1;
  fclose(in);
  if (fclose(out) != 0) failed = 1;
  if (failed) { remove(tmp); return -1; }
  remove(dst);
  if (rename(tmp, dst) != 0) { remove(tmp); return -1; }
  return 0;
}

/* Copy a tree. `overwrite` refreshes files that ship with the package (mod
 * code, shader presets); player-owned files are copied only when missing. */
static void copy_tree(const char *src, const char *dst, int overwrite) {
  DIR *d = opendir(src);
  if (!d) return;
  mkdir_p(dst);
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    char s[512], t[512];
    snprintf(s, sizeof(s), "%s/%s", src, e->d_name);
    snprintf(t, sizeof(t), "%s/%s", dst, e->d_name);
    if (is_dir(s)) {
      copy_tree(s, t, overwrite);
    } else if (overwrite || !file_exists(t)) {
      if (copy_file(s, t) != 0) srps4_log("copy failed: %s -> %s", s, t);
    }
  }
  closedir(d);
}

static void read_small(const char *path, char *out, size_t cap) {
  out[0] = '\0';
  FILE *f = fopen(path, "rb");
  if (!f) return;
  size_t n = fread(out, 1, cap - 1, f);
  while (n > 0 && (out[n - 1] == '\n' || out[n - 1] == '\r' || out[n - 1] == ' ')) --n;
  out[n] = '\0';
  fclose(f);
}

/* /app0/srps4/defaults/ mirrors the data dir: files under it seed the data
 * dir once; files under /app0/srps4/refresh/ are re-synced on every package
 * version change (they are code-adjacent: mod packages, shader presets). */
static void provision_data_dir(void) {
  char stamp_pkg[600], stamp_data[600], ver_pkg[64], ver_data[64];
  snprintf(stamp_pkg, sizeof(stamp_pkg), "%s/srps4/version.txt", s_pkg_dir);
  snprintf(stamp_data, sizeof(stamp_data), "%s/.srps4_version", s_data_dir);
  read_small(stamp_pkg, ver_pkg, sizeof(ver_pkg));
  read_small(stamp_data, ver_data, sizeof(ver_data));
  int upgraded = strcmp(ver_pkg, ver_data) != 0;

  char src[600];
  snprintf(src, sizeof(src), "%s/srps4/defaults", s_pkg_dir);
  copy_tree(src, s_data_dir, 0);
  if (upgraded) {
    snprintf(src, sizeof(src), "%s/srps4/refresh", s_pkg_dir);
    copy_tree(src, s_data_dir, 1);
    FILE *f = fopen(stamp_data, "wb");
    if (f) { fputs(ver_pkg, f); fclose(f); }
    srps4_log("data dir provisioned for package version '%s' (was '%s')",
              ver_pkg, ver_data[0] ? ver_data : "none");
  }
}

/* Optional /data/<Title>/srps4_env.txt: KEY=VALUE lines applied with
 * setenv() before the game starts. The console offers no other way to set
 * the host's diagnostic/tuning knobs (e.g. SNESRECOMP_RENDER_WORKERS=1). */
static void apply_env_file(void) {
  char path[600], line[512];
  snprintf(path, sizeof(path), "%s/srps4_env.txt", s_data_dir);
  FILE *f = fopen(path, "r");
  if (!f) return;
  while (fgets(line, sizeof(line), f)) {
    char *p = line;
    while (*p == ' ' || *p == '\t') ++p;
    if (*p == '#' || *p == ';' || *p == '\n' || *p == '\r' || !*p) continue;
    size_t n = strlen(p);
    while (n && (p[n - 1] == '\n' || p[n - 1] == '\r' || p[n - 1] == ' ')) p[--n] = '\0';
    char *eq = strchr(p, '=');
    if (!eq || eq == p) continue;
    *eq = '\0';
    setenv(p, eq + 1, 1);
    srps4_log("env: %s=%s", p, eq + 1);
  }
  fclose(f);
}

static void redirect_stdio(void) {
  char log_path[600];
  snprintf(log_path, sizeof(log_path), "%s/logs", s_data_dir);
  mkdir_p(log_path);
  snprintf(log_path, sizeof(log_path), "%s/logs/last_run.txt", s_data_dir);
  /* stderr carries the host's breadcrumbs; keep the most recent run only.
   * Truncate once, then open both streams O_APPEND so their writes
   * interleave at the end instead of overwriting each other. */
  FILE *trunc = fopen(log_path, "w");
  if (trunc) fclose(trunc);
  if (freopen(log_path, "a", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
  if (freopen(log_path, "a", stdout)) setvbuf(stdout, NULL, _IOLBF, 0);
}

int main(int argc, char **argv) {
#if SRPS4_CONSOLE
  snprintf(s_pkg_dir, sizeof(s_pkg_dir), "/app0");
  snprintf(s_data_dir, sizeof(s_data_dir), "/data/%s", SRPS4_DATA_DIR);
  /* SDL's PS4 video init (PS4_LoadModules) loads the system/user/pad/audio
   * modules, initialises the user service and hides the splash screen; doing
   * any of that here first would make SDL's own calls fail. */
#else
  /* Native smoke test: package = SRPS4_PKG_DIR env (staged tree), data dir =
   * SRPS4_DATA_ROOT env or ./srps4-data. Same provisioning logic. */
  const char *pkg = getenv("SRPS4_PKG_DIR");
  const char *root = getenv("SRPS4_DATA_ROOT");
  snprintf(s_pkg_dir, sizeof(s_pkg_dir), "%s", pkg ? pkg : ".");
  snprintf(s_data_dir, sizeof(s_data_dir), "%s/%s", root ? root : "./srps4-data",
           SRPS4_DATA_DIR);
#endif
  if (mkdir_p(s_data_dir) != 0) {
    srps4_log("cannot create %s (errno %d)", s_data_dir, errno);
  }
#if SRPS4_CONSOLE
  redirect_stdio();
#endif
  srps4_log("%s starting; package=%s data=%s", SRPS4_TITLE, s_pkg_dir, s_data_dir);
  provision_data_dir();
  /* Relative I/O resolves against the data dir via srps4_paths.c whether or
   * not the kernel honours chdir(); the real chdir is still attempted. */
  srps4_paths_init(s_data_dir);
  if (chdir(s_data_dir) != 0) srps4_log("chdir(%s) failed (errno %d)", s_data_dir, errno);

  apply_env_file();

  /* The console has no keyboard or launcher; boot straight into the game. */
  setenv("SNESRECOMP_NO_LAUNCHER", "1", 1);
  /* Diagnostics recording is for desktop bug reports; on a console it would
   * only spend the hard drive and frame time. */
  setenv("MMX_REPLAY_RECORD", "0", 1);

  /* Fake argv[0] inside the data dir: the host derives its "exe dir" from it
   * where /proc/self/exe does not exist. */
  static char exe0[600];
  snprintf(exe0, sizeof(exe0), "%s/eboot.bin", s_data_dir);
  static char *fake_argv[64];
  int n = 0;
  fake_argv[n++] = exe0;
  for (int i = 1; i < argc && n < 63; ++i) fake_argv[n++] = argv[i];
  /* Test hook: SRPS4_EXTRA_ARGS="--script intro.script" (emulators and the
   * native smoke test can pass environment variables but not always argv). */
  static char extra[512];
  const char *ea = getenv("SRPS4_EXTRA_ARGS");
  if (ea && *ea) {
    snprintf(extra, sizeof(extra), "%s", ea);
    for (char *tok = strtok(extra, " "); tok && n < 63; tok = strtok(NULL, " "))
      fake_argv[n++] = tok;
  }
  fake_argv[n] = NULL;

  int rc = SRPS4_GAME_ENTRY(n, fake_argv);
  srps4_log("%s exited with %d", SRPS4_TITLE, rc);
#if SRPS4_CONSOLE
  /* Returning from main on PS4 leaves a frozen black screen; ask the shell to
   * close the app cleanly instead. */
  fflush(stdout);
  fflush(stderr);
  sceSystemServiceLoadExec("exit", NULL);
#endif
  return rc;
}
