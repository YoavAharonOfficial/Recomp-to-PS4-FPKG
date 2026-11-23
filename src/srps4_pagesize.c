/* srps4_pagesize.c — sysconf() names from musl's numbering to libkernel's.
 *
 * sysconf is not musl's here: the link resolves it to libkernel's export,
 * which follows FreeBSD's _SC_* numbering, while titles are compiled against
 * musl's <unistd.h> (Linux numbering). musl's _SC_PAGESIZE is 30; libkernel
 * read that as a different name and answered 4096. The console's pages are
 * 16 KiB, so a guard page placed by that answer covers more than asked:
 * segagenesisrecomp put its fiber guard at offset 4 KiB, the kernel rounded
 * the range down to offset 0, the fiber header became PROT_NONE, and the
 * first write to it crashed on real hardware. (shadPS4 answers 16384 for any
 * name, so the emulator hid this.)
 *
 * Linked with --wrap=sysconf on the console. Names without a mapping here
 * fail with EINVAL rather than return an answer to a different question. */
#include <errno.h>
#include <unistd.h>

#if SRPS4_CONSOLE
long __real_sysconf(int name);

/* FreeBSD <sys/unistd.h> values, as libkernel numbers them. */
enum {
  BSD_SC_ARG_MAX = 1, BSD_SC_CHILD_MAX = 2, BSD_SC_CLK_TCK = 3,
  BSD_SC_NGROUPS_MAX = 4, BSD_SC_OPEN_MAX = 5, BSD_SC_PAGESIZE = 47,
  BSD_SC_NPROCESSORS_CONF = 57, BSD_SC_NPROCESSORS_ONLN = 58,
};
#define SRPS4_PAGE_SIZE 16384L

long __wrap_sysconf(int name) {
  long v;
  switch (name) {
  case _SC_PAGESIZE:                 /* musl 30 */
    v = __real_sysconf(BSD_SC_PAGESIZE);
    return v >= SRPS4_PAGE_SIZE ? v : SRPS4_PAGE_SIZE;
  case _SC_NPROCESSORS_CONF:         /* musl 83 */
  case _SC_NPROCESSORS_ONLN:         /* musl 84 */
    v = __real_sysconf(name == _SC_NPROCESSORS_CONF ? BSD_SC_NPROCESSORS_CONF
                                                    : BSD_SC_NPROCESSORS_ONLN);
    return v > 0 ? v : 6;            /* a game owns six of the eight cores */
  case _SC_CLK_TCK:     return __real_sysconf(BSD_SC_CLK_TCK);
  case _SC_OPEN_MAX:    return __real_sysconf(BSD_SC_OPEN_MAX);
  case _SC_ARG_MAX:     return __real_sysconf(BSD_SC_ARG_MAX);
  case _SC_CHILD_MAX:   return __real_sysconf(BSD_SC_CHILD_MAX);
  case _SC_NGROUPS_MAX: return __real_sysconf(BSD_SC_NGROUPS_MAX);
  default:
    errno = EINVAL;
    return -1;
  }
}
#endif
