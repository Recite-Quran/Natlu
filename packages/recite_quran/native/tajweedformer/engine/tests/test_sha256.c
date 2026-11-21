/* zf_sha256 (zf/sha256.h) against the FIPS 180-4 examples and the padding boundaries.
 *
 * The SDKs check every model file against its manifest with this function, so a wrong digest would
 * refuse a good model or accept a damaged one. The expected digests are the published ones ("abc",
 * the 448-bit message, one million 'a') and, for the lengths around a block boundary (55, 56, 63,
 * 64, 65 bytes, where the padding moves into a second block), those of Python's hashlib. */
#include <stdlib.h>
#include <string.h>

#include "zf/sha256.h"
#include "zf_test.h"

static int digest_is(const void *data, size_t n, const char *hex) {
  unsigned char d[32];
  char got[65];
  zf_sha256(data, n, d);
  for (int i = 0; i < 32; ++i) {
    got[2 * i] = "0123456789abcdef"[d[i] >> 4];
    got[2 * i + 1] = "0123456789abcdef"[d[i] & 15];
  }
  got[64] = 0;
  if (strcmp(got, hex)) fprintf(stderr, "sha256 of %lu bytes: %s, expected %s\n", (unsigned long)n, got, hex);
  return !strcmp(got, hex);
}

int main(void) {
  CHECK(digest_is("", 0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
  CHECK(digest_is("abc", 3, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
  const char *m448 = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
  CHECK(digest_is(m448, strlen(m448), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));

  char *a = (char *)malloc(1000000);
  CHECK(a != NULL);
  if (!a) return zf_test_done("sha256");
  memset(a, 'a', 1000000);
  CHECK(digest_is(a, 55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"));
  CHECK(digest_is(a, 56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"));
  CHECK(digest_is(a, 63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"));
  CHECK(digest_is(a, 64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"));
  CHECK(digest_is(a, 65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"));
  CHECK(digest_is(a, 1000000, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"));
  free(a);

  unsigned char all[256];
  for (int i = 0; i < 256; ++i) all[i] = (unsigned char)i;
  CHECK(digest_is(all, 256, "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880"));
  return zf_test_done("sha256");
}
