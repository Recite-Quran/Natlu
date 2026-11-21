#ifndef ZF_SHA256_H
#define ZF_SHA256_H

#include <stddef.h>

/* SHA-256 of `n` bytes, into `out` (32 bytes). Portable C, no platform crypto. */
void zf_sha256(const void *data, size_t n, unsigned char out[32]);

#endif
