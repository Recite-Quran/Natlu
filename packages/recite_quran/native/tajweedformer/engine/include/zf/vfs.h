#ifndef ZF_VFS_H
#define ZF_VFS_H

/* In-memory files. A caller that holds a model's files in memory (rebuilt from a CoreML package and
 * its sidecar, see zf/zfs.h) registers them under the path the engine would open, and every loader
 * looks here before the file system. The table takes ownership of the bytes; loaders copy them. */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Register `data` (malloc'd, `size` bytes, owned by the table from now on) under `path`, replacing
 * any earlier entry. Returns 1, or 0 if out of memory (the data is freed either way on failure). */
int zf_vfs_put(const char *path, unsigned char *data, size_t size);

/* A copy of the file, malloc'd with one extra NUL byte after `size` bytes, or NULL if not registered. */
unsigned char *zf_vfs_copy(const char *path, size_t *size);

/* Drop every entry whose path starts with `prefix`. */
void zf_vfs_remove_prefix(const char *prefix);

#ifdef __cplusplus
}
#endif
#endif
