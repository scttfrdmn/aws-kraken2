// Oracle harness for internal/mmscan (issue #5). Linked against DerrickWood/kraken2 at
// 2731b35f7abb26ec926517274f3d87e78d42fd76; uses upstream's own MinimizerScanner and the
// FastReader that classify.cc reads input with, and loads opts.k2d exactly as classify.cc's
// load_index does. Not in the core path. Build: scripts/harness-build.sh mm_dump.
//
// Usage: mm_dump [-k K] [-l L] [-s MASK] [-t MASK] [-R REVCOM] [-P] [-r] opts.k2d FILE...
//   -k/-l/-s/-t/-R override the opts.k2d fields (synthetic equivalence probes only)
//   -P  scan as protein (dna_db = false), feeding the bytes unchanged
//   -r  after each full-sequence record, also emit a LoadSequence(seq, start, finish) record
//
// Writes a little-endian binary stream to stdout (format "K2MMDMP1", see
// cmd/k2probe/equivscan.go) and the effective options as text on stderr.

#include "kraken2_headers.h"
#include "kraken2_data.h"
#include "mmscanner.h"
#include "fast_reader.h"

using namespace kraken2;

static void put(const void *p, size_t n) {
  if (fwrite(p, 1, n, stdout) != n)
    err(EX_IOERR, "write");
}
template <class T> static void putv(T v) { put(&v, sizeof(v)); }

static uint64_t g_records = 0, g_minimizers = 0;

static void emit(MinimizerScanner &scanner, const SeqView &v, uint8_t file_idx,
                 uint64_t start, uint64_t finish, std::vector<uint64_t> &mm,
                 std::vector<uint8_t> &amb) {
  mm.clear();
  amb.clear();
  scanner.LoadSequence(v.seq, v.seq_len, start, finish);
  uint64_t *p;
  while ((p = scanner.NextMinimizer()) != nullptr) {
    mm.push_back(*p);
    amb.push_back(scanner.is_ambiguous() ? 1 : 0);
  }
  putv<uint8_t>(1);
  putv<uint8_t>(file_idx);
  putv<uint32_t>(v.header_len);
  put(v.header, v.header_len);
  putv<uint32_t>(v.seq_len);
  put(v.seq, v.seq_len);
  putv<uint64_t>(start);
  putv<uint64_t>(finish);
  putv<uint32_t>((uint32_t) mm.size());
  for (size_t i = 0; i < mm.size(); i++) {
    putv<uint64_t>(mm[i]);
    putv<uint8_t>(amb[i]);
  }
  g_records++;
  g_minimizers += mm.size();
}

