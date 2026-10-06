// Oracle harness for internal/report's std::sort twin: the permutation libstdc++'s std::sort
// produces with the comparator shape of upstream's KrakenReportDFS (src/reports.cc at the pin).
// Copyright 2026 aws-kraken2 contributors. MIT License.
//
// stdin, one case per line: m n k_0 ... k_{n-1}, where m is 's' for std::sort or 'h' for
// std::partial_sort(first, last, last) (the heapsort std::sort falls back to), and k_i is the
// clade count of element i or -1 for "absent from the counter map". Elements are the IDs
// 1000+i.
// stdout, one line per case: the sorted IDs.
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <map>
#include <vector>

int main() {
  std::ios::sync_with_stdio(false);
  char mode;
  size_t n;
  while (std::cin >> mode >> n) {
    std::map<uint64_t, int64_t> counts;
    std::vector<uint64_t> ids(n);
    for (size_t i = 0; i < n; i++) {
      long long k;
      std::cin >> k;
      ids[i] = 1000 + i;
      if (k >= 0) counts[ids[i]] = k;
    }
    auto comp = [&](const uint64_t &a, const uint64_t &b) {
      if (counts.find(a) == counts.end()) return false;
      if (counts.find(b) == counts.end()) return true;
      return counts[a] > counts[b];
    };
    if (mode == 'h')
      std::partial_sort(ids.begin(), ids.end(), ids.end(), comp);
    else
      std::sort(ids.begin(), ids.end(), comp);
    for (size_t i = 0; i < n; i++) std::cout << (i ? " " : "") << ids[i];
    std::cout << "\n";
  }
  return 0;
}
