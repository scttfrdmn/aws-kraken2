package classify

import (
	"math"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
)

// Synthetic taxonomy (internal ID: external ID, name):
//
//	1 root (1)
//	├── 2 (10, "A")
//	│   ├── 3 (20, "A1")
//	│   └── 4 (30, "A2")
//	└── 5 (40, "B")
func synthTree() *testTree {
	return &testTree{
		parent: []uint64{0, 0, 1, 2, 2, 1},
		ext:    []uint64{0, 1, 10, 20, 30, 40},
		name:   []string{"root", "root", "A", "A1", "A2", "B"},
	}
}

type ev struct {
	min uint64
	amb bool
}

// fakeScanner yields a fixed event list per Load call, in order.
type fakeScanner struct {
	seqs [][]ev
	cur  []ev
}

func (f *fakeScanner) Load([]byte) { f.cur, f.seqs = f.seqs[0], f.seqs[1:] }
func (f *fakeScanner) Next() (uint64, bool, bool) {
	if len(f.cur) == 0 {
		return 0, false, false
	}
	e := f.cur[0]
	f.cur = f.cur[1:]
	return e.min, e.amb, true
}

type countingResolver struct {
	m     map[uint64]uint32
	calls int
}

func (r *countingResolver) Get(k uint64) uint32 { r.calls++; return r.m[k] }

func run(t *testing.T, opts Options, idx IndexInfo, r map[uint64]uint32, id string, mates ...[]ev) (string, uint64, *Worker, *countingResolver) {
	t.Helper()
	idx.DNA = true
	c, err := New(synthTree(), idx, opts, nil)
	if err != nil {
		t.Fatal(err)
	}
	s := &fakeScanner{seqs: mates}
	res := &countingResolver{m: r}
	w := &Worker{}
	seq1 := make([]byte, 100)
	var seq2 []byte
	if opts.Paired {
		seq2 = make([]byte, 90)
	}
	call := c.ClassifySequence(s, res, []byte(id), seq1, seq2, w)
	return string(w.Out), call, w, res
}

func evs(mins ...uint64) []ev {
	out := make([]ev, len(mins))
	for i, m := range mins {
		out[i] = ev{min: m}
	}
	return out
}

func TestHitlistRunsAndRepeats(t *testing.T) {
	// 7 and 8 hit taxon 3; 9 misses. The repeated 7 is a repeat (no lookup, no hit group).
	db := map[uint64]uint32{7: 3, 8: 3}
	m := []ev{{7, false}, {7, false}, {1, true}, {1, true}, {9, false}, {8, false}}
	out, call, _, res := run(t, Options{MinimumHitGroups: 2}, IndexInfo{}, db, "r1", m)
	want := "C\tr1\t20\t100\t20:2 A:2 0:1 20:1 \n"
	if out != want || call != 3 {
		t.Fatalf("got %q call %d, want %q", out, call, want)
	}
	if res.calls != 3 {
		t.Fatalf("lookups = %d, want 3 (repeat must not be looked up)", res.calls)
	}
	// Ambiguous events do not reset last_minimizer: 7, A, 7 is a lookup, A, then a repeat.
	out, _, _, res = run(t, Options{MinimumHitGroups: 2}, IndexInfo{}, db, "r1",
		[]ev{{7, false}, {0, true}, {7, false}})
	if out != "U\tr1\t0\t100\t20:1 A:1 20:1 \n" || res.calls != 1 {
		t.Fatalf("got %q with %d lookups (want 1 hit group so unclassified)", out, res.calls)
	}
}

func TestEmptyAndShortReads(t *testing.T) {
	out, _, _, _ := run(t, Options{}, IndexInfo{}, nil, "r", nil)
	if out != "U\tr\t0\t100\t0:0\n" {
		t.Fatalf("single short read: %q", out)
	}
	out, _, _, _ = run(t, Options{Paired: true}, IndexInfo{}, nil, "r/1", nil, nil)
	if out != "U\tr\t0\t100|90\t|:|\n" {
		t.Fatalf("paired short reads: %q", out)
	}
}

func TestPairedBorderAndIDTrim(t *testing.T) {
	db := map[uint64]uint32{7: 3, 8: 4}
	out, call, _, _ := run(t, Options{Paired: true, MinimumHitGroups: 2}, IndexInfo{}, db, "x/2",
		evs(7, 7), evs(7, 8))
	// last_minimizer resets at the mate border, so mate 2's 7 is a fresh lookup (3 groups).
	// Scores: 3 -> 3 hits, 4 -> 1, so 3 wins.
	if out != "C\tx\t20\t100|90\t20:2 |:| 20:1 30:1 \n" || call != 3 {
		t.Fatalf("got %q call %d", out, call)
	}
	// A single-end read keeps its /1.
	out, _, _, _ = run(t, Options{}, IndexInfo{}, nil, "x/1", nil)
	if out != "U\tx/1\t0\t100\t0:0\n" {
		t.Fatalf("got %q", out)
	}
}

