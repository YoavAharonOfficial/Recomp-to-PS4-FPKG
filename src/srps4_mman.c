/* srps4_mman.c — musl (Linux) mmap/sysconf constants -> libkernel (FreeBSD).
 *
 * PacBrew's musl declares Linux values for <sys/mman.h> and <unistd.h>, but on
 * the PS4 mmap() and sysconf() resolve to libkernel, which follows FreeBSD.
 * The same class of mismatch as the clock ids (srps4_time.c):
 *
 *   - MAP_ANONYMOUS is 0x20 on Linux and 0x1000 on FreeBSD (0x20 there is a
 *     reserved bit), so an anonymous mapping turned into a file mapping of
 *     fd -1 and failed. Genesis titles allocate their game-fiber stacks this
 *     way (segagenesisrecomp runner/fiber_compat.c).
 *   - sysconf(_SC_PAGESIZE) is 30 on Linux and 47 on FreeBSD; 30 asks
 *     libkernel for something else entirely. The PS4's pages are 16 KiB, and
 *     a guard page placed at a 4 KiB boundary cannot be protected.
 *
 * Linked with --wrap=mmap --wrap=sysconf on the console only. */
#include <errno.h>
#include <stddef.h>
#include <sys/types.h>

#if SRPS4_CONSOLE
void *__real_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
long __real_sysconf(int name);

enum {
  LX_MAP_SHARED = 0x01, LX_MAP_PRIVATE = 0x02, LX_MAP_FIXED = 0x10,
  LX_MAP_ANON = 0x20, LX_MAP_STACK = 0x20000,
  BSD_MAP_ANON = 0x1000, BSD_MAP_STACK = 0x400,
};

void *__wrap_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
  int bsd = flags & (LX_MAP_SHARED | LX_MAP_PRIVATE | LX_MAP_FIXED);
  if (flags & LX_MAP_ANON) bsd |= BSD_MAP_ANON;
  if (flags & LX_MAP_STACK) bsd |= BSD_MAP_STACK;
  /* MAP_NORESERVE, MAP_POPULATE, MAP_GROWSDOWN, MAP_LOCKED: hints only. */
  return __real_mmap(addr, len, prot, bsd, fd, off);
}

long __wrap_sysconf(int name) {
  long v;
  switch (name) {
  case 30:                          /* _SC_PAGESIZE -> FreeBSD 47 */
    v = __real_sysconf(47);
    return v > 0 ? v : 16384;
  case 83: case 84:                 /* _SC_NPROCESSORS_CONF/ONLN -> 57/58 */
    v = __real_sysconf(name == 83 ? 57 : 58);
    return v > 0 ? v : 6;           /* cores 0-5 belong to the game */
  case 2:                           /* _SC_CLK_TCK -> 3 */
    return __real_sysconf(3);
  case 4:                           /* _SC_OPEN_MAX -> 5 */
    return __real_sysconf(5);
  default:
    errno = EINVAL;                 /* unmapped: refuse rather than misanswer */
    return -1;
  }
}
#endif
