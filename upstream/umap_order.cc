// Oracle harness for #44: a black-box record of the iteration order of upstream's
// taxon_counts_t (kraken2_data.h: std::unordered_map<taxid_t, uint64_t>), which ResolveTree
// (classify.cc) walks. The C++ standard library is used as a library: the harness performs the
// operations classify.cc performs on hit_counts and prints what iteration yields. Built against
// upstream DerrickWood/kraken2 src/ at 2731b35f7abb26ec926517274f3d87e78d42fd76 for the typedef
// (docs/hitorder.md; scripts/hitorder-golden.sh).
// Copyright 2026 aws-kraken2 contributors. MIT License.
//
// Usage: umap_order < ops > out
//   ops, one per line:  C          hit_counts.clear()                         (classify.cc:971)
//                       I <taxon>  hit_counts[taxon]++                        (classify.cc:1085)
//                       L <taxon>  (void) hit_counts[taxon], the rvalue lookup (classify.cc:927)
//                       P          print "P <bucket_count()> <taxon> <taxon> ..." in iteration order
// One process is one map's lifetime, as one classify.cc thread's.

#include "kraken2_data.h"
#include <cstdio>
#include <iostream>
#include <string>

using namespace kraken2;

int main() {
  taxon_counts_t m;
  std::string op;
  while (std::cin >> op) {
    if (op == "C") {
      m.clear();
    } else if (op == "I") {
      unsigned long long k;
      std::cin >> k;
      m[k]++;
    } else if (op == "L") {
      unsigned long long k;
      std::cin >> k;
      volatile uint64_t v = m[k];
      (void) v;
    } else if (op == "P") {
      std::printf("P %zu", m.bucket_count());
      for (auto &kv : m)
        std::printf(" %llu", (unsigned long long) kv.first);
      std::printf("\n");
    } else {
      std::fprintf(stderr, "umap_order: unknown op %s\n", op.c_str());
      return 2;
    }
  }
  return 0;
}