int main(int argc, char **argv) {
  long ok_k = -1, ok_l = -1, o_rv = -1;
  bool o_s = false, o_t = false, protein = false, ranges = false;
  uint64_t v_s = 0, v_t = 0;
  int c;
  while ((c = getopt(argc, argv, "k:l:s:t:R:Pr")) != -1) {
    switch (c) {
      case 'k': ok_k = strtol(optarg, nullptr, 10); break;
      case 'l': ok_l = strtol(optarg, nullptr, 10); break;
      case 's': o_s = true; v_s = strtoull(optarg, nullptr, 0); break;
      case 't': o_t = true; v_t = strtoull(optarg, nullptr, 0); break;
      case 'R': o_rv = strtol(optarg, nullptr, 10); break;
      case 'P': protein = true; break;
      case 'r': ranges = true; break;
      default: errx(EX_USAGE, "bad option");
    }
  }
  if (argc - optind < 2)
    errx(EX_USAGE, "usage: mm_dump [opts] opts.k2d FILE...");
  const char *opts_filename = argv[optind++];

  // As classify.cc load_index().
  IndexOptions idx_opts = {0};
  std::ifstream idx_opt_fs(opts_filename);
  struct stat sb;
  if (stat(opts_filename, &sb) < 0)
    errx(EX_OSERR, "unable to get filesize of %s", opts_filename);
  auto opts_filesize = sb.st_size;
  idx_opt_fs.read((char *) &idx_opts, opts_filesize);

  if (ok_k >= 0) idx_opts.k = ok_k;
  if (ok_l >= 0) idx_opts.l = ok_l;
  if (o_s) idx_opts.spaced_seed_mask = v_s;
  if (o_t) idx_opts.toggle_mask = v_t;
  if (o_rv >= 0) idx_opts.revcom_version = (int) o_rv;
  if (protein) idx_opts.dna_db = false;

  fprintf(stderr,
          "opts_filesize %lld\nk %zu\nl %zu\nspaced_seed_mask 0x%016llx\n"
          "toggle_mask 0x%016llx\ndna_db %d\nminimum_acceptable_hash_value 0x%016llx\n"
          "revcom_version %d\ndb_version %d\ndb_type %d\n",
          (long long) opts_filesize, idx_opts.k, idx_opts.l,
          (unsigned long long) idx_opts.spaced_seed_mask,
          (unsigned long long) idx_opts.toggle_mask, (int) idx_opts.dna_db,
          (unsigned long long) idx_opts.minimum_acceptable_hash_value,
          idx_opts.revcom_version, idx_opts.db_version, idx_opts.db_type);

  static char outbuf[1 << 20];
  setvbuf(stdout, outbuf, _IOFBF, sizeof(outbuf));
  put("K2MMDMP1", 8);
  putv<uint64_t>(idx_opts.k);
  putv<uint64_t>(idx_opts.l);
  putv<uint64_t>(idx_opts.spaced_seed_mask);
  putv<uint64_t>(idx_opts.toggle_mask);
  putv<uint8_t>(idx_opts.dna_db ? 1 : 0);
  putv<uint64_t>(idx_opts.minimum_acceptable_hash_value);
  putv<int32_t>(idx_opts.revcom_version);
  putv<int32_t>(idx_opts.db_version);
  putv<int32_t>(idx_opts.db_type);
  putv<uint64_t>((uint64_t) opts_filesize);
  putv<uint8_t>(ranges ? 1 : 0);

  // As classify.cc's thread body.
  MinimizerScanner scanner(idx_opts.k, idx_opts.l, idx_opts.spaced_seed_mask,
                           idx_opts.dna_db, idx_opts.toggle_mask,
                           idx_opts.revcom_version);
  std::vector<uint64_t> mm;
  std::vector<uint8_t> amb;
  uint64_t idx = 0;
  for (int f = optind; f < argc; f++) {
    int fd = open(argv[f], O_RDONLY);
    if (fd < 0)
      err(EX_NOINPUT, "%s", argv[f]);
    StreamCursor cursor;
    FastReader reader;
    if (PrimeStream(fd, cursor)) {
      while (reader.LoadBlock(fd, cursor, 8 * 1024 * 1024)) {  // classify's INPUT_BLOCK_BYTES
        reader.Parse();
        for (size_t i = 0; i < reader.size(); i++, idx++) {
          const SeqView &v = reader[i];
          emit(scanner, v, (uint8_t) (f - optind), 0, SIZE_MAX, mm, amb);
          if (ranges) {
            uint64_t len = v.seq_len, start = idx % 41, finish;
            switch (idx % 4) {
              case 0: finish = SIZE_MAX; break;
              case 1: finish = len + 3; break;
              case 2: finish = len - (idx % 29); break;  // may wrap for short reads
              default: finish = start + (idx % 50); break;
            }
            emit(scanner, v, (uint8_t) (f - optind), start, finish, mm, amb);
          }
        }
      }
    }
    if (! cursor.error.empty())
      errx(EX_IOERR, "%s (%s)", cursor.error.c_str(), argv[f]);
    if (reader.fault_count())
      warnx("%s: %s", argv[f], reader.fault().c_str());
    close(fd);
  }
  putv<uint8_t>(0);
  putv<uint64_t>(g_records);
  putv<uint64_t>(g_minimizers);
  if (fflush(stdout) != 0)
    err(EX_IOERR, "flush");
  fprintf(stderr, "records %llu\nminimizers %llu\n", (unsigned long long) g_records,
          (unsigned long long) g_minimizers);
  return 0;
}
