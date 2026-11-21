/* zf_zfs_materialize: see zf/zfs.h. The format is documented in tajweedformer-coreml's zfs_pack.py. */
#include "zf/zfs.h"

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zf/sha256.h"
#include "zf/vfs.h"

#ifdef _WIN32
#include <direct.h>
#define ZF_MKDIR(p) _mkdir(p)
#else
#include <sys/stat.h>
#define ZF_MKDIR(p) mkdir(p, 0755)
#endif

#define UNIT 4 /* the pairing layout: 4 output units by 16 k, as tools/zfgraph.pack_weights */
#define KG 16

typedef struct {
  const unsigned char *p, *end;
  int bad;
} Reader;

static uint64_t rd(Reader *r, int bytes) {
  if (r->p + bytes > r->end) {
    r->bad = 1;
    return 0;
  }
  uint64_t v = 0;
  for (int i = 0; i < bytes; ++i) v |= (uint64_t)r->p[i] << (8 * i);
  r->p += bytes;
  return v;
}

static float rd_f32(Reader *r) {
  const uint32_t u = (uint32_t)rd(r, 4);
  float f;
  memcpy(&f, &u, 4);
  return f;
}

/* IEEE half to single, exactly (every half is representable) */
static float half_to_float(uint16_t h) {
  const uint32_t sign = (uint32_t)(h >> 15) << 31;
  uint32_t exp = (h >> 10) & 0x1f, man = h & 0x3ff, bits;
  if (exp == 0) {
    if (man == 0) {
      bits = sign;
    } else { /* subnormal: normalise */
      int e = -1;
      do {
        ++e;
        man <<= 1;
      } while (!(man & 0x400));
      bits = sign | (uint32_t)(127 - 15 - e) << 23 | (man & 0x3ff) << 13;
    }
  } else if (exp == 31) {
    bits = sign | 0x7f800000u | man << 13;
  } else {
    bits = sign | (exp + 127 - 15) << 23 | man << 13;
  }
  float f;
  memcpy(&f, &bits, 4);
  return f;
}

typedef struct {
  int kind;
  uint64_t dst, len;
  uint64_t side_off;                   /* SIDE */
  uint64_t woff, coff, clen;           /* REQUANT and INT8 */
  uint32_t n, k;
  float scale;                         /* REQUANT */
  uint32_t of;                         /* ROWSUMS */
  int32_t *rowsums;                    /* filled by REQUANT for ROWSUMS */
} Entry;

/* rows [n,k] from the weights (kind 1: fp16 requantised with the scale; kind 3: int8 copied), corrected,
 * packed in the pairing layout into `dst` (np*kp bytes) with the row sums of the padded rows into `rs` (np
 * entries) */
static int requant(const Entry *e, const unsigned char *w, size_t wlen, const unsigned char *corr,
                   size_t corr_len, unsigned char *dst, int32_t *rs) {
  const size_t n = e->n, k = e->k, kp = (k + KG - 1) / KG * KG, np = (n + UNIT - 1) / UNIT * UNIT;
  const size_t elem = e->kind == 3 ? 1 : 2;
  if (n == 0 || k == 0 || e->woff > wlen || n * k * elem > wlen - e->woff || e->len != np * kp) return 0;
  int8_t *rows = (int8_t *)calloc(np * kp, 1);
  if (!rows) return 0;
  const unsigned char *src = w + e->woff;
  if (e->kind == 3) {
    for (size_t i = 0; i < n; ++i) memcpy(rows + i * kp, src + i * k, k);
  } else {
    for (size_t i = 0; i < n; ++i)
      for (size_t j = 0; j < k; ++j) {
        const size_t t = i * k + j;
        const float v = half_to_float((uint16_t)(src[2 * t] | src[2 * t + 1] << 8));
        float q = nearbyintf(v / e->scale); /* IEEE division, then round half to even */
        if (q < -128.0f) q = -128.0f;
        if (q > 127.0f) q = 127.0f;
        rows[i * kp + j] = (int8_t)q;
      }
  }
  /* corrections: varints of gap*2 + sign, indices into the unpadded [n,k] rows */
  long long at = -1;
  for (size_t p = 0; p < corr_len;) {
    uint64_t v = 0;
    int sh = 0;
    for (;;) {
      if (p >= corr_len || sh > 56) {
        free(rows);
        return 0;
      }
      const unsigned char b = corr[p++];
      v |= (uint64_t)(b & 0x7f) << sh;
      sh += 7;
      if (b < 0x80) break;
    }
    at += (long long)(v >> 1) + 1;
    if (at < 0 || (size_t)at >= n * k) {
      free(rows);
      return 0;
    }
    int8_t *c = &rows[((size_t)at / k) * kp + (size_t)at % k];
    const int nv = *c + ((v & 1) ? 1 : -1);
    if (nv < -128 || nv > 127) {
      free(rows);
      return 0;
    }
    *c = (int8_t)nv;
  }
  for (size_t i = 0; i < np; ++i) {
    int32_t s = 0;
    for (size_t j = 0; j < kp; ++j) s += rows[i * kp + j];
    rs[i] = s;
  }
  const size_t groups = kp / KG;
  for (size_t b = 0; b < np / UNIT; ++b)
    for (size_t g = 0; g < groups; ++g)
      for (size_t u = 0; u < UNIT; ++u)
        memcpy(dst + ((b * groups + g) * UNIT + u) * KG, rows + (b * UNIT + u) * kp + g * KG, KG);
  free(rows);
  return 1;
}

