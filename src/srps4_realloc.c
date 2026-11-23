/* srps4_realloc.c — never let musl copy a shrinking mmapped block.
 *
 * PacBrew's musl (1.2.0, oldmalloc) serves blocks above MMAP_THRESHOLD
 * (~224 KiB) with their own mmap. realloc() resizes those with mremap(), which
 * PS4 does not have (__mremap always fails there), so it falls back to
 * "malloc new, copy, free old". The copy length is the OLD chunk size: for a
 * shrink that writes past the end of the smaller new block and corrupts the
 * next heap chunk. segagenesisrecomp's rewind ring shrinks its snapshot buffer
 * whenever a snapshot gets more than 4 KiB smaller; Sonic 3 & Knuckles did so
 * on entering a special stage, and the next malloc crashed on the damaged
 * free list (found under shadPS4 with a hardware watchpoint on the word).
 *
 * Shrinks (and same-size calls) now return the block unchanged, which is a
 * valid realloc result; growth and realloc(NULL, n) / realloc(p, 0) still go
 * to musl, whose growth paths copy the smaller old size and are correct.
 * Linked with --wrap=realloc on the console. */
#include <malloc.h>
#include <stdlib.h>

#if SRPS4_CONSOLE
void *__real_realloc(void *p, size_t n);

void *__wrap_realloc(void *p, size_t n) {
  if (p && n && n <= malloc_usable_size(p)) return p;
  return __real_realloc(p, n);
}
#endif
