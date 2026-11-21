/* What the tajweed library's tests share: a counting CHECK and a few file helpers.
 *
 * The tests build their model folders at run time, under the scratch directory ctest hands them
 * (argv[2]), from the files in tests/data/model (argv[1]). */
#ifndef TJ_TEST_H
#define TJ_TEST_H

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <direct.h>
#define tj_test_mkdir(path) _mkdir(path)
#else
#include <sys/stat.h>
#define tj_test_mkdir(path) mkdir(path, 0777)
#endif

static int tj_test_checks, tj_test_fails;

#define CHECK(cond)                                                              \
  do {                                                                           \
    ++tj_test_checks;                                                            \
    if (!(cond)) {                                                               \
      ++tj_test_fails;                                                           \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);   \
    }                                                                            \
  } while (0)

/* Prints the count and gives main's return value. */
static inline int tj_test_done(const char *name) {
  printf("%s: %d checks, %d failed\n", name, tj_test_checks, tj_test_fails);
  return tj_test_fails != 0;
}

/* "<dir>/<name>" into buf. A path that does not fit ends the test: nothing is ever cut short. */
static inline const char *tj_test_path(char *buf, size_t cap, const char *dir, const char *name) {
  const size_t a = strlen(dir), b = strlen(name);
  if (a + b + 2 > cap) {
    fprintf(stderr, "path too long: %s/%s\n", dir, name);
    exit(2);
  }
  memcpy(buf, dir, a);
  buf[a] = '/';
  memcpy(buf + a + 1, name, b + 1);
  return buf;
}

/* A whole file, malloc'd, with a NUL after its bytes; NULL when it cannot be read. */
static inline unsigned char *tj_test_read(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  const long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *d = n >= 0 ? (unsigned char *)malloc((size_t)n + 1) : NULL;
  if (d && n > 0 && fread(d, 1, (size_t)n, f) != (size_t)n) {
    free(d);
    d = NULL;
  }
  fclose(f);
  if (d) {
    d[n] = 0;
    *size = (size_t)n;
  }
  return d;
}

/* Writes a file; 0 on success. */
static inline int tj_test_write(const char *path, const void *data, size_t size) {
  FILE *f = fopen(path, "wb");
  if (!f) return -1;
  const size_t w = size ? fwrite(data, 1, size, f) : 0;
  return fclose(f) || w != size ? -1 : 0;
}

/* Copies <from_dir>/<name> to <to_dir>/<name>; 0 on success. */
static inline int tj_test_copy(const char *from_dir, const char *to_dir, const char *name) {
  char a[1024], b[1024];
  size_t n = 0;
  unsigned char *d = tj_test_read(tj_test_path(a, sizeof a, from_dir, name), &n);
  if (!d) return -1;
  const int rc = tj_test_write(tj_test_path(b, sizeof b, to_dir, name), d, n);
  free(d);
  return rc;
}

#endif /* TJ_TEST_H */
