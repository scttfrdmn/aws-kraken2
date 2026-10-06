// Oracle harness for internal/taxo: dumps a taxo.k2d through upstream's own Taxonomy class.
// Copyright 2026 aws-kraken2 contributors. MIT License.
// Links against DerrickWood/kraken2 src/taxonomy.cc at the pin (scripts/harness-build.sh).
//
// Usage: taxo_dump <taxo.k2d> [pairs]
// Output (one record per line, tab-separated):
//   header  <node_count> <name_data_len> <rank_data_len>
//   node    <i> <parent_id> <first_child> <child_count> <name_offset> <rank_offset>
//           <external_id> <godparent_id> <rank> <name>
//   int     <external_id> <GetInternalID(external_id)>     for every node's external ID and 0
//   pair    <a> <b> <IsAAncestorOfB(a,b)> <IsAAncestorOfB(b,a)> <LowestCommonAncestor(a,b)>
// Pairs: every (x,0), (0,x), (x,x), (x,parent(x)) for all x, then <pairs> pseudo-random pairs
// drawn with the LCG in the Go twin (internal/taxo oracle_test.go).
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <string>
#include "taxonomy.h"

using namespace kraken2;

static uint64_t lcg_state = 0x9E3779B97F4A7C15ULL;
static uint64_t next_rand() {
  lcg_state = lcg_state * 6364136223846793005ULL + 1442695040888963407ULL;
  return lcg_state >> 11;
}

static void pair(const Taxonomy &t, uint64_t a, uint64_t b) {
  printf("pair\t%" PRIu64 "\t%" PRIu64 "\t%d\t%d\t%" PRIu64 "\n", a, b,
         (int) t.IsAAncestorOfB(a, b), (int) t.IsAAncestorOfB(b, a),
         t.LowestCommonAncestor(a, b));
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <taxo.k2d> [pairs]\n", argv[0]);
    return 2;
  }
  uint64_t npairs = argc > 2 ? strtoull(argv[2], nullptr, 10) : 0;
  Taxonomy t(argv[1]);
  t.GenerateExternalToInternalIDMap();
  const TaxonomyNode *nodes = t.nodes();
  size_t n = t.node_count();
  // name_data_len_/rank_data_len_ are private; recompute from the file header.
  FILE *f = fopen(argv[1], "rb");
  char magic[8];
  uint64_t hdr[3];
  if (!f || fread(magic, 1, 8, f) != 8 || fread(hdr, 8, 3, f) != 3) {
    fprintf(stderr, "cannot reread header\n");
    return 1;
  }
  fclose(f);
  printf("header\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64 "\n", (uint64_t) n, hdr[1], hdr[2]);
  for (size_t i = 0; i < n; i++) {
    const TaxonomyNode &d = nodes[i];
    printf("node\t%zu\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64 "\t%" PRIu64
           "\t%" PRIu64 "\t%" PRIu64 "\t%s\t%s\n",
           i, d.parent_id, d.first_child, d.child_count, d.name_offset, d.rank_offset,
           d.external_id, d.godparent_id, t.rank_data() + d.rank_offset,
           t.name_data() + d.name_offset);
  }
  printf("int\t0\t%" PRIu64 "\n", t.GetInternalID(0));
  for (size_t i = 1; i < n; i++)
    printf("int\t%" PRIu64 "\t%" PRIu64 "\n", nodes[i].external_id,
           t.GetInternalID(nodes[i].external_id));
  pair(t, 0, 0);
  for (size_t i = 1; i < n; i++) {
    pair(t, i, 0);
    pair(t, 0, i);
    pair(t, i, i);
    pair(t, i, nodes[i].parent_id);
  }
  for (uint64_t k = 0; k < npairs && n > 1; k++) {
    uint64_t a = 1 + next_rand() % (n - 1);
    uint64_t b = 1 + next_rand() % (n - 1);
    pair(t, a, b);
  }
  return 0;
}
