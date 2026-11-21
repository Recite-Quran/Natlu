/* The in-memory file table (zf/vfs.h): what a caller registers is what a loader reads.
 *
 * The web SDK has no file system and the Apple SDK rebuilds the engine's files in memory, so both
 * hand the engine its model through this table. Checked: a copy is the registered bytes with one NUL
 * after them, a second put under the same path replaces the first, an unknown path is NULL, and
 * remove_prefix drops exactly the paths that start with the prefix. */
#include <stdlib.h>
#include <string.h>

#include "zf/vfs.h"
#include "zf_test.h"

static unsigned char *bytes(const char *s, size_t n) {
  unsigned char *p = (unsigned char *)malloc(n ? n : 1);
  if (p && n) memcpy(p, s, n);
  return p;
}

int main(void) {
  size_t n = 99;
  CHECK(zf_vfs_copy("zfmem:/m/a.bin", &n) == NULL);

  CHECK(zf_vfs_put("zfmem:/m/a.bin", bytes("abc\0def", 7), 7) == 1);
  CHECK(zf_vfs_put("zfmem:/m/b.bin", bytes("", 0), 0) == 1);
  CHECK(zf_vfs_put("zfmem:/n/a.bin", bytes("other", 5), 5) == 1);

  unsigned char *c = zf_vfs_copy("zfmem:/m/a.bin", &n);
  CHECK(c != NULL && n == 7);
  if (c) CHECK(!memcmp(c, "abc\0def", 7) && c[7] == 0);
  free(c);

  n = 99;
  c = zf_vfs_copy("zfmem:/m/b.bin", &n);
  CHECK(c != NULL && n == 0);
  if (c) CHECK(c[0] == 0);
  free(c);

  /* the size pointer is optional */
  c = zf_vfs_copy("zfmem:/n/a.bin", NULL);
  CHECK(c != NULL);
  if (c) CHECK(!memcmp(c, "other", 6));
  free(c);

  /* a second put replaces the first */
  CHECK(zf_vfs_put("zfmem:/m/a.bin", bytes("xy", 2), 2) == 1);
  c = zf_vfs_copy("zfmem:/m/a.bin", &n);
  CHECK(c != NULL && n == 2);
  if (c) CHECK(!memcmp(c, "xy", 3));
  free(c);

  /* a path is matched whole, not by prefix */
  CHECK(zf_vfs_copy("zfmem:/m/a", &n) == NULL);
  CHECK(zf_vfs_copy("zfmem:/m/a.bin2", &n) == NULL);

  zf_vfs_remove_prefix("zfmem:/m/");
  CHECK(zf_vfs_copy("zfmem:/m/a.bin", &n) == NULL);
  CHECK(zf_vfs_copy("zfmem:/m/b.bin", &n) == NULL);
  c = zf_vfs_copy("zfmem:/n/a.bin", &n);
  CHECK(c != NULL && n == 5);
  free(c);

  zf_vfs_remove_prefix("zfmem:/");
  CHECK(zf_vfs_copy("zfmem:/n/a.bin", &n) == NULL);
  return zf_test_done("vfs");
}
