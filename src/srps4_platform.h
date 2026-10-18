/* srps4_platform.h — services the PS4 port layer exposes to patched
 * snesrecomp code (all patches are guarded by #if SRPS4). */
#ifndef SRPS4_PLATFORM_H
#define SRPS4_PLATFORM_H
#ifdef __cplusplus
extern "C" {
#endif
/* Writable per-title directory that stands in for "beside the executable". */
const char *srps4_data_dir(void);
/* Read-only package mount (/app0 on PS4). */
const char *srps4_pkg_dir(void);
void srps4_log(const char *fmt, ...);
/* Set the port's own working directory (see srps4_paths.c). */
void srps4_paths_init(const char *cwd);
#ifdef __cplusplus
}
#endif
#endif
