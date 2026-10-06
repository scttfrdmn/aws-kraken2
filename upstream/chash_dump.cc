// Oracle harness for internal/chash (issue #4, G0b-1): upstream's CompactHashTable lookups with
// probe counts, linked against DerrickWood/kraken2 at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Copyright 2026 aws-kraken2 contributors. MIT License.
// Upstream code used here: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
//
// Usage: chash_dump [-m] hash.k2d < keys > out
//   keys: uint64 LE, one per key.  out: per key, uint32 LE value then uint32 LE probe count.
//   -m: load with upstream's memory-mapping path instead of LoadTable's read-into-RAM path.
//
// Values come from upstream's own Get(). Probe counts come from upstream's own FindIndex(): its
// final *idx is the matching cell, the empty cell that ended the search, or (after a full wrap)
// the home cell. We count cells examined by stepping from home to that idx with upstream's own
// second_hash(), and on a full wrap count the cycle length. second_hash() and table_ are private,
// so the least invasive access is to compile upstream's header with `private` defined as `public`
// (every system header it pulls in is included first, so only kraken2 classes are affected). No
// upstream line is copied or changed. GetBatch() is also run and checked against Get().
//
// stderr gets key=value lines: load and lookup timings, hits.

#include "kraken2_headers.h"
#include "kv_store.h"
#include "mmap_file.h"
#include "kraken2_data.h"
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <chrono>
#include <string>
#include <vector>

#define private public
#include "compact_hash.h"
#undef private

using namespace kraken2;

static double now_s() {
  return std::chrono::duration<double>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
}

template <typename Cell>
static int run(const char *path, bool mmap_load, const std::vector<uint64_t> &keys) {
  double t0 = now_s();
  CompactHashTable<Cell> cht(path, mmap_load);
  double t1 = now_s();
  const size_t n = keys.size();
  const size_t cap = cht.capacity_;
  const size_t vb = cht.value_bits_;

  std::vector<hvalue_t> vals(n), batch(n);
  double t2 = now_s();
  for (size_t i = 0; i < n; i++)
    vals[i] = cht.Get(keys[i]);
  double t3 = now_s();
  cht.GetBatch(keys.data(), batch.data(), n);
  double t4 = now_s();

  std::vector<uint32_t> out(2 * n);
  uint64_t hits = 0;
  for (size_t i = 0; i < n; i++) {
    if (batch[i] != vals[i])
      errx(1, "key %zu: GetBatch %u != Get %u", i, batch[i], vals[i]);
    size_t idx;
    bool found = cht.FindIndex(keys[i], &idx);
    uint64_t hc = MurmurHash3(keys[i]);
    size_t home = hc % cap;
    uint64_t step = cht.second_hash(hc);
    hvalue_t cell_val = cht.table_[idx].value(vb);
    if (found ? (cell_val != vals[i]) : (vals[i] != 0))
      errx(1, "key %zu: FindIndex (found=%d, cell value %u) disagrees with Get %u",
           i, (int) found, cell_val, vals[i]);
    bool wrapped = ! found && cell_val != 0;  // ended back at home, not on an empty cell
    if (wrapped && idx != home)
      errx(1, "key %zu: FindIndex ended on a non-empty, non-matching cell off home", i);
    uint64_t probes = 1;
    size_t j = home;
    if (wrapped) {
      while ((j = (j + step) % cap) != home) probes++;
    } else {
      while (j != idx) { j = (j + step) % cap; probes++; }
    }
    if (vals[i]) hits++;
    out[2 * i] = vals[i];
    out[2 * i + 1] = probes > UINT32_MAX ? UINT32_MAX : (uint32_t) probes;
  }
  if (fwrite(out.data(), sizeof(uint32_t), out.size(), stdout) != out.size())
    err(1, "write");
  fprintf(stderr, "capacity=%zu\nsize=%zu\nkey_bits=%zu\nvalue_bits=%zu\n",
          cap, cht.size_, cht.key_bits_, vb);
  fprintf(stderr, "cell_bytes=%zu\n", sizeof(Cell));
#ifdef LINEAR_PROBING
  fprintf(stderr, "mode=linear\n");
#else
  fprintf(stderr, "mode=double\n");
#endif
  fprintf(stderr, "load=%s\nload_s=%.3f\nkeys=%zu\nhits=%llu\n", mmap_load ? "mmap" : "ram",
          t1 - t0, n, (unsigned long long) hits);
  fprintf(stderr, "get_s=%.3f\nget_ns_per_key=%.1f\n", t3 - t2, n ? (t3 - t2) * 1e9 / n : 0.0);
  fprintf(stderr, "getbatch_s=%.3f\ngetbatch_ns_per_key=%.1f\n", t4 - t3,
          n ? (t4 - t3) * 1e9 / n : 0.0);
  return 0;
}

int main(int argc, char **argv) {
  bool mmap_load = false;
  int a = 1;
  if (a < argc && std::string(argv[a]) == "-m") { mmap_load = true; a++; }
  if (a + 1 != argc)
    errx(2, "usage: chash_dump [-m] hash.k2d < keys.u64 > out");
  std::string path = argv[a];

  std::vector<uint64_t> keys;
  uint64_t buf[1 << 16];
  size_t r;
  while ((r = fread(buf, sizeof(uint64_t), 1 << 16, stdin)) > 0)
    keys.insert(keys.end(), buf, buf + r);
  if (ferror(stdin))
    err(1, "read keys");

  switch (GetKVStoreCellType(path)) {
  case CompactHash32: return run<CompactHashCell>(path.c_str(), mmap_load, keys);
  case CompactHash40: return run<CompactHashCell40>(path.c_str(), mmap_load, keys);
  default: errx(1, "%s: unknown cell type", path.c_str());
  }
}
