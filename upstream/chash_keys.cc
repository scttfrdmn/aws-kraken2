// Key generator for the internal/chash equivalence run (issue #4, G0b-1): the real minimizer
// stream from upstream's own MinimizerScanner, linked against DerrickWood/kraken2 at
// 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Copyright 2026 aws-kraken2 contributors. MIT License.
// Upstream code used here: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
//
// Usage: chash_keys opts.k2d real.u64 random.u64 SEED reads.fq [reads.fq ...]
//
// real.u64: every minimizer classify would hand to the hash table, in read order: for each record
//   (upstream BatchSequenceReader), MinimizerScanner configured from opts.k2d exactly as classify
//   does, skipping ambiguous minimizers and those under minimum_acceptable_hash_value. Unlike
//   classify, consecutive repeats are NOT collapsed: this is the raw (non-ambiguous) stream, so
//   every lookup classify makes appears here at least once. uint64 LE.
// random.u64: the same number of keys, uniform over uint64 from splitmix64(SEED): a miss-heavy
//   control. Kept in a separate file so the two populations are never mixed up.
// stderr gets key=value counts.

#include "kraken2_headers.h"
#include "kraken2_data.h"
#include "kv_store.h"
#include "mmscanner.h"
#include "seqreader.h"

using namespace kraken2;

static uint64_t splitmix64(uint64_t &s) {
  uint64_t z = (s += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}

class Writer {
 public:
  explicit Writer(const char *path) : f_(fopen(path, "wb")) {
    if (! f_) err(1, "%s", path);
    buf_.reserve(1 << 16);
  }
  void put(uint64_t v) {
    buf_.push_back(v);
    if (buf_.size() == buf_.capacity()) flush();
  }
  void close() {
    flush();
    if (fclose(f_) != 0) err(1, "close");
  }
 private:
  void flush() {
    if (fwrite(buf_.data(), sizeof(uint64_t), buf_.size(), f_) != buf_.size()) err(1, "write");
    buf_.clear();
  }
  FILE *f_;
  std::vector<uint64_t> buf_;
};

int main(int argc, char **argv) {
  if (argc < 6)
    errx(2, "usage: chash_keys opts.k2d real.u64 random.u64 SEED reads.fq [reads.fq ...]");

  // Read opts.k2d exactly as classify's load_index does.
  IndexOptions idx_opts = {0};
  {
    struct stat sb;
    if (stat(argv[1], &sb) < 0) err(1, "%s", argv[1]);
    std::ifstream ifs(argv[1]);
    ifs.read((char *) &idx_opts, sb.st_size);
  }
  if (! idx_opts.dna_db)
    errx(1, "protein databases are not supported by this harness");
  uint64_t seed = strtoull(argv[4], nullptr, 0);

  MinimizerScanner scanner(idx_opts.k, idx_opts.l, idx_opts.spaced_seed_mask,
                           idx_opts.dna_db, idx_opts.toggle_mask,
                           idx_opts.revcom_version);
  Writer real(argv[2]);
  uint64_t records = 0, minimizers = 0, ambiguous = 0, skipped = 0, emitted = 0, lookups = 0;
  for (int a = 5; a < argc; a++) {
    BatchSequenceReader reader(argv[a]);
    Sequence seq;
    while (reader.NextSequence(seq)) {
      records++;
      scanner.LoadSequence(seq.seq);
      uint64_t last_minimizer = UINT64_MAX;
      uint64_t *mp;
      while ((mp = scanner.NextMinimizer()) != nullptr) {
        minimizers++;
        if (scanner.is_ambiguous()) { ambiguous++; continue; }
        bool repeat = *mp == last_minimizer;
        last_minimizer = *mp;
        if (idx_opts.minimum_acceptable_hash_value &&
            MurmurHash3(*mp) < idx_opts.minimum_acceptable_hash_value) {
          skipped++;
          continue;
        }
        if (! repeat) lookups++;
        real.put(*mp);
        emitted++;
      }
    }
  }
  real.close();

  Writer rnd(argv[3]);
  uint64_t s = seed;
  for (uint64_t i = 0; i < emitted; i++)
    rnd.put(splitmix64(s));
  rnd.close();

  fprintf(stderr, "k=%zu\nl=%zu\nspaced_seed_mask=0x%016llx\ntoggle_mask=0x%016llx\n",
          idx_opts.k, idx_opts.l, (unsigned long long) idx_opts.spaced_seed_mask,
          (unsigned long long) idx_opts.toggle_mask);
  fprintf(stderr, "minimum_acceptable_hash_value=%llu\nrevcom_version=%d\n",
          (unsigned long long) idx_opts.minimum_acceptable_hash_value, idx_opts.revcom_version);
  fprintf(stderr, "records=%llu\nminimizers=%llu\nambiguous=%llu\nskipped=%llu\n",
          (unsigned long long) records, (unsigned long long) minimizers,
          (unsigned long long) ambiguous, (unsigned long long) skipped);
  fprintf(stderr, "real_keys=%llu\nclassify_lookups=%llu\nrandom_keys=%llu\nseed=%llu\n",
          (unsigned long long) emitted, (unsigned long long) lookups,
          (unsigned long long) emitted, (unsigned long long) seed);
  return 0;
}
