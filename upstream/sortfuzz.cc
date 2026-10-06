// Differential oracle for internal/report's std::sort twin (issue #35, docs/sortfuzz.md):
// libstdc++'s std::sort, with the comparator of upstream's KrakenReportDFS (src/reports.cc at
// 2731b35f7abb26ec926517274f3d87e78d42fd76), on cases streamed from the Go driver
// (internal/report/sortfuzz_test.go). Not part of the core path.
// Copyright 2026 aws-kraken2 contributors. MIT License.
//
// Modes:
//   sortfuzz --version     one line: compiler and libstdc++ (header) version.
//   sortfuzz --killer N    N lines: the keys of a McIlroy adversary input of length N (below).
//   sortfuzz               the stream mode below.
//
// Stream mode, binary, little-endian, until EOF on stdin. Per case:
//   in : u32 n, then n x (u32 id, i32 key). key < 0 means "absent from the counter map". ids are
//        distinct within a case (checked).
//   out: u32 heap, u64 comps, u32 n, then n x u32 id (the ids in std::sort's output order).
//        heap  = how many times std::sort's depth-limit (heapsort) fallback was entered;
//        comps = comparator calls.
// The comparator is upstream's (reports.cc, KrakenReportDFS):
//   a absent -> false; else b absent -> true; else count(a) > count(b).
// Children are uint64_t taxids in a std::vector there; here they are uint64_t too.
//
// Heapsort detection. In libstdc++ std::sort is __sort -> __introsort_loop, which calls
// std::__partial_sort(first, last, last, comp) exactly when the depth limit (2*floor(lg n)) is
// exhausted on a range longer than _S_threshold (16); nothing else on std::sort's path calls it.
// We sort through TagIt, a thin random-access iterator over uint64_t* defined here, and declare
// an explicit specialization of std::__partial_sort for <TagIt, comparator> that counts the call
// and then runs the unspecialized primary template on the same range through plain pointers, so
// the algorithm, the comparisons and the moves are libstdc++'s own. libstdc++ is not modified.
// The comparator type at that call depends on the library: GCC < 16 wraps it in
// __gnu_cxx::__ops::_Iter_comp_iter<C>, GCC 16 passes C itself; the matching specialization is
// chosen by _GLIBCXX_RELEASE. If neither matched, the count would stay 0 on every case and
// the Go driver fails (a corpus that never reaches the fallback is a failure), so a mismatch is
// loud, not silent. Every case is also sorted a second time with plain std::sort on
// std::vector<uint64_t>::iterator, exactly upstream's call; any difference from the TagIt sort
// aborts (exit 3), so the instrumentation cannot have changed the order.
//
// --killer N: McIlroy's adversary ("A Killer Adversary for Quicksort", 1999) run against this
// std::sort: values start as "gas" (above every solid value); when two gas items are compared the
// one that is not the current pivot candidate is frozen to the next solid value. The frozen
// values (gas left as ties at the top) are an input on which std::sort makes the same
// comparisons, which drives introsort into its depth limit. Printed as descending-sort keys
// (key = N - value, so gas -> 0, all tied), ready for the comparator above.
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <string>
#include <vector>

namespace {

struct TagIt {
  typedef std::random_access_iterator_tag iterator_category;
  typedef uint64_t value_type;
  typedef std::ptrdiff_t difference_type;
  typedef uint64_t *pointer;
  typedef uint64_t &reference;
  uint64_t *p;
  TagIt() : p(0) {}
  explicit TagIt(uint64_t *q) : p(q) {}
  reference operator*() const { return *p; }
  pointer operator->() const { return p; }
  reference operator[](difference_type d) const { return p[d]; }
  TagIt &operator++() { ++p; return *this; }
  TagIt operator++(int) { TagIt t = *this; ++p; return t; }
  TagIt &operator--() { --p; return *this; }
  TagIt operator--(int) { TagIt t = *this; --p; return t; }
  TagIt &operator+=(difference_type d) { p += d; return *this; }
  TagIt &operator-=(difference_type d) { p -= d; return *this; }
  TagIt operator+(difference_type d) const { return TagIt(p + d); }
  TagIt operator-(difference_type d) const { return TagIt(p - d); }
  difference_type operator-(const TagIt &o) const { return p - o.p; }
  bool operator==(const TagIt &o) const { return p == o.p; }
  bool operator!=(const TagIt &o) const { return p != o.p; }
  bool operator<(const TagIt &o) const { return p < o.p; }
  bool operator>(const TagIt &o) const { return p > o.p; }
  bool operator<=(const TagIt &o) const { return p <= o.p; }
  bool operator>=(const TagIt &o) const { return p >= o.p; }
};
inline TagIt operator+(TagIt::difference_type d, const TagIt &it) { return it + d; }

// Per-case state the comparator reads: key by (id - base); present[] is the counter map's
// membership.
std::vector<int64_t> g_key;
std::vector<char> g_present;
uint64_t g_base = 0;
uint64_t g_comps = 0;
unsigned g_heap = 0;

// upstream reports.cc KrakenReportDFS, with clade_counters.find(x) == end() as !present.
struct Comp {
  bool operator()(const uint64_t &a, const uint64_t &b) const {
    g_comps++;
    if (!g_present[a - g_base]) return false;
    if (!g_present[b - g_base]) return true;
    return (uint64_t)g_key[a - g_base] > (uint64_t)g_key[b - g_base];
  }
};

}  // namespace

