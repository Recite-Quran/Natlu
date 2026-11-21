#include "zf/zfw.h"
#include "zf/vfs.h"

#include "zf/conv.h"
#include "zf/dot.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zf/env.h"

/* POSIX (Android, Linux, Apple): the weight file is mapped, not read (see zf_weights_open) */
#if (defined(__unix__) || defined(__APPLE__)) && !defined(__EMSCRIPTEN__)
#define ZF_ZFW_MMAP 1
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#define ZFW_MAGIC "ZFW1"
#define ZFW_VERSION 1

struct ZfWeights {
  unsigned char *blob;
  size_t bytes;
  int count;
  ZfTensor *tensors;
  char *names;
  unsigned char *converted; /* one flag a tensor, so a layout change happens at most once */
  int mapped;               /* blob is a private file mapping (munmap), not malloc'd (free) */
};

static uint32_t read_u32(const unsigned char *p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int32_t read_i32(const unsigned char *p) { return (int32_t)read_u32(p); }

static void release_blob(unsigned char *blob, size_t size, int mapped) {
#if ZF_ZFW_MMAP
  if (mapped) {
    munmap(blob, size);
    return;
  }
#endif
  (void)size;
  (void)mapped;
  free(blob);
}

static ZfWeights *from_blob(unsigned char *blob, size_t size, int mapped, const char **error) {
  const char *why = "unknown";
  ZfWeights *w = (ZfWeights *)calloc(1, sizeof(ZfWeights));
  if (!w) {
    release_blob(blob, size, mapped);
    if (error) *error = "out of memory";
    return NULL;
  }
  w->blob = blob;
  w->mapped = mapped;
  w->bytes = size;
  if (size < 12) {
    why = "the weight file is too short";
    goto fail;
  }
  if (memcmp(blob, ZFW_MAGIC, 4) != 0) {
    why = "not a zfw file";
    goto fail;
  }
  if (read_u32(blob + 4) != ZFW_VERSION) {
    why = "unsupported zfw version";
    goto fail;
  }
  w->count = (int)read_u32(blob + 8);
  if (w->count < 0 || (size_t)w->count > (w->bytes / 32)) {
    why = "implausible tensor count";
    goto fail;
  }
  w->tensors = (ZfTensor *)calloc((size_t)w->count, sizeof(ZfTensor));
  w->names = (char *)calloc((size_t)w->count, ZF_ZFW_NAME_LEN + 1);
  w->converted = (unsigned char *)calloc((size_t)w->count, 1);
  if (!w->tensors || !w->names || !w->converted) {
    why = "out of memory";
    goto fail;
  }
  const size_t entry = ZF_ZFW_NAME_LEN + 12 + 16;
  for (int i = 0; i < w->count; ++i) {
    const unsigned char *p = blob + 12 + (size_t)i * entry;
    if ((size_t)(p - blob) + entry > w->bytes) {
      why = "the tensor table runs past the end of the file";
      goto fail;
    }
    char *name = w->names + (size_t)i * (ZF_ZFW_NAME_LEN + 1);
    memcpy(name, p, ZF_ZFW_NAME_LEN);
    name[ZF_ZFW_NAME_LEN] = '\0';
    const uint32_t dtype = read_u32(p + ZF_ZFW_NAME_LEN);
    const uint32_t offset = read_u32(p + ZF_ZFW_NAME_LEN + 4);
    const uint32_t bytes = read_u32(p + ZF_ZFW_NAME_LEN + 8);
    if (dtype > ZF_DTYPE_S32 || (size_t)offset + bytes > w->bytes) {
      why = "a tensor lies outside the file";
      goto fail;
    }
    w->tensors[i].name = name;
    w->tensors[i].dtype = (ZfDtype)dtype;
    w->tensors[i].data = blob + offset;
    w->tensors[i].bytes = bytes;
    for (int d = 0; d < 4; ++d)
      w->tensors[i].dims[d] = read_i32(p + ZF_ZFW_NAME_LEN + 12 + 4 * d);
  }
  if (error) *error = NULL;
  return w;

fail:
  zf_weights_close(w);
  if (error) *error = why;
  return NULL;
}

/* Takes ownership of `blob` (malloc'd, `size` bytes): parses it as a zfw file. */
ZfWeights *zf_weights_from_blob(unsigned char *blob, size_t size, const char **error) {
  return from_blob(blob, size, 0, error);
}

ZfWeights *zf_weights_open(const char *path, const char **error) {
  /* a file held in memory (zf/vfs.h) is used before the file system */
  size_t mem_size = 0;
  unsigned char *mem = zf_vfs_copy(path, &mem_size);
  if (mem) return zf_weights_from_blob(mem, mem_size, error);
#if ZF_ZFW_MMAP
  /* A private, writable mapping of the file instead of a malloc'd copy of it.
   *
   * Reading copied the 66 MB of layers.zfw into anonymous memory at load. Mapped, the pages are the
   * page cache's own: no copy at load, and on a low-memory phone (the Alcatel 1 has 912 MB) the
   * kernel can drop clean weight pages under pressure and fault them back from the file instead of
   * killing the app. The few tensors the engine rewrites in place at load (layout conversions) are
   * copied on write into private pages, as before. Same bytes, so the same bits.
   *
   * The file must not be truncated or rewritten in place while a stream uses it (a reader past the
   * new end would fault): a model update must write a new file and rename it over the old one, which
   * leaves this mapping on the old inode. ZF_ZFW_READ=1 (development builds) reads instead. */
  if (!zf_getenv("ZF_ZFW_READ")) {
    const int fd = open(path, O_RDONLY);
    struct stat sb;
    if (fd >= 0 && fstat(fd, &sb) == 0 && sb.st_size > 0) {
      void *p = mmap(NULL, (size_t)sb.st_size, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
      close(fd);
      if (p != MAP_FAILED) {
        /* Start reading the whole file in now, in the background: every chunk reads every weight,
         * and without this a cold start (file not in the page cache) takes its page faults one
         * readahead window at a time inside the first chunk (Alcatel 1, one cold run: 508 major
         * faults, first chunk 470 ms against 75 warm). Advice only; same bytes. */
        madvise(p, (size_t)sb.st_size, MADV_WILLNEED);
        return from_blob((unsigned char *)p, (size_t)sb.st_size, 1, error);
      }
    } else if (fd >= 0) {
      close(fd);
    }
  }
#endif
  FILE *fh = fopen(path, "rb");
  if (!fh) {
    if (error) *error = "cannot open the weight file";
    return NULL;
  }
  fseek(fh, 0, SEEK_END);
  const long size = ftell(fh);
  fseek(fh, 0, SEEK_SET);
  unsigned char *blob = size > 0 ? (unsigned char *)malloc((size_t)size) : NULL;
  if (!blob || fread(blob, 1, (size_t)size, fh) != (size_t)size) {
    fclose(fh);
    free(blob);
    if (error) *error = blob ? "short read" : "cannot read the weight file";
    return NULL;
  }
  fclose(fh);
  return zf_weights_from_blob(blob, (size_t)size, error);
}

void zf_weights_close(ZfWeights *w) {
  if (!w) return;
  release_blob(w->blob, w->bytes, w->mapped);
  free(w->tensors);
  free(w->names);
  free(w->converted);
  free(w);
}

int zf_weights_convert_to_dot(ZfWeights *w, const char *name, int n, int k) {
  if (!w) return 0;
  for (int i = 0; i < w->count; ++i) {
    if (strcmp(w->tensors[i].name, name) != 0) continue;
    if (w->tensors[i].dtype != ZF_DTYPE_S8) return 0;
    if (w->converted[i]) return 1;
    if (!zf_weights_s8_to_dot((int8_t *)w->tensors[i].data, n, k)) return 0;
    w->converted[i] = 1;
    return 1;
  }
  return 0;
}

int zf_weights_reorder_conv_k(ZfWeights *w, const char *name, int n, int k, int in_channels,
                              int kh, int kw) {
  if (!w) return 0;
  for (int i = 0; i < w->count; ++i) {
    if (strcmp(w->tensors[i].name, name) != 0) continue;
    if (w->tensors[i].dtype != ZF_DTYPE_S8) return 0;
    if (w->converted[i]) return 1;
    if (!zf_conv_reorder_k((int8_t *)w->tensors[i].data, n, k, in_channels, kh, kw)) return 0;
    w->converted[i] = 1;
    return 1;
  }
  return 0;
}

/* The same permutation for an fp32 conv weight: k from (channel, dy, dx) to (dy, dx, channel).
 *
 * The gather has to match the weight. Reading (dy, dx, channel) out of a pixel-major input is
 * kh*kw contiguous runs of in_channels floats; reading (channel, dy, dx) out of it is one strided
 * load per element, which is what the fp32 path was doing for the two convolutions whose input is
 * pixel-major. Float addition is not associative, so this DOES reorder the sum, and it is only safe
 * because the products are the same set: measured below against the graph it leaves the front end
 * exact to the same 1.6e-07. */
int zf_weights_reorder_conv_k_f32(ZfWeights *w, const char *name, int n, int in_channels, int kh,
                                  int kw) {
  if (!w) return 0;
  const int k = in_channels * kh * kw;
  for (int i = 0; i < w->count; ++i) {
    if (strcmp(w->tensors[i].name, name) != 0) continue;
    if (w->tensors[i].dtype != ZF_DTYPE_F32) return 0;
    if (w->converted[i]) return 1;
    float *data = (float *)w->tensors[i].data;
    float *tmp = (float *)malloc((size_t)k * sizeof(float));
    if (!tmp) return 0;
    for (int row = 0; row < n; ++row) {
      float *r = data + (size_t)row * k;
      for (int c = 0; c < in_channels; ++c)
        for (int y = 0; y < kh; ++y)
          for (int x = 0; x < kw; ++x)
            tmp[((size_t)y * kw + x) * in_channels + c] = r[((size_t)c * kh + y) * kw + x];
      memcpy(r, tmp, (size_t)k * sizeof(float));
    }
    free(tmp);
    w->converted[i] = 1;
    return 1;
  }
  return 0;
}

const ZfTensor *zf_weights_find(const ZfWeights *w, const char *name) {
  if (!w) return NULL;
  for (int i = 0; i < w->count; ++i)
    if (strcmp(w->tensors[i].name, name) == 0) return &w->tensors[i];
  return NULL;
}

static const void *typed(const ZfWeights *w, const char *name, ZfDtype want, size_t elem,
                         size_t *count) {
  const ZfTensor *t = zf_weights_find(w, name);
  if (!t || t->dtype != want) return NULL;
  if (count) *count = t->bytes / elem;
  return t->data;
}

const float *zf_weights_f32(const ZfWeights *w, const char *name, size_t *count) {
  return (const float *)typed(w, name, ZF_DTYPE_F32, sizeof(float), count);
}

const int8_t *zf_weights_s8(const ZfWeights *w, const char *name, size_t *count) {
  return (const int8_t *)typed(w, name, ZF_DTYPE_S8, 1, count);
}

const int32_t *zf_weights_s32(const ZfWeights *w, const char *name, size_t *count) {
  return (const int32_t *)typed(w, name, ZF_DTYPE_S32, sizeof(int32_t), count);
}

int zf_weights_count(const ZfWeights *w) { return w ? w->count : 0; }

const ZfTensor *zf_weights_at(const ZfWeights *w, int index) {
  if (!w || index < 0 || index >= w->count) return NULL;
  return &w->tensors[index];
}
