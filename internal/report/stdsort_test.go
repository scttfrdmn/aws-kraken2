package report

import (
	"bytes"
	"fmt"
	"math/rand/v2"
	"os/exec"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

type sortCase struct {
	mode byte    // 's' std::sort, 'h' std::partial_sort(first, last, last)
	keys []int64 // -1 = absent from the counter map
}

func sortCases() []sortCase {
	r := rand.New(rand.NewPCG(1, 2))
	var cs []sortCase
	add := func(keys []int64) {
		cs = append(cs, sortCase{'s', keys}, sortCase{'h', keys})
	}
	for n := 0; n <= 70; n++ {
		for _, distinct := range []int{1, 2, 3, 5, 1000} {
			for rep := 0; rep < 3; rep++ {
				k := make([]int64, n)
				for i := range k {
					k[i] = int64(r.IntN(distinct+1)) - 1
				}
				add(k)
			}
		}
	}
	for _, n := range []int{100, 257, 1000, 4096, 10000} {
		for _, distinct := range []int{1, 3, 50, 100000} {
			k := make([]int64, n)
			for i := range k {
				k[i] = int64(r.IntN(distinct+1)) - 1
			}
			add(k)
		}
		asc, desc := make([]int64, n), make([]int64, n)
		for i := range asc {
			asc[i], desc[i] = int64(i/3), int64((n-i)/3)
		}
		add(asc)
		add(desc)
	}
	return cs
}

func goOrder(c sortCase) string {
	ids := make([]uint64, len(c.keys))
	present := map[uint64]int64{}
	for i, k := range c.keys {
		ids[i] = 1000 + uint64(i)
		if k >= 0 {
			present[ids[i]] = k
		}
	}
	less := func(a, b uint64) bool {
		ka, ok := present[a]
		if !ok {
			return false
		}
		kb, ok := present[b]
		if !ok {
			return true
		}
		return ka > kb
	}
	if c.mode == 'h' {
		heapSort(ids, less)
	} else {
		stdSort(ids, less)
	}
	s := make([]string, len(ids))
	for i, id := range ids {
		s[i] = fmt.Sprint(id)
	}
	return strings.Join(s, " ")
}

// TestOracleStdSort checks that stdSort and heapSort permute ties exactly as libstdc++ does.
func TestOracleStdSort(t *testing.T) {
	harness := oracletest.Harness(t, "stdsort_order")
	cs := sortCases()
	var in bytes.Buffer
	for _, c := range cs {
		fmt.Fprintf(&in, "%c %d", c.mode, len(c.keys))
		for _, k := range c.keys {
			fmt.Fprintf(&in, " %d", k)
		}
		in.WriteByte('\n')
	}
	cmd := exec.Command(harness)
	cmd.Stdin = &in
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Split(strings.TrimSuffix(string(out), "\n"), "\n")
	if len(want) != len(cs) {
		t.Fatalf("harness gave %d lines for %d cases", len(want), len(cs))
	}
	for i, c := range cs {
		if got := goOrder(c); got != want[i] {
			t.Fatalf("case %d (mode %c, n=%d): order differs\n go:  %s\n c++: %s", i, c.mode,
				len(c.keys), got, want[i])
		}
	}
	t.Logf("%d sort cases identical to libstdc++", len(cs))
}

func TestStdSortSorts(t *testing.T) {
	for _, c := range sortCases() {
		ids := make([]uint64, len(c.keys))
		for i := range ids {
			ids[i] = uint64(c.keys[i] + 1)
		}
		stdSort(ids, func(a, b uint64) bool { return a > b })
		for i := 1; i < len(ids); i++ {
			if ids[i-1] < ids[i] {
				t.Fatalf("not sorted: %v", ids)
			}
		}
	}
}
