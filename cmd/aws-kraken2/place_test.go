package main

import (
	"math/rand"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func loads(pl [][]int, w []int64) []int64 {
	out := make([]int64, len(pl))
	for r, js := range pl {
		for _, j := range js {
			out[r] += w[j]
		}
	}
	return out
}

func maxOf(xs []int64) int64 {
	m := xs[0]
	for _, x := range xs {
		if x > m {
			m = x
		}
	}
	return m
}

func TestPlaceMod(t *testing.T) {
	got := placeMod(7, 3)
	want := [][]int{{0, 3, 6}, {1, 4}, {2, 5}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("placeMod(7,3) = %v, want %v", got, want)
	}
}

func TestPlaceLPTSmall(t *testing.T) {
	// Heaviest first; ties by manifest order; to the least-loaded node, ties to the lowest rank.
	w := []int64{5, 9, 9, 1, 7, 3}
	got := placeLPT(w, 3)
	// order: 1(9) 2(9) 4(7) 0(5) 5(3) 3(1)
	// 1->r0 [9]; 2->r1 [9]; 4->r2 [7]; 0->r2 [12]; 5->r0 [12]; 3->r1 [10]
	want := [][]int{{1, 5}, {2, 3}, {4, 0}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("placeLPT = %v, want %v", got, want)
	}
}

// E1's cohort 10 (results/cohort/PRJNA398089/runs.tsv read counts) on 8 nodes: j mod N put
// 35.4M pairs on rank 1; LPT's busiest node holds only the largest sample.
func TestPlaceLPTE1(t *testing.T) {
	w := []int64{10532910, 16518263, 12325847, 201473, 15328347, 10492437, 11012615, 3036382, 11859598, 18879904}
	mod := maxOf(loads(placeMod(len(w), 8), w))
	lpt := maxOf(loads(placeLPT(w, 8), w))
	if mod != 35398167 {
		t.Fatalf("mod max load %d, want 35398167 (E1's rank 1)", mod)
	}
	if lpt != 18879904 {
		t.Fatalf("LPT max load %d, want 18879904 (the largest sample)", lpt)
	}
}

// Every sample placed exactly once; heaviest first within a node; LPT's bound against the
// brute-force optimum on small random cases: makespan <= (4/3 - 1/(3N)) * OPT.
func TestPlaceLPTProperties(t *testing.T) {
	rng := rand.New(rand.NewSource(25))
	for iter := 0; iter < 400; iter++ {
		n := 1 + rng.Intn(9)
		nodes := 1 + rng.Intn(4)
		w := make([]int64, n)
		for i := range w {
			w[i] = int64(rng.Intn(100))
		}
		pl := placeLPT(w, nodes)
		if len(pl) != nodes {
			t.Fatalf("%d ranks, want %d", len(pl), nodes)
		}
		seen := make([]int, n)
		for _, js := range pl {
			for k, j := range js {
				seen[j]++
				if k > 0 && w[js[k-1]] < w[j] {
					t.Fatalf("w=%v nodes=%d: rank order %v not heaviest first", w, nodes, js)
				}
			}
		}
		for j, c := range seen {
			if c != 1 {
				t.Fatalf("w=%v nodes=%d: sample %d placed %d times", w, nodes, j, c)
			}
		}
		opt := bruteOpt(w, nodes)
		got := maxOf(loads(pl, w))
		if 3*int64(nodes)*got > (4*int64(nodes)-1)*opt {
			t.Fatalf("w=%v nodes=%d: LPT %d exceeds (4/3-1/3N) x OPT %d", w, nodes, got, opt)
		}
		if !reflect.DeepEqual(pl, placeLPT(w, nodes)) {
			t.Fatalf("not deterministic")
		}
	}
}

func bruteOpt(w []int64, nodes int) int64 {
	best := int64(-1)
	ld := make([]int64, nodes)
	var rec func(i int)
	rec = func(i int) {
		if i == len(w) {
			if m := maxOf(ld); best < 0 || m < best {
				best = m
			}
			return
		}
		for r := 0; r < nodes; r++ {
			ld[r] += w[i]
			rec(i + 1)
			ld[r] -= w[i]
		}
	}
	rec(0)
	return best
}

func TestParseCohortPlacement(t *testing.T) {
	dir := t.TempDir()
	write := func(body string) string {
		p := filepath.Join(dir, "m.tsv")
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	ls, err := parseCohort(write("0\t1\tparallel:lpt\t-\ta\tweight=10\t--output\tx\tin\n0\t1\tparallel:lpt\t-\tb\tweight=3\t--output\ty\tin\n" +
		"1\t1\tparallel\t-\tc\t--output\tz\tin\n2\t1\tparallel:mod\t-\td\tweight=4\t--output\tw\tin\n3\t1\tstriped\t-\te\t--output\tv\tin\n"))
	if err != nil {
		t.Fatal(err)
	}
	type got struct {
		mode, place string
		weight      int64
		args        string
	}
	var g []got
	for _, l := range ls {
		g = append(g, got{l.mode, l.place, l.weight, strings.Join(l.args, " ")})
	}
	want := []got{{"parallel", "lpt", 10, "--output x in"}, {"parallel", "lpt", 3, "--output y in"},
		{"parallel", "mod", -1, "--output z in"}, {"parallel", "mod", 4, "--output w in"}, {"striped", "", -1, "--output v in"}}
	if !reflect.DeepEqual(g, want) {
		t.Fatalf("parsed %+v, want %+v", g, want)
	}
	for _, bad := range []string{
		"0\t1\tparallel:lpt\t-\ta\t--output\tx\tin\n",                                                  // no weight
		"0\t1\tparallel:lpt\t-\ta\tweight=-1\t--output\tx\tin\n",                                       // negative
		"0\t1\tparallel:lpt\t-\ta\tweight=1\t--output\tx\tin\n0\t1\tparallel\t-\tb\t--output\ty\tin\n", // mixed placement
		"0\t1\tparallel:xyz\t-\ta\t--output\tx\tin\n",                                                  // unknown placement
	} {
		if _, err := parseCohort(write(bad)); err == nil {
			t.Errorf("parseCohort accepted %q", bad)
		}
	}
}
