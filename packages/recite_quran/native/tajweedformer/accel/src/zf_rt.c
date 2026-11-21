/* zf_rt: the engine graph without ONNX Runtime.
 *
 * The deployed graph, once tools/zfgraph.py has rewritten it, is 46 nodes: 41 of the engine's own
 * operators (accel/src/ort_ops.c) and five standard ones, three Concat, one Add and one
 * LogSoftmax. ONNX Runtime's part in a chunk is therefore scheduling, allocation and five small
 * operators. This file provides the slice of the ONNX Runtime C API that the engine's operators and
 * the bench harnesses actually call, and runs the graph itself: the same operator code, the same
 * nodes in the same order, so the same bits. The harnesses link against this instead of
 * libonnxruntime and do not change.
 *
 * The graph comes from `MODEL.zfg` and `MODEL.zfg.bin` next to the model path the session is asked
 * to open, written by tools/zfg_export.py. Only what that graph needs is implemented; anything else
 * returns ORT_NOT_IMPLEMENTED rather than guessing.
 */
#include <math.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "onnxruntime_c_api.h"
#include "zf/env.h"
#include "zf/vfs.h"
#include "zf/kernels.h"
#include "zf/libm.h"

#define RT_MAX_RANK 8
#define RT_MAX_IO 16
#define RT_MAX_ATTR 16

struct OrtStatus {
  OrtErrorCode code;
  char msg[256];
};

struct OrtValue {
  int dtype;
  int rank;
  int64_t dims[RT_MAX_RANK];
  void *data;
  size_t cap;  /* bytes allocated when owned */
  int owned;
};

struct OrtTensorTypeAndShapeInfo {
  int dtype;
  size_t rank;
  int64_t dims[RT_MAX_RANK];
};

struct OrtTypeInfo {
  struct OrtTensorTypeAndShapeInfo tensor;
};

typedef struct {
  char kind; /* i, f, s, I */
  char name[64];
  int64_t i;
  float f;
  char *s;
  int64_t *ints;
  size_t n;
} RtAttr;

typedef struct {
  char domain[64];
  char op[64];
  char name[160];
  int n_in, n_out, n_attr;
  int in[RT_MAX_IO];  /* value slots, -1 for an absent optional input */
  int out[RT_MAX_IO];
  RtAttr attr[RT_MAX_ATTR];
  const OrtCustomOp *custom;
  void *kernel;
} RtNode;

struct OrtKernelInfo {
  const RtNode *node;
};

struct OrtCustomOpDomain {
  char name[64];
  const OrtCustomOp *ops[32];
  int n;
};

struct OrtSessionOptions {
  OrtCustomOpDomain *domains[4];
  int n_domains;
};

typedef struct {
  char name[160];
  OrtValue value;
} RtSlot;

typedef struct {
  char key[64];
  char *value;
} RtMeta;

struct OrtModelMetadata {
  RtMeta *items;
  int n;
};

struct OrtSession {
  RtSlot *slots;
  int n_slots, cap_slots;
  RtNode *nodes;
  int n_nodes;
  int inputs[RT_MAX_IO], n_inputs;
  int outputs[RT_MAX_IO], n_outputs;
  struct OrtModelMetadata meta;
  unsigned char *blob;
  /* zf_rt_run_batch: one value per chunk for every per-chunk slot, kept between batches so their
   * buffers are reused; [chunk * n_slots + slot] */
  OrtValue *bvals;
  int bcap;
  /* the live set of the last request (rt_live): live[i] is 1 when node i feeds an asked-for output */
  unsigned char *live;
  char **live_names;
  size_t live_n;
  int live_last; /* the last live node */
};

struct OrtKernelContext {
  OrtSession *session;
  RtNode *node;
};

struct OrtEnv {
  int unused;
};
struct OrtMemoryInfo {
  int unused;
};

static OrtApi g_rt;

/* ------------------------------------------------------------------------------------ status */

static OrtStatus *ORT_API_CALL rt_create_status(OrtErrorCode code, const char *msg) NO_EXCEPTION {
  OrtStatus *s = (OrtStatus *)calloc(1, sizeof *s);
  if (!s) return NULL;
  s->code = code;
  snprintf(s->msg, sizeof s->msg, "%s", msg ? msg : "");
  return s;
}
static OrtStatus *fail(const char *fmt, const char *a) {
  char buf[256];
  snprintf(buf, sizeof buf, fmt, a ? a : "");
  return rt_create_status(ORT_FAIL, buf);
}
static OrtErrorCode ORT_API_CALL rt_get_error_code(const OrtStatus *s) NO_EXCEPTION {
  return s->code;
}
static const char *ORT_API_CALL rt_get_error_message(const OrtStatus *s) NO_EXCEPTION {
  return s->msg;
}
static void ORT_API_CALL rt_release_status(OrtStatus *s) { free(s); }

static size_t dtype_size(int dtype) {
  switch (dtype) {
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32:
      return 4;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
      return 8;
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8:
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_UINT8:
    case ONNX_TENSOR_ELEMENT_DATA_TYPE_BOOL:
      return 1;
    default:
      return 0;
  }
}

static size_t elements(const OrtValue *v) {
  size_t n = 1;
  for (int d = 0; d < v->rank; ++d) n *= (size_t)v->dims[d];
  return n;
}

/* ----------------------------------------------------------------------- env and options */