func TestResolveTreeTieIsLCA(t *testing.T) {
	db := map[uint64]uint32{1: 3, 2: 4}
	out, call, _, _ := run(t, Options{MinimumHitGroups: 1}, IndexInfo{}, db, "r", evs(1, 2))
	if call != 2 || out != "C\tr\t10\t100\t20:1 30:1 \n" {
		t.Fatalf("tie: got %q call %d, want LCA 2 (ext 10)", out, call)
	}
	// Ancestor hits add to descendants' path scores: 2 + 3 beats 4 alone.
	db = map[uint64]uint32{1: 3, 2: 4, 3: 2}
	_, call, _, _ = run(t, Options{MinimumHitGroups: 1}, IndexInfo{}, db, "r", evs(1, 2, 3))
	if call != 2 {
		// path(3)=2, path(4)=2, path(2)=1: tie of 3 and 4 -> LCA 2.
		t.Fatalf("call %d, want 2", call)
	}
	db = map[uint64]uint32{1: 3, 2: 4, 3: 2, 4: 3}
	_, call, _, _ = run(t, Options{MinimumHitGroups: 1}, IndexInfo{}, db, "r", evs(1, 2, 3, 4))
	if call != 3 {
		t.Fatalf("call %d, want 3", call)
	}
}

func TestConfidenceClimbs(t *testing.T) {
	// 4 minimizers: 3, 3, 4, miss. Path(3) = 2 hits. With confidence 0.75, required =
	// ceil(0.75*4) = 3: 3 alone has 2 < 3, its clade has 2, climb to 2 whose clade has 3.
	db := map[uint64]uint32{1: 3, 2: 3, 3: 4}
	_, call, _, _ := run(t, Options{Confidence: 0.75, MinimumHitGroups: 1}, IndexInfo{}, db, "r", evs(1, 2, 3, 9))
	if call != 2 {
		t.Fatalf("conf 0.75: call %d, want 2", call)
	}
	// 0.76 -> ceil(3.04) = 4 > 3 hits anywhere: runs off the tree.
	out, call, _, _ := run(t, Options{Confidence: 0.76, MinimumHitGroups: 1}, IndexInfo{}, db, "r", evs(1, 2, 3, 9))
	if call != 0 || out != "U\tr\t0\t100\t20:2 30:1 0:1 \n" {
		t.Fatalf("conf 0.76: got %q call %d", out, call)
	}
	// Confidence 0.5 exactly: ceil(2.0) = 2, satisfied at 3 directly.
	_, call, _, _ = run(t, Options{Confidence: 0.5, MinimumHitGroups: 1}, IndexInfo{}, db, "r", evs(1, 2, 3, 9))
	if call != 3 {
		t.Fatalf("conf 0.5: call %d, want 3", call)
	}
	// Paired: the mate border is not counted in total_kmers (2 per mate -> 4; 0.75 -> 3).
	_, call, _, _ = run(t, Options{Paired: true, Confidence: 0.75, MinimumHitGroups: 1}, IndexInfo{}, db, "r",
		evs(1, 2), evs(3, 9))
	if call != 2 {
		t.Fatalf("paired conf 0.75: call %d, want 2", call)
	}
}

func TestMinimumHitGroups(t *testing.T) {
	db := map[uint64]uint32{1: 3, 2: 3}
	for g, want := range map[int]uint64{0: 3, 1: 3, 2: 3, 3: 0} {
		_, call, _, _ := run(t, Options{MinimumHitGroups: g}, IndexInfo{}, db, "r", evs(1, 1, 1, 2))
		if call != want {
			t.Errorf("-g %d: call %d, want %d", g, call, want)
		}
	}
}

func TestQuickTruncation(t *testing.T) {
	db := map[uint64]uint32{1: 3, 2: 4, 3: 5}
	c, _ := New(synthTree(), IndexInfo{DNA: true}, Options{Quick: true, MinimumHitGroups: 2}, nil)
	tok := c.NewTokens()
	for _, m := range []uint64{9, 1, 1, 2, 3} {
		tok.Add(m, false)
	}
	tok.Resolve(&countingResolver{m: db})
	w := &Worker{}
	call := c.Classify(tok, []byte("q"), 100, 0, w)
	// Exit at the second hit group (2 -> taxon 4): taxa = [0, 3, 3, 4]; ResolveTree over
	// {3:2, 4:1} with total 4 calls 3, and the line prints only ext:Q.
	if len(c.taxa) != 4 || c.taxa[3] != 4 {
		t.Fatalf("taxa after early exit: %v", c.taxa)
	}
	if call != 3 || string(w.Out) != "C\tq\t20\t100\t20:Q\n" {
		t.Fatalf("got %q call %d", w.Out, call)
	}
	// An unclassified quick read prints 0:Q.
	tok.Reset()
	tok.Add(9, false)
	tok.Resolve(&countingResolver{m: db})
	w.Out = w.Out[:0]
	c.Classify(tok, []byte("q"), 100, 0, w)
	if string(w.Out) != "U\tq\t0\t100\t0:Q\n" {
		t.Fatalf("got %q", w.Out)
	}
}

