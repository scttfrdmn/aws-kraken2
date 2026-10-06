// Oracle harness for internal/chash (issue #4): builds a synthetic hash.k2d with upstream's own
// CompactHashTable (CompareAndSet, WriteTable), linked against DerrickWood/kraken2 at
// 2731b35f7abb26ec926517274f3d87e78d42fd76. Its purpose is the 40-bit cell path
// (CompactHashCell40), which neither pinned database uses: the table is built by upstream, then
// looked up by upstream (chash_dump) and by Go (k2probe equiv-hash).
// Copyright 2026 aws-kraken2 contributors. MIT License.
// Upstream code used here: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
//
// Usage: chash_build out.k2d capacity key_bits value_bits n seed keys.u64
//   Inserts n keys (splitmix64 from seed) with values in [1, 2^value_bits - 1], then writes
//   keys.u64: the n inserted keys followed by n further splitmix64 keys (mostly misses), uint64 LE.
//   The probe sequence is whatever this build of compact_hash.h has (-DLINEAR_PROBING or not), so
//   the .dh variant builds a double-hashing table.
// Synthetic data: a port check of the cell format, not a measurement (Law 3).

#include "kraken2_headers.h"
#include "kv_store.h"
#include "compact_hash.h"
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace kraken2;

static uint64_t splitmix64(uint64_t &s) {
  uint64_t z = (s += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}

template <typename Cell>
static int build(const char *out, size_t cap, size_t kb, size_t vb, size_t n, uint64_t seed,
                 const char *keys_out) {
  CompactHashTable<Cell> cht(cap, kb, vb);
  std::vector<uint64_t> keys;
  keys.reserve(2 * n);
  uint64_t s = seed;
  const uint64_t vmax = (1ULL << vb) - 1;
  for (size_t i = 0; i < n; i++) {
    uint64_t k = splitmix64(s);
    hvalue_t v = (hvalue_t) (splitmix64(s) % vmax) + 1;
    hvalue_t old = 0;
    cht.CompareAndSet(k, v, &old);  // an existing compacted key keeps its value, as in build_db
    keys.push_back(k);
  }
  for (size_t i = 0; i < n; i++)
    keys.push_back(splitmix64(s));
  cht.WriteTable(out);
  FILE *f = fopen(keys_out, "wb");
  if (!f || fwrite(keys.data(), sizeof(uint64_t), keys.size(), f) != keys.size() || fclose(f)) {
    perror(keys_out);
    return 1;
  }
  fprintf(stderr, "capacity=%zu\nsize=%zu\nkey_bits=%zu\nvalue_bits=%zu\ncell_bytes=%zu\nkeys=%zu\nseed=%llu\n",
          cap, (size_t) cht.size(), kb, vb, sizeof(Cell), keys.size(), (unsigned long long) seed);
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 8) {
    fprintf(stderr, "usage: chash_build out.k2d capacity key_bits value_bits n seed keys.u64\n");
    return 2;
  }
  size_t cap = strtoull(argv[2], nullptr, 10), kb = strtoull(argv[3], nullptr, 10),
         vb = strtoull(argv[4], nullptr, 10), n = strtoull(argv[5], nullptr, 10);
  uint64_t seed = strtoull(argv[6], nullptr, 10);
  if (kb + vb == 40)
    return build<CompactHashCell40>(argv[1], cap, kb, vb, n, seed, argv[7]);
  if (kb + vb == 32)
    return build<CompactHashCell>(argv[1], cap, kb, vb, n, seed, argv[7]);
  fprintf(stderr, "chash_build: key_bits + value_bits must be 32 or 40\n");
  return 2;
}