/* Called with each rebuilt and checked file; owns `buf` (malloc'd, size + 1 bytes) from then on, also on
 * failure. Returns 0, or -1 with `*error` set. */
typedef int (*EmitFn)(void *user, const char *name, unsigned char *buf, size_t size, const char **error);

static int rebuild(const unsigned char *weight_bin, size_t weight_len, const unsigned char *zfs, size_t zfs_len,
                   EmitFn emit, void *user, const char **error) {
  Reader r = {zfs, zfs + zfs_len, 0};
  if (zfs_len < 28 || memcmp(zfs, "ZFS1", 4) != 0) {
    if (error) *error = "not an engine sidecar (ZFS1)";
    return -1;
  }
  r.p += 4;
  const uint32_t version = (uint32_t)rd(&r, 4), n_files = (uint32_t)rd(&r, 4);
  const uint64_t side_off = rd(&r, 8), side_len = rd(&r, 8);
  if ((version != 1 && version != 2) || side_off > zfs_len || side_len > zfs_len - side_off || n_files > 64) {
    if (error) *error = "unsupported or damaged engine sidecar";
    return -1;
  }
  const unsigned char *side = zfs + side_off;
  for (uint32_t f = 0; f < n_files; ++f) {
    const uint32_t name_len = (uint32_t)rd(&r, 4);
    char name[256];
    if (r.bad || name_len == 0 || name_len >= sizeof name || r.p + name_len > r.end) goto damaged;
    memcpy(name, r.p, name_len);
    name[name_len] = 0;
    r.p += name_len;
    const uint64_t size = rd(&r, 8);
    unsigned char want[32];
    if (r.p + 32 > r.end) goto damaged;
    memcpy(want, r.p, 32);
    r.p += 32;
    const uint32_t n_ent = (uint32_t)rd(&r, 4);
    if (r.bad || n_ent > 100000) goto damaged;
    Entry *ents = (Entry *)calloc(n_ent ? n_ent : 1, sizeof(Entry));
    unsigned char *buf = (unsigned char *)calloc(size + 1, 1);
    if (!ents || !buf) {
      free(ents);
      free(buf);
      if (error) *error = "out of memory";
      return -1;
    }
    int ok = 1;
    for (uint32_t i = 0; i < n_ent && ok; ++i) {
      Entry *e = &ents[i];
      e->kind = (int)rd(&r, 1);
      e->dst = rd(&r, 8);
      e->len = rd(&r, 8);
      if (e->kind == 0) {
        e->side_off = rd(&r, 8);
      } else if (e->kind == 1) {
        e->woff = rd(&r, 8);
        e->n = (uint32_t)rd(&r, 4);
        e->k = (uint32_t)rd(&r, 4);
        e->scale = rd_f32(&r);
        e->coff = rd(&r, 8);
        e->clen = rd(&r, 8);
      } else if (e->kind == 2) {
        e->of = (uint32_t)rd(&r, 4);
      } else if (e->kind == 3 && version >= 2) {
        e->woff = rd(&r, 8);
        e->n = (uint32_t)rd(&r, 4);
        e->k = (uint32_t)rd(&r, 4);
        e->coff = rd(&r, 8);
        e->clen = rd(&r, 8);
      } else {
        ok = 0;
      }
      if (r.bad || e->dst > size || e->len > size - e->dst) ok = 0;
    }
    for (uint32_t i = 0; i < n_ent && ok; ++i) { /* sources first, row sums after */
      Entry *e = &ents[i];
      if (e->kind == 0) {
        if (e->side_off > side_len || e->len > side_len - e->side_off) ok = 0;
        else memcpy(buf + e->dst, side + e->side_off, e->len);
      } else if (e->kind == 1 || e->kind == 3) {
        const size_t np = ((size_t)e->n + UNIT - 1) / UNIT * UNIT;
        e->rowsums = (int32_t *)malloc(np * sizeof(int32_t));
        if (!e->rowsums || e->coff > side_len || e->clen > side_len - e->coff ||
            !requant(e, weight_bin, weight_len, side + e->coff, e->clen, buf + e->dst, e->rowsums))
          ok = 0;
      }
    }
    for (uint32_t i = 0; i < n_ent && ok; ++i) {
      Entry *e = &ents[i];
      if (e->kind != 2) continue;
      if (e->of >= n_ent || (ents[e->of].kind != 1 && ents[e->of].kind != 3)) {
        ok = 0;
        break;
      }
      const size_t np = ((size_t)ents[e->of].n + UNIT - 1) / UNIT * UNIT;
      if (e->len != np * 4) {
        ok = 0;
        break;
      }
      for (size_t j = 0; j < np; ++j) { /* little endian int32, as the file stores it */
        const uint32_t v = (uint32_t)ents[e->of].rowsums[j];
        for (int b = 0; b < 4; ++b) buf[e->dst + 4 * j + b] = (unsigned char)(v >> (8 * b));
      }
    }
    for (uint32_t i = 0; i < n_ent; ++i) free(ents[i].rowsums);
    free(ents);
    unsigned char got[32];
    if (ok) {
      zf_sha256(buf, size, got);
      if (memcmp(got, want, 32) != 0) {
        free(buf);
        if (error) *error = "a rebuilt engine file does not match its checksum: the weights and the sidecar do not belong together";
        return -1;
      }
    }
    if (!ok) {
      free(buf);
      goto damaged;
    }
    if (emit(user, name, buf, size, error) != 0) return -1;
  }
  return (int)n_files;
damaged:
  if (error) *error = "damaged engine sidecar";
  return -1;
}

