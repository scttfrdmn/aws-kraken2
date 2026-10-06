// Oracle harness for internal/classify. Built by scripts/harness-build.sh against upstream
// DerrickWood/kraken2 src/ at 2731b35f7abb26ec926517274f3d87e78d42fd76 (not in the core path).
// Original sources: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Harness: Copyright 2026 aws-kraken2 contributors. MIT License.
//
// Runs upstream's own FastReader, MinimizerScanner, CompactHashTable and Taxonomy over real
// reads and writes, per read, the event stream classify.cc's ClassifySequence consumes: for each
// mate, every (minimizer, ambiguous) the scanner yields, in order, with the value upstream's
// table returns for that minimizer (0 for ambiguous events). It does no classification itself.
//
// Usage: classify_trace <db-dir> <trace-out> <taxonomy-dump-out> <reads_1> [reads_2]
//
// Trace format, little-endian:
//   "K2TRACE1"  u64 minimum_acceptable_hash_value  u8 dna_db  u8 paired
//   per read:   u32 id_len, id bytes (SeqView header: identifier up to first whitespace)
//               per mate (1, or 2 when paired): u32 seq_len, u32 n, then n events of
//                 u64 minimizer, u8 ambiguous, u32 value
// Taxonomy dump, text, one line per internal ID i in [0, node_count):
//   i \t parent_id \t external_id \t name

#include "kraken2_headers.h"
#include "kv_store.h"
#include "taxonomy.h"
#include "fast_reader.h"
#include "mmscanner.h"
#include "compact_hash.h"
#include "kraken2_data.h"

using namespace kraken2;

static void put(FILE *f, const void *p, size_t n) {
  if (fwrite(p, 1, n, f) != n)
    errx(1, "write failed");
}
template <class T> static void put(FILE *f, T v) { put(f, &v, sizeof(v)); }

static void EmitMate(FILE *f, MinimizerScanner &scanner, KeyValueStore *cht,
                     const SeqView &v) {
  static std::vector<uint64_t> mins;
  static std::vector<uint8_t> ambs;
  mins.clear();
  ambs.clear();
  scanner.LoadSequence(v.seq, v.seq_len);
  uint64_t *m;
  while ((m = scanner.NextMinimizer()) != nullptr) {
    mins.push_back(*m);
    ambs.push_back(scanner.is_ambiguous() ? 1 : 0);
  }
  put<uint32_t>(f, v.seq_len);
  put<uint32_t>(f, (uint32_t) mins.size());
  for (size_t i = 0; i < mins.size(); i++) {
    put<uint64_t>(f, mins[i]);
    put<uint8_t>(f, ambs[i]);
    put<uint32_t>(f, ambs[i] ? 0 : cht->Get(mins[i]));
  }
}

int main(int argc, char **argv) {
  if (argc != 5 && argc != 6)
    errx(64, "usage: classify_trace <db-dir> <trace-out> <taxonomy-dump-out> <reads_1> [reads_2]");
  std::string db = argv[1];
  std::string opts_fn = db + "/opts.k2d", hash_fn = db + "/hash.k2d", taxo_fn = db + "/taxo.k2d";
  bool paired = argc == 6;

  IndexOptions idx_opts = {0};
  {
    struct stat sb;
    if (stat(opts_fn.c_str(), &sb) < 0)
      errx(1, "stat %s", opts_fn.c_str());
    std::ifstream ifs(opts_fn);
    ifs.read((char *) &idx_opts, sb.st_size);
  }
  Taxonomy taxonomy(taxo_fn, false);
  KeyValueStore *cht = nullptr;
  switch (GetKVStoreCellType(hash_fn)) {
  case CompactHash32: cht = new CompactHashTable<CompactHashCell>(hash_fn, false); break;
  case CompactHash40: cht = new CompactHashTable<CompactHashCell40>(hash_fn, false); break;
  default: errx(1, "unknown cell type");
  }

  FILE *tf = fopen(argv[3], "w");
  if (! tf)
    errx(1, "open %s", argv[3]);
  for (size_t i = 0; i < taxonomy.node_count(); i++) {
    const TaxonomyNode &n = taxonomy.nodes()[i];
    fprintf(tf, "%zu\t%llu\t%llu\t%s\n", i, (unsigned long long) n.parent_id,
            (unsigned long long) n.external_id, taxonomy.name_data() + n.name_offset);
  }
  fclose(tf);

  FILE *out = fopen(argv[2], "w");
  if (! out)
    errx(1, "open %s", argv[2]);
  static char obuf[1 << 20];
  setvbuf(out, obuf, _IOFBF, sizeof(obuf));
  put(out, "K2TRACE1", 8);
  put<uint64_t>(out, idx_opts.minimum_acceptable_hash_value);
  put<uint8_t>(out, idx_opts.dna_db ? 1 : 0);
  put<uint8_t>(out, paired ? 1 : 0);

  MinimizerScanner scanner(idx_opts.k, idx_opts.l, idx_opts.spaced_seed_mask,
                           idx_opts.dna_db, idx_opts.toggle_mask, idx_opts.revcom_version);
  int fd1 = open(argv[4], O_RDONLY);
  int fd2 = paired ? open(argv[5], O_RDONLY) : -1;
  if (fd1 < 0 || (paired && fd2 < 0))
    errx(1, "open reads");
  StreamCursor c1, c2;
  PrimeStream(fd1, c1);
  if (paired)
    PrimeStream(fd2, c2);
  FastReader r1, r2;
  uint64_t reads = 0;
  while (r1.LoadBlock(fd1, c1, 8 * 1024 * 1024)) {
    if (paired && ! r2.LoadRecords(fd2, c2, r1.RecordCount()))
      break;
    r1.Parse();
    if (paired)
      r2.Parse();
    size_t n = r1.size();
    if (paired && r2.size() < n)
      n = r2.size();
    for (size_t i = 0; i < n; i++) {
      const SeqView &a = r1[i];
      put<uint32_t>(out, a.header_len);
      put(out, a.header, a.header_len);
      EmitMate(out, scanner, cht, a);
      if (paired)
        EmitMate(out, scanner, cht, r2[i]);
      reads++;
    }
  }
  fclose(out);
  fprintf(stderr, "classify_trace: %llu reads, k=%zu l=%zu min_hash=%llu dna=%d\n",
          (unsigned long long) reads, idx_opts.k, idx_opts.l,
          (unsigned long long) idx_opts.minimum_acceptable_hash_value, (int) idx_opts.dna_db);
  delete cht;
  return 0;
}