static OrtEnv g_env;
static OrtStatus *ORT_API_CALL rt_create_env(OrtLoggingLevel l, const char *id, OrtEnv **out) {
  (void)l;
  (void)id;
  *out = &g_env;
  return NULL;
}
static void ORT_API_CALL rt_release_env(OrtEnv *e) { (void)e; }
static OrtStatus *ORT_API_CALL rt_create_session_options(OrtSessionOptions **out) {
  *out = (OrtSessionOptions *)calloc(1, sizeof **out);
  return *out ? NULL : rt_create_status(ORT_FAIL, "out of memory");
}
static void ORT_API_CALL rt_release_session_options(OrtSessionOptions *o) { free(o); }
static OrtStatus *ORT_API_CALL rt_set_threads(OrtSessionOptions *o, int n) {
  (void)o;
  (void)n;
  return NULL; /* the engine runs its own pool; this runtime runs nodes on the calling thread */
}
static OrtStatus *ORT_API_CALL rt_set_opt_level(OrtSessionOptions *o, GraphOptimizationLevel l) {
  (void)o;
  (void)l;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_enable_profiling(OrtSessionOptions *o, const ORTCHAR_T *p) {
  (void)o;
  (void)p;
  return rt_create_status(ORT_NOT_IMPLEMENTED, "zf_rt: profiling is ONNX Runtime's");
}
static OrtStatus *ORT_API_CALL rt_create_domain(const char *name, OrtCustomOpDomain **out) {
  OrtCustomOpDomain *d = (OrtCustomOpDomain *)calloc(1, sizeof *d);
  if (!d) return rt_create_status(ORT_FAIL, "out of memory");
  snprintf(d->name, sizeof d->name, "%s", name);
  *out = d;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_domain_add(OrtCustomOpDomain *d, const OrtCustomOp *op) {
  if (d->n >= 32) return rt_create_status(ORT_FAIL, "zf_rt: too many custom ops");
  d->ops[d->n++] = op;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_add_domain(OrtSessionOptions *o, OrtCustomOpDomain *d) {
  if (o->n_domains >= 4) return rt_create_status(ORT_FAIL, "zf_rt: too many domains");
  o->domains[o->n_domains++] = d;
  return NULL;
}
static void ORT_API_CALL rt_release_domain(OrtCustomOpDomain *d) { free(d); }

/* ------------------------------------------------------------------------- allocator */

static void *ORT_API_CALL rt_alloc(OrtAllocator *a, size_t n) {
  (void)a;
  return malloc(n);
}
static void ORT_API_CALL rt_free(OrtAllocator *a, void *p) {
  (void)a;
  free(p);
}
static OrtAllocator g_alloc;
static OrtStatus *ORT_API_CALL rt_get_allocator(OrtAllocator **out) {
  g_alloc.version = ORT_API_VERSION;
  g_alloc.Alloc = rt_alloc;
  g_alloc.Free = rt_free;
  *out = &g_alloc;
  return NULL;
}
static OrtMemoryInfo g_mem;
static OrtStatus *ORT_API_CALL rt_create_cpu_memory_info(enum OrtAllocatorType t, enum OrtMemType m,
                                                         OrtMemoryInfo **out) {
  (void)t;
  (void)m;
  *out = &g_mem;
  return NULL;
}
static void ORT_API_CALL rt_release_memory_info(OrtMemoryInfo *m) { (void)m; }
static char *dup_with(OrtAllocator *a, const char *s) {
  const size_t n = strlen(s) + 1;
  char *p = (char *)a->Alloc(a, n);
  if (p) memcpy(p, s, n);
  return p;
}

/* ---------------------------------------------------------------------------- values */

static OrtStatus *ORT_API_CALL rt_create_tensor_with_data(const OrtMemoryInfo *info, void *data,
                                                          size_t bytes, const int64_t *shape,
                                                          size_t rank,
                                                          ONNXTensorElementDataType type,
                                                          OrtValue **out) {
  (void)info;
  if (rank > RT_MAX_RANK) return rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: rank");
  OrtValue *v = (OrtValue *)calloc(1, sizeof *v);
  if (!v) return rt_create_status(ORT_FAIL, "out of memory");
  v->dtype = type;
  v->rank = (int)rank;
  for (size_t d = 0; d < rank; ++d) v->dims[d] = shape[d];
  v->data = data;
  v->cap = bytes;
  *out = v;
  return NULL;
}
static void ORT_API_CALL rt_release_value(OrtValue *v) {
  if (!v) return;
  if (v->owned) free(v->data);
  free(v);
}
static OrtStatus *ORT_API_CALL rt_get_mutable_data(OrtValue *v, void **out) {
  *out = v->data;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_get_data(const OrtValue *v, const void **out) {
  *out = v->data;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_get_type_and_shape(const OrtValue *v,
                                                     OrtTensorTypeAndShapeInfo **out) {
  OrtTensorTypeAndShapeInfo *i = (OrtTensorTypeAndShapeInfo *)calloc(1, sizeof *i);
  if (!i) return rt_create_status(ORT_FAIL, "out of memory");
  i->dtype = v->dtype;
  i->rank = (size_t)v->rank;
  memcpy(i->dims, v->dims, sizeof i->dims);
  *out = i;
  return NULL;
}
static void ORT_API_CALL rt_release_tsinfo(OrtTensorTypeAndShapeInfo *i) { free(i); }
static OrtStatus *ORT_API_CALL rt_create_tsinfo(OrtTensorTypeAndShapeInfo **out) {
  *out = (OrtTensorTypeAndShapeInfo *)calloc(1, sizeof **out);
  return *out ? NULL : rt_create_status(ORT_FAIL, "out of memory");
}
static OrtStatus *ORT_API_CALL rt_set_elem_type(OrtTensorTypeAndShapeInfo *i,
                                                ONNXTensorElementDataType t) {
  i->dtype = t;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_set_dims(OrtTensorTypeAndShapeInfo *i, const int64_t *d,
                                           size_t n) {
  if (n > RT_MAX_RANK) return rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: rank");
  i->rank = n;
  memcpy(i->dims, d, n * sizeof *d);
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_get_elem_type(const OrtTensorTypeAndShapeInfo *i,
                                                enum ONNXTensorElementDataType *out) {
  *out = (enum ONNXTensorElementDataType)i->dtype;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_get_dims_count(const OrtTensorTypeAndShapeInfo *i, size_t *out) {
  *out = i->rank;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_get_dims(const OrtTensorTypeAndShapeInfo *i, int64_t *out,
                                           size_t n) {
  for (size_t d = 0; d < n && d < i->rank; ++d) out[d] = i->dims[d];
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_get_elem_count(const OrtTensorTypeAndShapeInfo *i, size_t *out) {
  size_t n = 1;
  for (size_t d = 0; d < i->rank; ++d) n *= (size_t)i->dims[d];
  *out = n;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_cast_type_info(const OrtTypeInfo *t,
                                                 const OrtTensorTypeAndShapeInfo **out) {
  *out = &t->tensor;
  return NULL;
}
static void ORT_API_CALL rt_release_type_info(OrtTypeInfo *t) { free(t); }

/* --------------------------------------------------------------------- kernel info, context */

static const RtAttr *find_attr(const RtNode *n, const char *name, char kind) {
  for (int i = 0; i < n->n_attr; ++i)
    if (n->attr[i].kind == kind && !strcmp(n->attr[i].name, name)) return &n->attr[i];
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_attr_i64(const OrtKernelInfo *info, const char *name,
                                           int64_t *out) {
  const RtAttr *a = find_attr(info->node, name, 'i');
  if (!a) return fail("zf_rt: no int attribute %s", name);
  *out = a->i;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_attr_f32(const OrtKernelInfo *info, const char *name,
                                           float *out) {
  const RtAttr *a = find_attr(info->node, name, 'f');
  if (!a) return fail("zf_rt: no float attribute %s", name);
  *out = a->f;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_attr_str(const OrtKernelInfo *info, const char *name, char *out,
                                           size_t *size) {
  const RtAttr *a = find_attr(info->node, name, 's');
  if (!a) return fail("zf_rt: no string attribute %s", name);
  const size_t need = strlen(a->s) + 1;
  if (!out || *size < need) {
    *size = need;
    return out ? rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: string buffer too small") : NULL;
  }
  memcpy(out, a->s, need);
  *size = need;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_attr_ints(const OrtKernelInfo *info, const char *name,
                                            int64_t *out, size_t *size) {
  const RtAttr *a = find_attr(info->node, name, 'I');
  if (!a) return fail("zf_rt: no ints attribute %s", name);
  if (!out) {
    *size = a->n;
    return NULL;
  }
  if (*size < a->n) {
    *size = a->n;
    return rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: ints buffer too small");
  }
  memcpy(out, a->ints, a->n * sizeof *out);
  *size = a->n;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_ctx_input_count(const OrtKernelContext *c, size_t *out) {
  *out = (size_t)c->node->n_in;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_ctx_input(const OrtKernelContext *c, size_t i,
                                            const OrtValue **out) {
  if ((int)i >= c->node->n_in) return rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: input index");
  const int s = c->node->in[i];
  *out = s < 0 ? NULL : &c->session->slots[s].value;
  return NULL;
}
/* Outputs keep their buffer from chunk to chunk: every shape in this graph is static, so this
 * allocates on the first chunk and never again. */
static OrtStatus *ensure(OrtValue *v, int dtype, const int64_t *dims, size_t rank) {
  if (rank > RT_MAX_RANK) return rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: rank");
  size_t n = 1;
  for (size_t d = 0; d < rank; ++d) n *= (size_t)dims[d];
  const size_t bytes = n * dtype_size(dtype);
  if (!v->owned || v->cap < bytes) {
    void *p = malloc(bytes ? bytes : 1);
    if (!p) return rt_create_status(ORT_FAIL, "out of memory");
    if (v->owned) free(v->data);
    v->data = p;
    v->cap = bytes;
    v->owned = 1;
  }
  v->dtype = dtype;
  v->rank = (int)rank;
  for (size_t d = 0; d < rank; ++d) v->dims[d] = dims[d];
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_ctx_output(OrtKernelContext *c, size_t i, const int64_t *dims,
                                             size_t rank, OrtValue **out) {
  if ((int)i >= c->node->n_out) return rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: output index");
  OrtValue *v = &c->session->slots[c->node->out[i]].value;
  OrtStatus *st = ensure(v, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, dims, rank);
  if (st) return st;
  *out = v;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_parallel_for(const OrtKernelContext *c, void (*fn)(void *, size_t),
                                               size_t total, size_t batch, void *user) {
  (void)c;
  (void)batch;
  for (size_t i = 0; i < total; ++i) fn(user, i);
  return NULL;
}

/* --------------------------------------------------------------------------- loading */

static int slot_of(OrtSession *s, const char *name, int create) {
  if (!strcmp(name, "-")) return -1;
  for (int i = 0; i < s->n_slots; ++i)
    if (!strcmp(s->slots[i].name, name)) return i;
  if (!create) return -2;
  if (s->n_slots == s->cap_slots) {
    const int cap = s->cap_slots ? 2 * s->cap_slots : 256;
    RtSlot *p = (RtSlot *)realloc(s->slots, (size_t)cap * sizeof *p);
    if (!p) return -2;
    memset(p + s->cap_slots, 0, (size_t)(cap - s->cap_slots) * sizeof *p);
    s->slots = p;
    s->cap_slots = cap;
  }
  snprintf(s->slots[s->n_slots].name, sizeof s->slots[0].name, "%s", name);
  return s->n_slots++;
}

static const OrtCustomOp *find_custom(const OrtSessionOptions *o, const char *domain,
                                      const char *op) {
  for (int d = 0; d < o->n_domains; ++d) {
    if (strcmp(o->domains[d]->name, domain)) continue;
    for (int i = 0; i < o->domains[d]->n; ++i)
      if (!strcmp(o->domains[d]->ops[i]->GetName(o->domains[d]->ops[i]), op))
        return o->domains[d]->ops[i];
  }
  return NULL;
}

static unsigned char *read_file(const char *path, size_t *size) {
  /* a file held in memory (zf/vfs.h) is used before the file system */
  unsigned char *mem = zf_vfs_copy(path, size);
  if (mem) return mem;
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  const long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *p = (unsigned char *)malloc((size_t)n + 1);
  if (p && fread(p, 1, (size_t)n, f) != (size_t)n) {
    free(p);
    p = NULL;
  }
  fclose(f);
  if (p) {
    p[n] = 0;
    if (size) *size = (size_t)n;
  }
  return p;
}

static void release_session(OrtSession *s);

static OrtStatus *ORT_API_CALL rt_create_session(const OrtEnv *env, const ORTCHAR_T *model_path,
                                                 const OrtSessionOptions *options,
                                                 OrtSession **out) {
  (void)env;
  char path[1024];
  snprintf(path, sizeof path, "%s.zfg", model_path);
  char *text = (char *)read_file(path, NULL);
  if (!text) return fail("zf_rt: cannot read %s (tools/zfg_export.py writes it)", path);
  snprintf(path, sizeof path, "%s.zfg.bin", model_path);
  size_t blob_size = 0;
  unsigned char *blob = read_file(path, &blob_size);
  if (!blob) {
    free(text);
    return fail("zf_rt: cannot read %s", path);
  }
  OrtSession *s = (OrtSession *)calloc(1, sizeof *s);
  if (!s) {
    free(text);
    free(blob);
    return rt_create_status(ORT_FAIL, "out of memory");
  }
  s->blob = blob;
  int node_cap = 0;
  OrtStatus *st = NULL;
  RtNode *node = NULL;
  char *save = NULL;
  for (char *line = strtok_r(text, "\n", &save); line && !st; line = strtok_r(NULL, "\n", &save)) {
    char kw[16] = {0};
    int used = 0;
    if (sscanf(line, "%15s%n", kw, &used) != 1) continue;
    char *rest = line + used;
    if (!strcmp(kw, "zfg")) continue;
    if (!strcmp(kw, "meta")) {
      RtMeta *m = (RtMeta *)realloc(s->meta.items, (size_t)(s->meta.n + 1) * sizeof *m);
      if (!m) { st = rt_create_status(ORT_FAIL, "out of memory"); break; }
      s->meta.items = m;
      int k = 0;
      sscanf(rest, " %63s%n", m[s->meta.n].key, &k);
      const char *v = rest + k;
      if (*v == ' ') ++v;
      m[s->meta.n].value = strdup(v);
      s->meta.n++;
    } else if (!strcmp(kw, "input") || !strcmp(kw, "output") || !strcmp(kw, "init")) {
      char name[160];
      int dtype = 0, rank = 0, k = 0;
      sscanf(rest, " %159s %d %d%n", name, &dtype, &rank, &k);
      rest += k;
      const int slot = slot_of(s, name, 1);
      if (slot < 0 || rank > RT_MAX_RANK) { st = fail("zf_rt: bad declaration %s", name); break; }
      OrtValue *v = &s->slots[slot].value;
      v->dtype = dtype;
      v->rank = rank;
      for (int d = 0; d < rank; ++d) {
        long long x = 0;
        sscanf(rest, " %lld%n", &x, &k);
        rest += k;
        v->dims[d] = x;
      }
      if (kw[0] == 'i' && kw[2] == 'p') s->inputs[s->n_inputs++] = slot;
      else if (kw[0] == 'o') s->outputs[s->n_outputs++] = slot;
      else {
        unsigned long long off = 0, bytes = 0;
        sscanf(rest, " %llu %llu", &off, &bytes);
        if (off + bytes > blob_size) { st = fail("zf_rt: initializer %s past the blob", name); break; }
        v->data = blob + off;
        v->cap = (size_t)bytes;
      }
    } else if (!strcmp(kw, "node")) {
      if (s->n_nodes == node_cap) {
        node_cap = node_cap ? 2 * node_cap : 64;
        RtNode *p = (RtNode *)realloc(s->nodes, (size_t)node_cap * sizeof *p);
        if (!p) { st = rt_create_status(ORT_FAIL, "out of memory"); break; }
        s->nodes = p;
      }
      node = &s->nodes[s->n_nodes++];
      memset(node, 0, sizeof *node);
      int k = 0;
      sscanf(rest, " %63s %63s %159s %d%n", node->domain, node->op, node->name, &node->n_in, &k);
      rest += k;
      for (int i = 0; i < node->n_in; ++i) {
        char nm[160];
        sscanf(rest, " %159s%n", nm, &k);
        rest += k;
        node->in[i] = slot_of(s, nm, 1);
      }
      sscanf(rest, " %d%n", &node->n_out, &k);
      rest += k;
      for (int i = 0; i < node->n_out; ++i) {
        char nm[160];
        sscanf(rest, " %159s%n", nm, &k);
        rest += k;
        node->out[i] = slot_of(s, nm, 1);
      }
      sscanf(rest, " %d", &node->n_attr);
      node->n_attr = 0; /* counted as the attribute lines arrive */
    } else if (!strcmp(kw, "a") && node) {
      RtAttr *a = &node->attr[node->n_attr++];
      int k = 0;
      sscanf(rest, " %c %63s%n", &a->kind, a->name, &k);
      rest += k;
      if (a->kind == 'i') {
        long long x = 0;
        sscanf(rest, " %lld", &x);
        a->i = x;
      } else if (a->kind == 'f') {
        a->f = strtof(rest, NULL);
      } else if (a->kind == 's') {
        char v[1024];
        sscanf(rest, " %1023s", v);
        a->s = strdup(v);
      } else if (a->kind == 'I') {
        unsigned long long n = 0;
        sscanf(rest, " %llu%n", &n, &k);
        rest += k;
        a->n = (size_t)n;
        a->ints = (int64_t *)calloc(a->n ? a->n : 1, sizeof(int64_t));
        for (size_t i = 0; i < a->n; ++i) {
          long long x = 0;
          sscanf(rest, " %lld%n", &x, &k);
          rest += k;
          a->ints[i] = x;
        }
      }
    }
  }
  free(text);
  /* bind the engine's operators and create their kernels, as ONNX Runtime does at session time */
  for (int i = 0; i < s->n_nodes && !st; ++i) {
    RtNode *n = &s->nodes[i];
    if (!strcmp(n->domain, "ai.onnx")) continue;
    n->custom = find_custom(options, n->domain, n->op);
    if (!n->custom) { st = fail("zf_rt: no operator registered for %s", n->op); break; }
    OrtKernelInfo info = {n};
    st = n->custom->CreateKernelV2(n->custom, &g_rt, &info, &n->kernel);
  }
  if (st) {
    release_session(s);
    return st;
  }
  *out = s;
  return NULL;
}

static void release_session(OrtSession *s) {
  if (!s) return;
  for (int i = 0; i < s->n_nodes; ++i) {
    RtNode *n = &s->nodes[i];
    if (n->custom && n->kernel && n->custom->KernelDestroy) n->custom->KernelDestroy(n->kernel);
    for (int a = 0; a < n->n_attr; ++a) {
      free(n->attr[a].s);
      free(n->attr[a].ints);
    }
  }
  for (int i = 0; i < s->n_slots; ++i)
    if (s->slots[i].value.owned) free(s->slots[i].value.data);
  for (int i = 0; i < s->bcap * s->n_slots; ++i)
    if (s->bvals[i].owned) free(s->bvals[i].data);
  free(s->bvals);
  for (size_t i = 0; i < s->live_n; ++i) free(s->live_names[i]);
  free(s->live_names);
  free(s->live);
  for (int i = 0; i < s->meta.n; ++i) free(s->meta.items[i].value);
  free(s->meta.items);
  free(s->slots);
  free(s->nodes);
  free(s->blob);
  free(s);
}
static void ORT_API_CALL rt_release_session(OrtSession *s) { release_session(s); }

/* ---------------------------------------------------------------------- session queries */

static OrtStatus *ORT_API_CALL rt_input_count(const OrtSession *s, size_t *out) {
  *out = (size_t)s->n_inputs;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_output_count(const OrtSession *s, size_t *out) {
  *out = (size_t)s->n_outputs;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_input_name(const OrtSession *s, size_t i, OrtAllocator *a,
                                             char **out) {
  *out = dup_with(a, s->slots[s->inputs[i]].name);
  return *out ? NULL : rt_create_status(ORT_FAIL, "out of memory");
}
static OrtStatus *ORT_API_CALL rt_output_name(const OrtSession *s, size_t i, OrtAllocator *a,
                                              char **out) {
  *out = dup_with(a, s->slots[s->outputs[i]].name);
  return *out ? NULL : rt_create_status(ORT_FAIL, "out of memory");
}
static OrtStatus *type_info_of(const OrtValue *v, OrtTypeInfo **out) {
  OrtTypeInfo *t = (OrtTypeInfo *)calloc(1, sizeof *t);
  if (!t) return rt_create_status(ORT_FAIL, "out of memory");
  t->tensor.dtype = v->dtype;
  t->tensor.rank = (size_t)v->rank;
  memcpy(t->tensor.dims, v->dims, sizeof t->tensor.dims);
  *out = t;
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_input_type(const OrtSession *s, size_t i, OrtTypeInfo **out) {
  return type_info_of(&s->slots[s->inputs[i]].value, out);
}
static OrtStatus *ORT_API_CALL rt_output_type(const OrtSession *s, size_t i, OrtTypeInfo **out) {
  return type_info_of(&s->slots[s->outputs[i]].value, out);
}
static OrtStatus *ORT_API_CALL rt_get_metadata(const OrtSession *s, OrtModelMetadata **out) {
  *out = (OrtModelMetadata *)&s->meta;
  return NULL;
}
static void ORT_API_CALL rt_release_metadata(OrtModelMetadata *m) { (void)m; }
static OrtStatus *ORT_API_CALL rt_lookup_metadata(const OrtModelMetadata *m, OrtAllocator *a,
                                                  const char *key, char **out) {
  *out = NULL;
  for (int i = 0; i < m->n; ++i)
    if (!strcmp(m->items[i].key, key)) {
      *out = dup_with(a, m->items[i].value);
      break;
    }
  return NULL;
}
static OrtStatus *ORT_API_CALL rt_end_profiling(OrtSession *s, OrtAllocator *a, char **out) {
  (void)s;
  (void)a;
  *out = NULL;
  return rt_create_status(ORT_NOT_IMPLEMENTED, "zf_rt: profiling is ONNX Runtime's");
}

/* ----------------------------------------------------------------------- standard nodes */

/* Concat along the last axis, which is the only axis this graph concatenates on. */
static OrtStatus *run_concat(OrtSession *s, RtNode *n) {
  const RtAttr *axis = find_attr(n, "axis", 'i');
  const OrtValue *a = &s->slots[n->in[0]].value;
  if (!axis || (axis->i != -1 && axis->i != a->rank - 1))
    return fail("zf_rt: %s concatenates on an axis other than the last", n->name);
  int64_t dims[RT_MAX_RANK];
  memcpy(dims, a->dims, sizeof dims);
  int64_t last = 0;
  for (int i = 0; i < n->n_in; ++i) last += s->slots[n->in[i]].value.dims[a->rank - 1];
  dims[a->rank - 1] = last;
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, a->dtype, dims, (size_t)a->rank);
  if (st) return st;
  const size_t esz = dtype_size(a->dtype);
  const size_t outer = elements(a) / (size_t)a->dims[a->rank - 1];
  size_t at = 0;
  for (int i = 0; i < n->n_in; ++i) {
    const OrtValue *v = &s->slots[n->in[i]].value;
    const size_t w = (size_t)v->dims[v->rank - 1] * esz;
    if (elements(v) / (size_t)v->dims[v->rank - 1] != outer)
      return fail("zf_rt: %s concatenates tensors of different leading shape", n->name);
    for (size_t o = 0; o < outer; ++o)
      memcpy((char *)y->data + o * (size_t)last * esz + at, (const char *)v->data + o * w, w);
    at += w;
  }
  return NULL;
}

/* Add of two tensors of one shape, or of a tensor and a one-element one: the frame counter. */
static OrtStatus *run_add(OrtSession *s, RtNode *n) {
  const OrtValue *a = &s->slots[n->in[0]].value, *b = &s->slots[n->in[1]].value;
  if (a->dtype != b->dtype) return fail("zf_rt: %s adds different types", n->name);
  const size_t na = elements(a), nb = elements(b);
  if (!(na == nb || nb == 1)) return fail("zf_rt: %s broadcasts in a way not supported", n->name);
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, a->dtype, a->dims, (size_t)a->rank);
  if (st) return st;
  if (a->dtype == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) {
    const int64_t *x = (const int64_t *)a->data, *z = (const int64_t *)b->data;
    for (size_t i = 0; i < na; ++i) ((int64_t *)y->data)[i] = x[i] + z[nb == 1 ? 0 : i];
  } else if (a->dtype == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
    const float *x = (const float *)a->data, *z = (const float *)b->data;
    for (size_t i = 0; i < na; ++i) ((float *)y->data)[i] = x[i] + z[nb == 1 ? 0 : i];
  } else {
    return fail("zf_rt: %s adds a type not supported", n->name);
  }
  return NULL;
}

static OrtStatus *run_log_softmax(OrtSession *s, RtNode *n) {
  const RtAttr *axis = find_attr(n, "axis", 'i');
  const OrtValue *a = &s->slots[n->in[0]].value;
  if (axis && axis->i != -1 && axis->i != a->rank - 1)
    return fail("zf_rt: %s is not over the last axis", n->name);
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, a->dims, (size_t)a->rank);
  if (st) return st;
  const int d = (int)a->dims[a->rank - 1];
  zf_log_softmax_rows_f32((const float *)a->data, (float *)y->data, (int)(elements(a) / (size_t)d),
                          d);
  return NULL;
}


/* V4's tajweed heads add a handful of standard nodes after the encoder (tools/zfgraph.py leaves
 * them as they are): Softmax and Sigmoid with ONNX Runtime's ARM32 arithmetic (MLAS's softmax and
 * logistic kernels, the ones the encoder layers already reproduce: zf_softmax_rows_f32 and
 * zf_sigmoid_f32 under ZF_CONV_ORT), an elementwise Mul of two tensors of one shape (SiLU's
 * x * sigmoid(x)), and the data movement ops Unsqueeze, Squeeze, Reshape and Tile, which copy bits. */

/* an int64 tensor's values (an initializer or a computed shape), at most RT_MAX_RANK of them */
static int rt_int64s(const OrtSession *s, int slot, int64_t *out, int max) {
  if (slot < 0) return -1;
  const OrtValue *v = &s->slots[slot].value;
  if (v->dtype != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 || !v->data) return -1;
  const size_t n = elements(v);
  if ((int)n > max) return -1;
  memcpy(out, v->data, n * sizeof(int64_t));
  return (int)n;
}

static OrtStatus *run_softmax(OrtSession *s, RtNode *n) {
  const RtAttr *axis = find_attr(n, "axis", 'i');
  const OrtValue *a = &s->slots[n->in[0]].value;
  if (a->dtype != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || (axis && axis->i != -1 && axis->i != a->rank - 1))
    return fail("zf_rt: %s is not a float softmax over the last axis", n->name);
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, a->dims, (size_t)a->rank);
  if (st) return st;
  const int d = (int)a->dims[a->rank - 1];
  memcpy(y->data, a->data, elements(a) * sizeof(float));
  zf_softmax_rows_f32((float *)y->data, (int)(elements(a) / (size_t)d), d);
  return NULL;
}

static OrtStatus *run_sigmoid(OrtSession *s, RtNode *n) {
  const OrtValue *a = &s->slots[n->in[0]].value;
  if (a->dtype != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) return fail("zf_rt: %s is not float", n->name);
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, a->dims, (size_t)a->rank);
  if (st) return st;
  zf_sigmoid_f32((const float *)a->data, (float *)y->data, elements(a));
  return NULL;
}

static OrtStatus *run_mul(OrtSession *s, RtNode *n) {
  const OrtValue *a = &s->slots[n->in[0]].value, *b = &s->slots[n->in[1]].value;
  if (a->dtype != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || b->dtype != a->dtype || elements(a) != elements(b))
    return fail("zf_rt: %s is not a float product of two tensors of one shape", n->name);
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, a->dtype, a->dims, (size_t)a->rank);
  if (st) return st;
  const float *x = (const float *)a->data, *z = (const float *)b->data;
  float *o = (float *)y->data;
  const size_t m = elements(a);
  for (size_t i = 0; i < m; ++i) o[i] = x[i] * z[i];
  return NULL;
}

/* Unsqueeze, Squeeze and Reshape: the same bytes under new dimensions */
static OrtStatus *run_reshape_like(OrtSession *s, RtNode *n) {
  const OrtValue *a = &s->slots[n->in[0]].value;
  int64_t dims[RT_MAX_RANK], arg[RT_MAX_RANK];
  int rank = 0;
  const int na = n->n_in > 1 ? rt_int64s(s, n->in[1], arg, RT_MAX_RANK) : 0;
  if (na < 0) return fail("zf_rt: %s needs constant int64 axes or shape", n->name);
  if (!strcmp(n->op, "Reshape")) {
    int64_t known = 1;
    int unknown = -1;
    for (int i = 0; i < na; ++i) {
      dims[i] = arg[i] == 0 ? a->dims[i] : arg[i];
      if (dims[i] == -1) unknown = i;
      else known *= dims[i];
    }
    if (unknown >= 0) dims[unknown] = known ? (int64_t)elements(a) / known : 0;
    rank = na;
  } else if (!strcmp(n->op, "Unsqueeze")) {
    rank = a->rank + na;
    if (rank > RT_MAX_RANK) return fail("zf_rt: %s exceeds the rank limit", n->name);
    int ins[RT_MAX_RANK] = {0};
    for (int i = 0; i < na; ++i) ins[arg[i] < 0 ? arg[i] + rank : arg[i]] = 1;
    for (int i = 0, j = 0; i < rank; ++i) dims[i] = ins[i] ? 1 : a->dims[j++];
  } else { /* Squeeze */
    int del[RT_MAX_RANK] = {0};
    for (int i = 0; i < na; ++i) del[arg[i] < 0 ? arg[i] + a->rank : arg[i]] = 1;
    for (int i = 0; i < a->rank; ++i)
      if (!(na ? del[i] : a->dims[i] == 1)) dims[rank++] = a->dims[i];
  }
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, a->dtype, dims, (size_t)rank);
  if (st) return st;
  if (elements(y) != elements(a)) return fail("zf_rt: %s changes the element count", n->name);
  memcpy(y->data, a->data, elements(a) * dtype_size(a->dtype));
  return NULL;
}

static OrtStatus *run_tile(OrtSession *s, RtNode *n) {
  const OrtValue *a = &s->slots[n->in[0]].value;
  int64_t rep[RT_MAX_RANK], dims[RT_MAX_RANK];
  if (rt_int64s(s, n->in[1], rep, RT_MAX_RANK) != a->rank)
    return fail("zf_rt: %s needs one constant repeat per axis", n->name);
  for (int i = 0; i < a->rank; ++i) dims[i] = a->dims[i] * rep[i];
  OrtValue *y = &s->slots[n->out[0]].value;
  OrtStatus *st = ensure(y, a->dtype, dims, (size_t)a->rank);
  if (st) return st;
  /* The trailing axes that are not repeated are one contiguous block in both tensors: V4's 40 to 20
   * ms upsampling ([1, T, 1, 512] tiled [1, 1, 2, 1]) is 2T blocks of 512 floats. Each block is found
   * from its source by index as before and copied whole. The element-by-element loop this replaces
   * (an index decomposition and a 4-byte memcpy per value) cost 1.85 ms of a 61 ms c16 chunk on the
   * Alcatel 1, single-threaded; the bytes copied are the same. */
  int inner_axis = a->rank;
  size_t inner = 1;
  while (inner_axis > 0 && rep[inner_axis - 1] == 1) {
    --inner_axis;
    inner *= (size_t)a->dims[inner_axis];
  }
  const size_t esz = dtype_size(a->dtype), total = elements(y), block = inner * esz;
  for (size_t o = 0; o < total; o += inner) { /* each block from its source by index */
    size_t rem = o / inner, src = 0, stride = inner;
    for (int r = inner_axis - 1; r >= 0; --r) {
      const size_t c = rem % (size_t)dims[r];
      rem /= (size_t)dims[r];
      src += (c % (size_t)a->dims[r]) * stride;
      stride *= (size_t)a->dims[r];
    }
    memcpy((char *)y->data + o * esz, (const char *)a->data + src * esz, block);
  }
  return NULL;
}

/* every standard node this runner implements */
static OrtStatus *run_standard(OrtSession *s, RtNode *n) {
  if (!strcmp(n->op, "Concat")) return run_concat(s, n);
  if (!strcmp(n->op, "Add")) return run_add(s, n);
  if (!strcmp(n->op, "LogSoftmax")) return run_log_softmax(s, n);
  if (!strcmp(n->op, "Softmax")) return run_softmax(s, n);
  if (!strcmp(n->op, "Sigmoid")) return run_sigmoid(s, n);
  if (!strcmp(n->op, "Mul")) return run_mul(s, n);
  if (!strcmp(n->op, "Unsqueeze") || !strcmp(n->op, "Squeeze") || !strcmp(n->op, "Reshape"))
    return run_reshape_like(s, n);
  if (!strcmp(n->op, "Tile")) return run_tile(s, n);
  return fail("zf_rt: no implementation of %s", n->op);
}

/* ---------------------------------------------------------------------------------- run */

/* The nodes a Run needs: those that feed one of the outputs it asks for, as ONNX Runtime prunes a
 * graph to the requested outputs. A V4 caller that wants only the default heads then skips the
 * other heads' linears, softmaxes and copies (inter4, id, conf, the attribute heads); the nodes that
 * do run are the same nodes on the same inputs, so every output computed is the same bits as when
 * everything runs. Every node with carried state (the encoder layers' caches, the front end) feeds
 * log_probs and the new_ states, which every caller asks for, so skipping never changes a state.
 * Asking for every output makes every node live: the 1.x behaviour, unchanged.
 *
 * Computed once per distinct request (a stream asks the same thing every chunk) and kept. */
static const unsigned char *rt_live(OrtSession *s, const char *const *out_names, size_t n_out) {
  if (s->live && s->live_n == n_out) {
    size_t i = 0;
    while (i < n_out && !strcmp(s->live_names[i], out_names[i])) ++i;
    if (i == n_out) return s->live;
  }
  unsigned char *need = (unsigned char *)calloc((size_t)s->n_slots + 1, 1);
  unsigned char *live = (unsigned char *)calloc((size_t)s->n_nodes + 1, 1);
  char **names = (char **)calloc(n_out + 1, sizeof(char *));
  if (!need || !live || !names) {
    free(need);
    free(live);
    free(names);
    return NULL;
  }
  for (size_t o = 0; o < n_out; ++o) {
    const int slot = slot_of(s, out_names[o], 0);
    if (slot >= 0) need[slot] = 1;
  }
  int last = -1;
  for (int i = s->n_nodes - 1; i >= 0; --i) {
    const RtNode *n = &s->nodes[i];
    for (int o = 0; o < n->n_out && !live[i]; ++o) live[i] = need[n->out[o]];
    if (!live[i]) continue;
    if (last < 0) last = i;
    for (int k = 0; k < n->n_in; ++k)
      if (n->in[k] >= 0) need[n->in[k]] = 1;
  }
  free(need);
  for (size_t o = 0; o < n_out; ++o) names[o] = strdup(out_names[o]);
  for (size_t i = 0; i < s->live_n; ++i) free(s->live_names[i]);
  free(s->live_names);
  free(s->live);
  s->live = live;
  s->live_names = names;
  s->live_n = n_out;
  s->live_last = last;
  return live;
}

static OrtStatus *rt_run_nodes(OrtSession *s, const char *const *in_names,
                               const OrtValue *const *inputs, size_t n_in,
                               const char *const *out_names, size_t n_out, OrtValue **outputs);

static OrtStatus *ORT_API_CALL rt_run(OrtSession *s, const OrtRunOptions *ro,
                                      const char *const *in_names, const OrtValue *const *inputs,
                                      size_t n_in, const char *const *out_names, size_t n_out,
                                      OrtValue **outputs) {
  (void)ro;
  const unsigned long fpcr = zf_fp_enter(); /* ARMv7 NEON's flush-to-zero and default NaN */
  OrtStatus *result = rt_run_nodes(s, in_names, inputs, n_in, out_names, n_out, outputs);
  zf_fp_leave(fpcr);
  return result;
}

/* Verification taps, for comparing this runner's arithmetic with another build or ONNX Runtime.
 *
 *   ZF_RT_DUMP=<dir>      every float output of every node of one Run, as <dir>/<node>_<tensor>.f32
 *   ZF_RT_DUMP_RUN=<n>    which Run (chunk) to dump, default 0
 *   ZF_RT_LOGP=<file>     the float outputs of each Run's last node (the log-probs), appended
 *
 * Off (one cached getenv) unless set, and read-only: they never touch the arithmetic. Development
 * builds only: a release build (ZF_RELEASE) reads no environment, and one process's streams share
 * the run count, so a dump wants one stream. */
static void rt_write_value(FILE *f, const OrtValue *v) {
  if (v->dtype != 1 || !v->data) return; /* float tensors only */
  size_t count = 1;
  for (int r = 0; r < v->rank; ++r) count *= (size_t)v->dims[r];
  fwrite(v->data, sizeof(float), count, f);
}

static void rt_taps(const OrtSession *s, const RtNode *n, int index, int last) {
  static int ready = 0, dump_run = 0, run = 0;
  static const char *dump_dir = NULL;
  static FILE *logp = NULL;
  if (!ready) {
    ready = 1;
    dump_dir = zf_getenv("ZF_RT_DUMP");
    const char *r = zf_getenv("ZF_RT_DUMP_RUN");
    dump_run = r ? atoi(r) : 0;
    const char *l = zf_getenv("ZF_RT_LOGP");
    if (l) logp = fopen(l, "wb");
  }
  if (dump_dir && run == dump_run) {
    for (int o = 0; o < n->n_out; ++o) {
      char name[160], path[512];
      snprintf(name, sizeof name, "%s", s->slots[n->out[o]].name);
      for (char *c = name; *c; ++c)
        if (*c == '/') *c = '_';
      snprintf(path, sizeof path, "%s/%03d_%s.f32", dump_dir, index, name);
      FILE *f = fopen(path, "wb");
      if (f) { rt_write_value(f, &s->slots[n->out[o]].value); fclose(f); }
    }
  }
  if (last) {
    if (logp) {
      for (int o = 0; o < n->n_out; ++o) rt_write_value(logp, &s->slots[n->out[o]].value);
      fflush(logp);
    }
    ++run;
  }
}

/* Per-node wall time, for finding where a chunk goes (ZF_RT_PROF=<file>, development builds only).
 *
 * Each node's time on the calling thread is summed over every Run of the process and written to
 * <file> at exit as "index op name calls ms", one node a line, in graph order. A node's time includes
 * the pool work it fans out, so the lines add up to the chunk. Off (one cached getenv) unless set;
 * the clock reads are outside the arithmetic. */
#include <time.h>
#define RT_PROF_MAX 512
static struct {
  int on;
  int n;
  char op[RT_PROF_MAX][32];
  char name[RT_PROF_MAX][96];
  double ms[RT_PROF_MAX];
  unsigned long calls[RT_PROF_MAX];
  const char *path;
} g_prof;
static double rt_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}
static void rt_prof_write(void) {
  FILE *f = fopen(g_prof.path, "w");
  if (!f) return;
  for (int i = 0; i < g_prof.n; ++i)
    fprintf(f, "%d %s %s %lu %.3f\n", i, g_prof.op[i], g_prof.name[i], g_prof.calls[i], g_prof.ms[i]);
  fclose(f);
}
static int rt_prof_on(void) {
  if (!g_prof.on) {
    g_prof.path = zf_getenv("ZF_RT_PROF");
    g_prof.on = g_prof.path ? 1 : -1;
    if (g_prof.on > 0) atexit(rt_prof_write);
  }
  return g_prof.on > 0;
}
static void rt_prof_add(const RtNode *n, int i, double ms) {
  if (i >= RT_PROF_MAX) return;
  if (i >= g_prof.n) {
    for (int k = g_prof.n; k <= i; ++k) g_prof.op[k][0] = g_prof.name[k][0] = 0;
    g_prof.n = i + 1;
  }
  if (!g_prof.op[i][0]) {
    snprintf(g_prof.op[i], sizeof g_prof.op[i], "%s", n->op);
    snprintf(g_prof.name[i], sizeof g_prof.name[i], "%s", n->name);
  }
  g_prof.ms[i] += ms;
  g_prof.calls[i] += 1;
}

static OrtStatus *rt_run_nodes(OrtSession *s, const char *const *in_names,
                               const OrtValue *const *inputs, size_t n_in,
                               const char *const *out_names, size_t n_out, OrtValue **outputs) {
  const int prof = rt_prof_on();
  for (size_t i = 0; i < n_in; ++i) {
    const int slot = slot_of(s, in_names[i], 0);
    if (slot < 0) return fail("zf_rt: unknown input %s", in_names[i]);
    OrtValue *v = &s->slots[slot].value;
    if (v->owned) free(v->data);
    *v = *inputs[i];
    v->owned = 0;
  }
  const unsigned char *live = rt_live(s, out_names, n_out);
  if (!live) return rt_create_status(ORT_FAIL, "out of memory");
  OrtKernelContext ctx = {s, NULL};
  for (int i = 0; i < s->n_nodes; ++i) {
    RtNode *n = &s->nodes[i];
    if (!live[i]) continue; /* feeds nothing this Run asked for */
    OrtStatus *st = NULL;
    const double t0 = prof ? rt_now_ms() : 0.0;
    if (n->custom) {
      ctx.node = n;
      st = n->custom->KernelComputeV2(n->kernel, &ctx);
    } else {
      st = run_standard(s, n);
    }
    if (st) return st;
    if (prof) rt_prof_add(n, i, rt_now_ms() - t0);
    rt_taps(s, n, i, i == s->live_last);
  }
  for (size_t o = 0; o < n_out; ++o) {
    const int slot = slot_of(s, out_names[o], 0);
    if (slot < 0) return fail("zf_rt: unknown output %s", out_names[o]);
    /* a view of the session's buffer, valid until the next Run, which is how the harnesses use it */
    OrtValue *v = (OrtValue *)malloc(sizeof *v);
    if (!v) return rt_create_status(ORT_FAIL, "out of memory");
    *v = s->slots[slot].value;
    v->owned = 0;
    outputs[o] = v;
  }
  return NULL;
}

/* ------------------------------------------------------------------------ batched chunks */

/* zf_rt_run_batch: B consecutive chunks through the graph node by node rather than chunk by chunk.
 *
 * Every node runs for chunk 0, 1, ..., B-1 before the next node runs at all. A node's internal
 * state (the encoder layers' caches, the front end's carried rows) therefore advances exactly as it
 * would chunk by chunk, and each chunk's arithmetic is the same operations on the same values: the
 * outputs are the same bits. What changes is that a node's weights are read from memory once per
 * batch instead of once per chunk; a layer's 4 MB then stays in cache for the other B-1 chunks,
 * which is most of what a chunk costs on a desktop where 66 MB of weights do not fit the L3.
 *
 * Every tensor that varies by chunk (graph inputs and node outputs; initializers are shared) gets a
 * value per chunk. Chunk 0 takes the caller's inputs. For b > 0 an input X with a graph output
 * new_X takes chunk b-1's new_X (the state the caller would carry between Runs), x takes the
 * caller's window b, and any other input is chunk 0's. That is only well defined when new_X is
 * produced no later than X is first consumed, which is checked; a graph where it is not returns
 * ORT_NOT_IMPLEMENTED and the caller runs its chunks one at a time. */
static int rt_is_per_chunk(const OrtSession *s, int slot) {
  for (int i = 0; i < s->n_inputs; ++i)
    if (s->inputs[i] == slot) return 1;
  for (int i = 0; i < s->n_nodes; ++i)
    for (int o = 0; o < s->nodes[i].n_out; ++o)
      if (s->nodes[i].out[o] == slot) return 1;
  return 0;
}

/* the output slot new_<name of input slot>, or -1 */
static int rt_state_out(const OrtSession *s, int in_slot) {
  char want[168];
  snprintf(want, sizeof want, "new_%s", s->slots[in_slot].name);
  for (int i = 0; i < s->n_outputs; ++i)
    if (!strcmp(s->slots[s->outputs[i]].name, want)) return s->outputs[i];
  return -1;
}

static int rt_producer(const OrtSession *s, int slot) {
  for (int i = 0; i < s->n_nodes; ++i)
    for (int o = 0; o < s->nodes[i].n_out; ++o)
      if (s->nodes[i].out[o] == slot) return i;
  return -1;
}

/* ort_ops.c's lockstep for the encoder layers (absent when zf_rt runs other kernels) */
#if defined(__GNUC__)
#define ZF_WEAK __attribute__((weak))
#else
#define ZF_WEAK
#endif
int zf_ops_defer_begin(const OrtCustomOp *op, void *kernel) ZF_WEAK;
OrtStatus *zf_ops_defer_end(const OrtCustomOp *op, void *kernel, int lanes) ZF_WEAK;

OrtStatus *zf_rt_run_batch(OrtSession *s, int B, const char *const *in_names,
                           const OrtValue *const *inputs, size_t n_in, const char *x_name,
                           const float *const *x_chunks, const char *const *out_names,
                           size_t n_out, OrtValue **outputs) {
  if (B < 1) return rt_create_status(ORT_INVALID_ARGUMENT, "zf_rt: batch");
  const int x_slot = slot_of(s, x_name, 0);
  if (x_slot < 0) return fail("zf_rt: unknown input %s", x_name);
  /* every state input must be produced no later than its first consumer */
  for (int i = 0; i < s->n_inputs; ++i) {
    const int in = s->inputs[i], so = rt_state_out(s, in);
    if (so < 0) continue;
    const int prod = rt_producer(s, so);
    for (int n = 0; n < s->n_nodes && prod >= 0; ++n)
      for (int k = 0; k < s->nodes[n].n_in; ++k)
        if (s->nodes[n].in[k] == in && n < prod)
          return rt_create_status(ORT_NOT_IMPLEMENTED, "zf_rt: state consumed before produced");
  }
  if (B > s->bcap) {
    OrtValue *nv = (OrtValue *)calloc((size_t)B * s->n_slots, sizeof *nv);
    if (!nv) return rt_create_status(ORT_FAIL, "out of memory");
    if (s->bvals) memcpy(nv, s->bvals, (size_t)s->bcap * s->n_slots * sizeof *nv);
    free(s->bvals);
    s->bvals = nv;
    s->bcap = B;
  }
  OrtValue *V = s->bvals;
  const int NS = s->n_slots;
  /* buffers an unbatched Run left in the shared slots: the chunks own their own from here */
  for (int k = 0; k < NS; ++k)
    if (rt_is_per_chunk(s, k)) {
      if (s->slots[k].value.owned) free(s->slots[k].value.data);
      memset(&s->slots[k].value, 0, sizeof(OrtValue));
    }
  /* chunk 0's inputs; later chunks' x */
  for (size_t i = 0; i < n_in; ++i) {
    const int slot = slot_of(s, in_names[i], 0);
    if (slot < 0) return fail("zf_rt: unknown input %s", in_names[i]);
    for (int b = 0; b < B; ++b) {
      OrtValue *v = &V[(size_t)b * NS + slot];
      if (v->owned) free(v->data);
      *v = *inputs[i];
      v->owned = 0;
      if (b > 0 && slot == x_slot) v->data = (void *)x_chunks[b];
    }
  }
  const unsigned char *live = rt_live(s, out_names, n_out);
  if (!live) return rt_create_status(ORT_FAIL, "out of memory");
  const unsigned long fpcr = zf_fp_enter();
  OrtKernelContext ctx = {s, NULL};
  OrtStatus *st = NULL;
  for (int i = 0; i < s->n_nodes && !st; ++i) {
    RtNode *n = &s->nodes[i];
    if (!live[i]) continue; /* feeds nothing this batch asked for */
    /* a node that runs its chunks together records them here and computes at the end */
    const int lanes = n->custom && B > 1 && zf_ops_defer_begin && !zf_getenv("ZF_RT_DUMP")
                          ? zf_ops_defer_begin(n->custom, n->kernel) : 0;
    for (int b = 0; b < B && !st; ++b) {
      OrtValue *vb = V + (size_t)b * NS;
      for (int k = 0; k < n->n_in; ++k) {
        const int in = n->in[k];
        if (in < 0) continue;
        if (b > 0) {
          const int so = rt_state_out(s, in);
          if (so >= 0) { vb[in] = V[(size_t)(b - 1) * NS + so]; vb[in].owned = 0; }
        }
        if (rt_is_per_chunk(s, in)) {
          s->slots[in].value = vb[in];
          s->slots[in].value.owned = 0; /* a view: the chunk keeps the buffer */
        }
      }
      for (int o = 0; o < n->n_out; ++o) s->slots[n->out[o]].value = vb[n->out[o]];
      if (n->custom) {
        ctx.node = n;
        st = n->custom->KernelComputeV2(n->kernel, &ctx);
      } else {
        st = run_standard(s, n);
      }
      if (!st) rt_taps(s, n, i, i == s->live_last);
      /* the chunk keeps its outputs (and their buffers); the shared slots let go of them */
      for (int o = 0; o < n->n_out; ++o) {
        vb[n->out[o]] = s->slots[n->out[o]].value;
        memset(&s->slots[n->out[o]].value, 0, sizeof(OrtValue));
      }
    }
    if (lanes) {
      OrtStatus *e = zf_ops_defer_end(n->custom, n->kernel, lanes);
      if (!st) st = e;
      else if (e) rt_release_status(e);
    }
  }
  zf_fp_leave(fpcr);
  /* leave no shared slot pointing at a chunk's buffer */
  for (int k = 0; k < NS; ++k)
    if (rt_is_per_chunk(s, k)) memset(&s->slots[k].value, 0, sizeof(OrtValue));
  if (st) return st;
  for (int b = 0; b < B; ++b)
    for (size_t o = 0; o < n_out; ++o) {
      const int slot = slot_of(s, out_names[o], 0);
      if (slot < 0) return fail("zf_rt: unknown output %s", out_names[o]);
      OrtValue *v = (OrtValue *)malloc(sizeof *v);
      if (!v) return rt_create_status(ORT_FAIL, "out of memory");
      *v = V[(size_t)b * NS + slot];
      v->owned = 0; /* a view of the chunk's buffer, valid until the next batch */
      outputs[(size_t)b * n_out + o] = v;
    }
  return NULL;
}

/* ------------------------------------------------------------------------------ the API */

/* the API table, filled once: two streams may ask for it at the same time */
static pthread_once_t g_rt_once = PTHREAD_ONCE_INIT;

static void rt_fill(void) {
  memset(&g_rt, 0, sizeof g_rt);
  g_rt.CreateStatus = rt_create_status;
  g_rt.GetErrorCode = rt_get_error_code;
  g_rt.GetErrorMessage = rt_get_error_message;
  g_rt.ReleaseStatus = rt_release_status;
  g_rt.CreateEnv = rt_create_env;
  g_rt.ReleaseEnv = rt_release_env;
  g_rt.CreateSessionOptions = rt_create_session_options;
  g_rt.ReleaseSessionOptions = rt_release_session_options;
  g_rt.SetIntraOpNumThreads = rt_set_threads;
  g_rt.SetInterOpNumThreads = rt_set_threads;
  g_rt.SetSessionGraphOptimizationLevel = rt_set_opt_level;
  g_rt.EnableProfiling = rt_enable_profiling;
  g_rt.CreateCustomOpDomain = rt_create_domain;
  g_rt.CustomOpDomain_Add = rt_domain_add;
  g_rt.AddCustomOpDomain = rt_add_domain;
  g_rt.ReleaseCustomOpDomain = rt_release_domain;
  g_rt.GetAllocatorWithDefaultOptions = rt_get_allocator;
  g_rt.CreateCpuMemoryInfo = rt_create_cpu_memory_info;
  g_rt.ReleaseMemoryInfo = rt_release_memory_info;
  g_rt.CreateTensorWithDataAsOrtValue = rt_create_tensor_with_data;
  g_rt.ReleaseValue = rt_release_value;
  g_rt.GetTensorMutableData = rt_get_mutable_data;
  g_rt.GetTensorData = rt_get_data;
  g_rt.GetTensorTypeAndShape = rt_get_type_and_shape;
  g_rt.ReleaseTensorTypeAndShapeInfo = rt_release_tsinfo;
  g_rt.CreateTensorTypeAndShapeInfo = rt_create_tsinfo;
  g_rt.SetTensorElementType = rt_set_elem_type;
  g_rt.SetDimensions = rt_set_dims;
  g_rt.GetTensorElementType = rt_get_elem_type;
  g_rt.GetDimensionsCount = rt_get_dims_count;
  g_rt.GetDimensions = rt_get_dims;
  g_rt.GetTensorShapeElementCount = rt_get_elem_count;
  g_rt.CastTypeInfoToTensorInfo = rt_cast_type_info;
  g_rt.ReleaseTypeInfo = rt_release_type_info;
  g_rt.KernelInfoGetAttribute_int64 = rt_attr_i64;
  g_rt.KernelInfoGetAttribute_float = rt_attr_f32;
  g_rt.KernelInfoGetAttribute_string = rt_attr_str;
  g_rt.KernelInfoGetAttributeArray_int64 = rt_attr_ints;
  g_rt.KernelContext_GetInputCount = rt_ctx_input_count;
  g_rt.KernelContext_GetInput = rt_ctx_input;
  g_rt.KernelContext_GetOutput = rt_ctx_output;
  g_rt.KernelContext_ParallelFor = rt_parallel_for;
  g_rt.CreateSession = rt_create_session;
  g_rt.ReleaseSession = rt_release_session;
  g_rt.SessionGetInputCount = rt_input_count;
  g_rt.SessionGetOutputCount = rt_output_count;
  g_rt.SessionGetInputName = rt_input_name;
  g_rt.SessionGetOutputName = rt_output_name;
  g_rt.SessionGetInputTypeInfo = rt_input_type;
  g_rt.SessionGetOutputTypeInfo = rt_output_type;
  g_rt.SessionGetModelMetadata = rt_get_metadata;
  g_rt.ReleaseModelMetadata = rt_release_metadata;
  g_rt.ModelMetadataLookupCustomMetadataMap = rt_lookup_metadata;
  g_rt.SessionEndProfiling = rt_end_profiling;
  g_rt.Run = rt_run;
}

static const OrtApi *ORT_API_CALL rt_get_api(uint32_t version) NO_EXCEPTION {
  if (version > ORT_API_VERSION) return NULL;
  pthread_once(&g_rt_once, rt_fill);
  return &g_rt;
}

static const char *ORT_API_CALL rt_version(void) NO_EXCEPTION { return "zf_rt"; }

static const OrtApiBase g_base = {rt_get_api, rt_version};

const OrtApiBase *ORT_API_CALL OrtGetApiBase(void) NO_EXCEPTION { return &g_base; }