namespace std {
#if _GLIBCXX_RELEASE >= 16
template <>
inline void __partial_sort<TagIt, Comp>(TagIt first, TagIt middle, TagIt last, Comp comp) {
  g_heap++;
  std::__partial_sort<uint64_t *, Comp>(first.p, middle.p, last.p, comp);
}
#else
template <>
inline void __partial_sort<TagIt, __gnu_cxx::__ops::_Iter_comp_iter<Comp> >(
    TagIt first, TagIt middle, TagIt last, __gnu_cxx::__ops::_Iter_comp_iter<Comp> comp) {
  g_heap++;
  std::__partial_sort<uint64_t *, __gnu_cxx::__ops::_Iter_comp_iter<Comp> >(first.p, middle.p,
                                                                           last.p, comp);
}
#endif
}  // namespace std

namespace {

std::string version() {
  char b[512];
  snprintf(b, sizeof b, "g++ %s; libstdc++ _GLIBCXX_RELEASE=%d __GLIBCXX__=%d; __cplusplus=%ld",
           __VERSION__, (int)_GLIBCXX_RELEASE, (int)__GLIBCXX__, (long)__cplusplus);
  return b;
}

bool readn(void *p, size_t n) { return fread(p, 1, n, stdin) == n; }
void writen(const void *p, size_t n) {
  if (fwrite(p, 1, n, stdout) != n) { perror("sortfuzz: write"); exit(1); }
}
void die(const char *m) { fprintf(stderr, "sortfuzz: %s\n", m); exit(2); }

int killer(long n) {
  if (n < 0) die("--killer: bad N");
  const long gas = n;
  std::vector<long> val(n, gas);
  std::vector<uint64_t> ptr(n);
  for (long i = 0; i < n; i++) ptr[i] = i;
  long nsolid = 0, candidate = 0;
  std::sort(ptr.begin(), ptr.end(), [&](const uint64_t &x, const uint64_t &y) {
    if (val[x] == gas && val[y] == gas) {
      if ((long)x == candidate) val[x] = nsolid++;
      else val[y] = nsolid++;
    }
    if (val[x] == gas) candidate = x;
    else if (val[y] == gas) candidate = y;
    return val[x] < val[y];
  });
  for (long i = 0; i < n; i++) printf("%ld\n", n - val[i]);
  return 0;
}

int stream() {
  std::vector<uint64_t> a, b;
  std::vector<uint32_t> in, out;
  uint32_t n;
  while (readn(&n, 4)) {
    in.resize(2 * (size_t)n);
    if (n && !readn(in.data(), 8 * (size_t)n)) die("truncated case");
    a.resize(n);
    uint64_t lo = UINT64_MAX;
    for (uint32_t i = 0; i < n; i++) {
      a[i] = in[2 * i];
      lo = std::min(lo, a[i]);
    }
    g_base = n ? lo : 0;
    g_key.assign(n, 0);
    g_present.assign(n, 0);
    std::vector<char> seen(n, 0);
    for (uint32_t i = 0; i < n; i++) {
      uint64_t j = a[i] - g_base;
      if (j >= n || seen[j]) die("ids must be distinct and span at most n values");
      seen[j] = 1;
      int32_t k;
      memcpy(&k, &in[2 * i + 1], 4);
      g_key[j] = k;
      g_present[j] = k >= 0;
    }
    b = a;
    g_heap = 0;
    g_comps = 0;
    std::sort(TagIt(a.data()), TagIt(a.data() + n), Comp());
    unsigned heap = g_heap;
    uint64_t comps = g_comps;
    std::sort(b.begin(), b.end(), Comp());  // upstream's exact call shape
    if (a != b) {
      fprintf(stderr, "sortfuzz: TagIt sort differs from plain std::sort (n=%u)\n", n);
      exit(3);
    }
    out.resize(n);
    for (uint32_t i = 0; i < n; i++) out[i] = (uint32_t)a[i];
    uint32_t h = heap;
    writen(&h, 4);
    writen(&comps, 8);
    writen(&n, 4);
    if (n) writen(out.data(), 4 * (size_t)n);
  }
  if (!feof(stdin)) die("read error");
  fflush(stdout);
  return 0;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--version")) {
    printf("%s\n", version().c_str());
    return 0;
  }
  if (argc == 3 && !strcmp(argv[1], "--killer")) return killer(atol(argv[2]));
  if (argc != 1) die("usage: sortfuzz [--version | --killer N]");
  return stream();
}
