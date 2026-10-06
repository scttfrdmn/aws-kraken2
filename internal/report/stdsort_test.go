package report

// Worked examples from the clean-room std::sort specification (issue #35). Each element is a
// letter key with an occurrence label (a1, b2, ...); only the key is compared, so the label shows
// where every equal element ends up.

import (
	"fmt"
	"strconv"
	"strings"
	"testing"
)

func labelled(t *testing.T, s string) []uint64 {
	t.Helper()
	var out []uint64
	for _, f := range strings.Fields(s) {
		k := uint64(f[0] - 'a')
		occ, err := strconv.Atoi(f[1:])
		if err != nil {
			t.Fatalf("bad label %q", f)
		}
		out = append(out, k<<32|uint64(occ))
	}
	return out
}

func unlabel(a []uint64) string {
	parts := make([]string, len(a))
	for i, v := range a {
		parts[i] = fmt.Sprintf("%c%d", 'a'+byte(v>>32), uint32(v))
	}
	return strings.Join(parts, " ")
}

func keyLess(x, y uint64) bool { return x>>32 < y>>32 }

func seq(prefix string, n int) string {
	parts := make([]string, n)
	for i := range parts {
		parts[i] = prefix + strconv.Itoa(i+1)
	}
	return strings.Join(parts, " ")
}

func TestStdSortWorkedExamples(t *testing.T) {
	ex5 := strings.Repeat("b a a b b a b a ", 5)
	{
		ca, cb := 0, 0
		var p []string
		for _, f := range strings.Fields(ex5) {
			if f == "a" {
				ca++
				p = append(p, "a"+strconv.Itoa(ca))
			} else {
				cb++
				p = append(p, "b"+strconv.Itoa(cb))
			}
		}
		ex5 = strings.Join(p, " ")
	}
	cases := []struct {
		name, in, out string
		depth         int // -1: natural budget
	}{
		{"ex1", "b1 a1 b2 a2 b3", "a1 a2 b1 b2 b3", -1},
		{"ex2", "c1 b1 a1 c2 b2 a2 c3 b3 a3 c4 b4 a4 c5 b5 a5 c6 a6",
			"a3 a6 a5 a4 a2 a1 b2 b3 b4 b5 b1 c3 c1 c4 c2 c5 c6", -1},
		{"ex3", seq("b", 20),
			"b11 b20 b19 b18 b17 b16 b15 b14 b13 b12 b1 b10 b9 b8 b7 b6 b5 b4 b3 b2", -1},
		{"ex4", "d1 a1 c1 b1 d2 a2 c2 b2 d3 a3 c3 b3 d4 a4 c4 b4 d5 a5 c5 b5",
			"a1 a5 a4 a2 a3 b5 b4 b3 b2 b1 c3 c2 c4 c1 c5 d3 d4 d2 d5 d1", -1},
		{"ex5", ex5,
			"a1 a20 a19 a18 a17 a16 a15 a14 a13 a12 a11 a10 a9 a8 a7 a2 a6 a5 a4 a3 b1 b8 b20 b19 b18 b2 b3 b17 b16 b4 b15 b14 b5 b13 b12 b11 b10 b6 b7 b9", -1},
		{"ex6", "i1 a1 i2 b1 i3 c1 i4 d1 h1 h2 i5 f1 j1 g1 i6 h3 h4 h5 i7 j2 a2 b2 c2 d2 e1 f2 g2 h6 i8 h7 j3 i9 i10 i11 i12 i13 i14 i15 j4 a3",
			"a2 a3 a1 b2 b1 c2 c1 d2 d1 e1 f1 f2 g1 g2 h6 h2 h7 h1 h4 h3 h5 i7 i9 i3 i15 i11 i1 i5 i8 i10 i2 i14 i12 i4 i6 i13 j2 j4 j3 j1", -1},
		{"ex7", "c1 a1 b1 c2 b2 a2 c3 a3 b3 b4 c4 a4 c5 b5 b6 a5 c6 b7 c7 a6",
			"a5 a1 a3 a4 a2 a6 b7 b3 b4 b2 b5 b1 b6 c6 c2 c7 c4 c1 c5 c3", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := labelled(t, c.in)
			if c.depth < 0 {
				stdSort(a, keyLess)
			} else {
				stdSortDepth(a, keyLess, c.depth)
			}
			if got := unlabel(a); got != c.out {
				t.Fatalf("\n got %s\nwant %s", got, c.out)
			}
		})
	}
}

func TestStdSortHeapVectors(t *testing.T) {
	cases := []struct{ in, heap, out string }{
		{"b1 a1 c1 a2 b2 a3 b3", "c1 b2 b3 a2 a1 a3 b1", "a1 a2 a3 b2 b1 b3 c1"},
		{"b1 a1 b2 c1 a2 b3 c2 a3", "c2 c1 b2 a3 a2 b3 b1 a1", "a3 a2 a1 b1 b3 b2 c1 c2"},
	}
	for _, c := range cases {
		a := labelled(t, c.in)
		m := len(a)
		for k := (m - 2) / 2; k >= 0; k-- {
			settle(a, k, m, a[k], keyLess)
		}
		if got := unlabel(a); got != c.heap {
			t.Fatalf("heap: got %s want %s", got, c.heap)
		}
		a = labelled(t, c.in)
		heapSort(a, keyLess)
		if got := unlabel(a); got != c.out {
			t.Fatalf("heapsort: got %s want %s", got, c.out)
		}
	}
}

func TestStdSortNoAlloc(t *testing.T) {
	a := make([]uint64, 1000)
	if n := testing.AllocsPerRun(10, func() {
		for i := range a {
			a[i] = uint64((i * 7919) % 1000)
		}
		stdSort(a, func(x, y uint64) bool { return x < y })
	}); n != 0 {
		t.Fatalf("allocs = %v", n)
	}
}
