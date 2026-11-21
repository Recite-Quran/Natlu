#include "zf/vfs.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef struct VfsFile {
  char *path;
  unsigned char *data;
  size_t size;
  struct VfsFile *next;
} VfsFile;

static VfsFile *g_files = NULL;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

int zf_vfs_put(const char *path, unsigned char *data, size_t size) {
  VfsFile *f = (VfsFile *)calloc(1, sizeof *f);
  char *p = f ? strdup(path) : NULL;
  if (!f || !p) {
    free(f);
    free(p);
    free(data);
    return 0;
  }
  f->path = p;
  f->data = data;
  f->size = size;
  pthread_mutex_lock(&g_lock);
  for (VfsFile **q = &g_files; *q; q = &(*q)->next) {
    if (strcmp((*q)->path, path) == 0) {
      VfsFile *old = *q;
      *q = old->next;
      free(old->path);
      free(old->data);
      free(old);
      break;
    }
  }
  f->next = g_files;
  g_files = f;
  pthread_mutex_unlock(&g_lock);
  return 1;
}

unsigned char *zf_vfs_copy(const char *path, size_t *size) {
  unsigned char *out = NULL;
  pthread_mutex_lock(&g_lock);
  for (VfsFile *f = g_files; f; f = f->next) {
    if (strcmp(f->path, path) != 0) continue;
    out = (unsigned char *)malloc(f->size + 1);
    if (out) {
      memcpy(out, f->data, f->size);
      out[f->size] = 0;
      if (size) *size = f->size;
    }
    break;
  }
  pthread_mutex_unlock(&g_lock);
  return out;
}

void zf_vfs_remove_prefix(const char *prefix) {
  const size_t n = strlen(prefix);
  pthread_mutex_lock(&g_lock);
  for (VfsFile **q = &g_files; *q;) {
    if (strncmp((*q)->path, prefix, n) == 0) {
      VfsFile *old = *q;
      *q = old->next;
      free(old->path);
      free(old->data);
      free(old);
    } else {
      q = &(*q)->next;
    }
  }
  pthread_mutex_unlock(&g_lock);
}