static int emit_vfs(void *user, const char *name, unsigned char *buf, size_t size, const char **error) {
  char path[1024];
  snprintf(path, sizeof path, "%s/%s", (const char *)user, name);
  if (!zf_vfs_put(path, buf, size)) {
    if (error) *error = "out of memory";
    return -1;
  }
  return 0;
}

int zf_zfs_materialize(const unsigned char *weight_bin, size_t weight_len, const unsigned char *zfs,
                       size_t zfs_len, const char *prefix, const char **error) {
  return rebuild(weight_bin, weight_len, zfs, zfs_len, emit_vfs, (void *)prefix, error);
}

/* mkdir -p of every parent of `path` (not `path` itself) */
static int make_parents(char *path) {
  for (char *p = path + 1; *p; ++p) {
    if (*p != '/' && *p != '\\') continue;
    const char c = *p;
    *p = 0;
    const int rc = ZF_MKDIR(path);
    *p = c;
    if (rc != 0 && errno != EEXIST) return -1;
  }
  return 0;
}

static int emit_disk(void *user, const char *name, unsigned char *buf, size_t size, const char **error) {
  char path[2048], tmp[2100];
  if (strstr(name, "..") || name[0] == '/' || name[0] == '\\' || strchr(name, ':')) {
    free(buf); /* the sidecar names files inside out_dir only */
    if (error) *error = "the engine sidecar names a file outside the folder";
    return -1;
  }
  snprintf(path, sizeof path, "%s/%s", (const char *)user, name);
  snprintf(tmp, sizeof tmp, "%s.part", path);
  FILE *f = make_parents(path) == 0 ? fopen(tmp, "wb") : NULL;
  int ok = f && fwrite(buf, 1, size, f) == size;
  if (f && fclose(f) != 0) ok = 0;
  free(buf);
  if (ok) {
    remove(path); /* rename does not replace an existing file on Windows */
    ok = rename(tmp, path) == 0;
  }
  if (!ok) {
    remove(tmp);
    if (error) *error = "cannot write a rebuilt engine file";
    return -1;
  }
  return 0;
}