func TestMinimumAcceptableHashSkip(t *testing.T) {
	// Pick a minimizer whose hash is below the threshold and one above.
	var lo, hi uint64
	for k := uint64(1); lo == 0 || hi == 0; k++ {
		if chash.MurmurHash3(k) < 1<<62 {
			if lo == 0 {
				lo = k
			}
		} else if hi == 0 {
			hi = k
		}
	}
	db := map[uint64]uint32{lo: 3, hi: 3}
	out, _, _, res := run(t, Options{MinimumHitGroups: 1}, IndexInfo{MinimumAcceptableHashValue: 1 << 62},
		db, "r", evs(lo, lo, hi))
	// lo is skipped (taxon 0) and its repeat inherits last_taxon = 0.
	if out != "C\tr\t20\t100\t0:2 20:1 \n" || res.calls != 1 {
		t.Fatalf("got %q with %d lookups", out, res.calls)
	}
}

func TestLastTaxonCarriesAcrossMates(t *testing.T) {
	// last_minimizer resets to UINT64_MAX per mate but last_taxon does not: a first
	// minimizer equal to UINT64_MAX in mate 2 repeats mate 1's last taxon.
	db := map[uint64]uint32{5: 3}
	out, _, _, _ := run(t, Options{Paired: true}, IndexInfo{}, db, "r", evs(5), evs(math.MaxUint64))
	if out != "C\tr\t20\t100|90\t20:1 |:| 20:1 \n" {
		t.Fatalf("got %q", out)
	}
}

func TestUseNamesAndFlagUnique(t *testing.T) {
	db := map[uint64]uint32{1: 3}
	out, _, _, _ := run(t, Options{UseNames: true}, IndexInfo{}, db, "r", evs(1, 1, 2))
	if out != "C\tr\tA1 (taxid 20)\t100\t20:2 0:1 \n" {
		t.Fatalf("names: %q", out)
	}
	out, _, _, _ = run(t, Options{UseNames: true}, IndexInfo{}, db, "r", evs(2))
	if out != "U\tr\tunclassified (taxid 0)\t100\t0:1 \n" {
		t.Fatalf("names unclassified: %q", out)
	}
	// -F tags the first token of each looked-up hit, so the run splits there.
	out, _, _, _ = run(t, Options{FlagUniqueMinimizers: true}, IndexInfo{}, db, "r", evs(1, 1, 1, 2))
	if out != "C\tr\t20\t100\t*20:1 20:2 0:1 \n" {
		t.Fatalf("-F: %q", out)
	}
}

func TestCounters(t *testing.T) {
	db := map[uint64]uint32{1: 3, 2: 4}
	_, _, w, _ := run(t, Options{CountTaxa: true, KmerData: true}, IndexInfo{}, db, "r", evs(1, 1, 2, 9))
	if w.Classified != 1 || w.Counts[3].Reads != 1 || w.Counts[3].Kmers != 2 || w.Counts[4].Kmers != 1 ||
		w.Counts[4].Reads != 0 || len(w.Counts) != 2 {
		t.Fatalf("counts %+v %+v classified %d", *w.Counts[3], *w.Counts[4], w.Classified)
	}
	total := map[uint64]*TaxonCount{}
	MergeCounts(total, w.Counts)
	MergeCounts(total, w.Counts)
	if total[3].Reads != 2 || total[3].Kmers != 4 {
		t.Fatalf("merge: %+v", *total[3])
	}
	// No counters without CountTaxa; no line with NoOutput.
	_, _, w, _ = run(t, Options{NoOutput: true}, IndexInfo{}, db, "r", evs(1))
	if len(w.Counts) != 0 || len(w.Out) != 0 || w.Classified != 1 {
		t.Fatalf("got counts %v out %q", w.Counts, w.Out)
	}
}

func TestTranslatedSearchRejected(t *testing.T) {
	if _, err := New(synthTree(), IndexInfo{DNA: false}, Options{}, nil); err != ErrTranslatedSearch {
		t.Fatalf("err = %v", err)
	}
}
