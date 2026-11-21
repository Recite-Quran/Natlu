#ifndef ZF_ZFS_H
#define ZF_ZFS_H

/* One weight file for both engines.
 *
 * The CoreML model's compiled weights (weights/weight.bin of the .mlmodelc) hold the network's
 * linear weights in fp16. The exact engine's int8 weights are those values requantised with each
 * tensor's scale, except for about 0.3% of codes that land one step off the published int8; the
 * sidecar (engine.zfs, written by tajweedformer-coreml's oneweight/zfs_pack.py; V4: oneweight/split_int8.py) lists those corrections
 * and holds everything else the engine needs. Every rebuilt file is checked against its SHA-256; a
 * file that does not match is refused, never used. */

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Rebuild the engine's files from `weight_bin` and the sidecar `zfs` and register each under
 * `prefix` + "/" + its name in the in-memory file table (zf/vfs.h). Returns the number of files, or
 * -1 with `*error` set to a static message. */
int zf_zfs_materialize(const unsigned char *weight_bin, size_t weight_len, const unsigned char *zfs,
                       size_t zfs_len, const char *prefix, const char **error);

/* The SHA-256 the sidecar records for file `name` (every rebuilt file is checked against it).
 * Returns 0, or -1 if the sidecar has no such file. */
int zf_zfs_file_digest(const unsigned char *zfs, size_t zfs_len, const char *name, unsigned char out[32]);

/* Version 2 sidecars (V4) may also take a tensor's int8 rows straight from an int8 CoreML build
 * (constexpr_affine_dequantize data in weight.bin), so the engine's int8 weights are the CoreML
 * weights themselves and the sidecar holds only what CoreML cannot supply. Both versions load here.
 *
 * Rebuild every file the sidecar lists, check each against its SHA-256, and write it to
 * `out_dir` + "/" + its name (names may contain '/': parent folders are created; each file is written
 * to "<name>.part" and renamed, so a file under its own name is always complete). Files are rebuilt
 * and written one at a time: peak memory is one file. Returns the number of files, or -1 with
 * `*error` set to a static message (files written before the failure stay; they are checked). */
int zf_zfs_write_files(const unsigned char *weight_bin, size_t weight_len, const unsigned char *zfs,
                       size_t zfs_len, const char *out_dir, const char **error);

/* How many files the sidecar rebuilds, or -1 if it is not one. */
int zf_zfs_file_count(const unsigned char *zfs, size_t zfs_len);

/* The index-th file's name (NUL-terminated, at most name_cap - 1 bytes) and, if sha256_out is not
 * NULL, its SHA-256. Returns 0, or -1. */
int zf_zfs_file_name(const unsigned char *zfs, size_t zfs_len, int index, char *name_out, size_t name_cap,
                     unsigned char sha256_out[32]);

#ifdef __cplusplus
}
#endif
#endif