int zf_zfs_write_files(const unsigned char *weight_bin, size_t weight_len, const unsigned char *zfs,
                       size_t zfs_len, const char *out_dir, const char **error) {
  return rebuild(weight_bin, weight_len, zfs, zfs_len, emit_disk, (void *)out_dir, error);
}

/* the file named `name`, or (name NULL) the index-th; its name into name_out when given */
static int walk(const unsigned char *zfs, size_t zfs_len, const char *name, int index, char *name_out,
                size_t name_cap, unsigned char out[32]) {
  Reader r = {zfs, zfs + zfs_len, 0};
  if (zfs_len < 28 || memcmp(zfs, "ZFS1", 4) != 0) return -1;
  r.p += 4;
  const uint32_t version = (uint32_t)rd(&r, 4), n_files = (uint32_t)rd(&r, 4);
  rd(&r, 8);
  rd(&r, 8);
  if (version != 1 && version != 2) return -1;
  for (uint32_t f = 0; f < n_files && !r.bad; ++f) {
    const uint32_t name_len = (uint32_t)rd(&r, 4);
    if (r.bad || r.p + name_len + 8 + 32 > r.end) return -1;
    const int match = name ? strlen(name) == name_len && !memcmp(r.p, name, name_len) : (int)f == index;
    if (match && name_out) {
      if (name_len >= name_cap) return -1;
      memcpy(name_out, r.p, name_len);
      name_out[name_len] = 0;
    }
    r.p += name_len;
    rd(&r, 8);
    if (match) {
      memcpy(out, r.p, 32);
      return 0;
    }
    r.p += 32;
    const uint32_t n_ent = (uint32_t)rd(&r, 4);
    for (uint32_t i = 0; i < n_ent && !r.bad; ++i) {
      const int kind = (int)rd(&r, 1);
      rd(&r, 8);
      rd(&r, 8);
      if (kind == 0) rd(&r, 8);
      else if (kind == 1) { rd(&r, 8); rd(&r, 4); rd(&r, 4); rd(&r, 4); rd(&r, 8); rd(&r, 8); }
      else if (kind == 2) rd(&r, 4);
      else if (kind == 3 && version >= 2) { rd(&r, 8); rd(&r, 4); rd(&r, 4); rd(&r, 8); rd(&r, 8); }
      else return -1;
    }
  }
  return -1;
}

int zf_zfs_file_digest(const unsigned char *zfs, size_t zfs_len, const char *name, unsigned char out[32]) {
  return name ? walk(zfs, zfs_len, name, -1, NULL, 0, out) : -1;
}

int zf_zfs_file_count(const unsigned char *zfs, size_t zfs_len) {
  if (zfs_len < 28 || memcmp(zfs, "ZFS1", 4) != 0) return -1;
  Reader r = {zfs + 4, zfs + zfs_len, 0};
  const uint32_t version = (uint32_t)rd(&r, 4), n = (uint32_t)rd(&r, 4);
  return (version == 1 || version == 2) && n <= 64 ? (int)n : -1;
}

int zf_zfs_file_name(const unsigned char *zfs, size_t zfs_len, int index, char *name_out, size_t name_cap,
                     unsigned char sha256_out[32]) {
  unsigned char d[32];
  if (index < 0 || !name_out || name_cap == 0) return -1;
  if (walk(zfs, zfs_len, NULL, index, name_out, name_cap, d) != 0) return -1;
  if (sha256_out) memcpy(sha256_out, d, 32);
  return 0;
}
