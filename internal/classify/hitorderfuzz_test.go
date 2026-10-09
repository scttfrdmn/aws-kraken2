package classify

// make hitorderfuzz (docs/hitorderfuzz.md, #44): a black-box differential fuzz of the HitCounts
// that newHitCounts() returns against upstream's taxon_counts_t, std::unordered_map<taxid_t,
// uint64_t> compiled by Amazon Linux 2023's g++ (upstream/umap_order.cc, run as a subprocess).
//
// The op histories are generated deterministically from a seed. Each history starts with N (a
// fresh map, one worker's lifetime) and is replayed through a fresh newHitCounts(); at every
// P/V the order and the counts Range yields must equal the container's, and at every G the value
// Lookup returns must equal the container's. The run stops at the first mismatch and writes it in
// full (mismatch.txt, and mismatch-ops.txt that umap_order replays as is).
//
// The generator learns the container's bucket-count sequence from a probe run of the harness
// (fresh map, keys 1..n, B after every insert), and uses it to place keys that collide modulo
// each bucket count and to place dumps on both sides of every rehash boundary. The test is
// skipped unless HITORDERFUZZ_CMD is set, so make test does not run it.
//
// Env: HITORDERFUZZ_CMD (sh -c command running umap_order on stdin/stdout), HITORDERFUZZ
// (quick|full|selftest), HITORDERFUZZ_SEED (default 44), HITORDERFUZZ_OUT (results directory),
// HITORDERFUZZ_MIRROR_CMD (selftest only: a line-buffered umap_order that stands in for the Go
// side, which checks the comparison and coverage logic against the container itself).

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fuzzNewHitCounts is the implementation under test.
var fuzzNewHitCounts = newHitCounts

type hop struct {
	c byte // N C I L G P V B
	k uint64
}

func (o hop) String() string {
	switch o.c {
	case 'I', 'L', 'G':
		return string(o.c) + " " + strconv.FormatUint(o.k, 10)
	}
	return string(o.c)
}

type fuzzHist struct {
	cat string
	id  int
	ops []hop
}

const (
	catLookup = iota + 1
	catRandom
	catClearRandom
	catClearBeyond
	catGrowth
)

type fuzzSizes struct {
	Random      int `json:"random_histories"`
	Lookup      int `json:"lookup_histories"`
	ClearHists  int `json:"clear_random_histories"`
	ClearCycles int `json:"clear_random_cycles_each"`
	GrowthMax   int `json:"growth_max_elements"`
	GrowthVars  int `json:"growth_variants"`
	RealRepeat  int `json:"real_repeat_rounds"`
	MinClears   int `json:"min_clear_cycles"`
	MinAbsent   int `json:"min_absent_lookups_interleaved"`
}

func fuzzSizesFor(mode string) (fuzzSizes, error) {
	switch mode {
	case "quick":
		return fuzzSizes{100000, 20000, 120, 250, 100000, 6, 100, 100000, 10000}, nil
	case "full":
		return fuzzSizes{1000000, 200000, 600, 500, 100000, 10, 1000, 1000000, 100000}, nil
	case "selftest":
		return fuzzSizes{1500, 300, 10, 100, 100000, 6, 3, 2000, 300}, nil
	}
	return fuzzSizes{}, fmt.Errorf("HITORDERFUZZ=%q: want quick, full or selftest", mode)
}

type fuzzCfg struct {
	seed   uint64
	sz     fuzzSizes
	bcs    []uint64 // bucket counts of a fresh insert-only map, in order; bcs[0] is the empty map's
	bounds []int    // bounds[i]: the size at which the bucket count becomes bcs[i+1]
	real   []fuzzHist
	only   map[string]bool // HITORDERFUZZ_ONLY: run only these top-level categories (never a pass)
}

func (cfg *fuzzCfg) on(cat string) bool { return cfg.only == nil || cfg.only[cat] }

func (cfg *fuzzCfg) rng(cat, id int) *rand.Rand {
	return rand.New(rand.NewPCG(cfg.seed, uint64(cat)<<48|uint64(id)))
}

// each yields every history in stream order, until emit returns false.
func (cfg *fuzzCfg) each(emit func(*fuzzHist) bool) {
	for i := range cfg.real {
		if !cfg.on("real") {
			break
		}
		if !emit(&cfg.real[i]) {
			return
		}
	}
	for i := 0; i < cfg.sz.Lookup && cfg.on("lookup"); i++ {
		if !emit(cfg.genRead(catLookup, i)) {
			return
		}
	}
	for i := 0; i < cfg.sz.Random && cfg.on("random"); i++ {
		if !emit(cfg.genRead(catRandom, i)) {
			return
		}
	}
	for i := 0; i < cfg.sz.ClearHists && cfg.on("clear-random"); i++ {
		if !emit(cfg.genClearRandom(i)) {
			return
		}
	}
	for i := range cfg.bounds {
		if i == 0 || cfg.bounds[i] > cfg.sz.GrowthMax || !cfg.on("clear-beyond") {
			continue
		}
		for v := 0; v < 2; v++ {
			if !emit(cfg.genClearBeyond(i, v)) {
				return
			}
		}
	}
	for v := 0; v < cfg.sz.GrowthVars && cfg.on("growth"); v++ {
		if !emit(cfg.genGrowth(v)) {
			return
		}
	}
}

// hb builds one history and tracks which keys it has inserted (for absent lookups).
type hb struct {
	r       *rand.Rand
	ops     []hop
	present map[uint64]bool
	keys    []uint64
	since   int
	next    int
	coarse  int // dump interval divisor for large maps
}

func newHB(r *rand.Rand) *hb {
	b := &hb{r: r, present: map[uint64]bool{}, coarse: 1}
	b.ops = append(b.ops, hop{'N', 0})
	b.next = 1
	return b
}

func (b *hb) op(c byte, k uint64) {
	b.ops = append(b.ops, hop{c, k})
	switch c {
	case 'C':
		clear(b.present)
		b.keys = b.keys[:0]
	case 'I', 'L', 'G':
		if !b.present[k] {
			b.present[k] = true
			b.keys = append(b.keys, k)
		}
	}
}

func (b *hb) dump() {
	if b.r.IntN(10) == 0 {
		b.op('P', 0)
	} else {
		b.op('V', 0)
	}
}

// tick dumps after every few ops: every 1..4 ops while the map is small, every 1..size/coarse
// ops once it is large.
func (b *hb) tick() {
	b.since++
	if b.since < b.next {
		return
	}
	b.dump()
	b.since = 0
	w := 4
	if n := len(b.keys) / b.coarse; n > w {
		w = n
	}
	if w > 512 {
		w = 512
	}
	b.next = 1 + b.r.IntN(w)
}

func (b *hb) absent(key func() uint64) uint64 {
	for t := 0; t < 32; t++ {
		if k := key(); !b.present[k] {
			return k
		}
	}
	k := key()
	for b.present[k] {
		k++
	}
	return k
}

func (b *hb) anyPresent() uint64 { return b.keys[b.r.IntN(len(b.keys))] }

// The key distributions.
const (
	distDense = iota
	distCollide
	distHuge
	distTaxid
	distMixed
	nDist
)

var distNames = [nDist]string{"dense", "collide", "huge", "taxid", "mixed"}

func (cfg *fuzzCfg) keyGen(r *rand.Rand, kind int) func() uint64 {
	switch kind {
	case distDense:
		d := []uint64{1, 2, 3, 5, 8, 13, 16, 29, 30, 59, 64, 128, 1000}[r.IntN(13)]
		off := uint64(0)
		if r.IntN(3) == 0 {
			off = 1
		}
		return func() uint64 { return off + r.Uint64N(d) }
	case distCollide:
		// Keys congruent modulo one (or a few) of the container's bucket counts.
		nb := 1 + r.IntN(3)
		var bcs, res []uint64
		for i := 0; i < nb; i++ {
			bc := cfg.bcs[1+r.IntN(len(cfg.bcs)-1)]
			bcs = append(bcs, bc)
			res = append(res, r.Uint64N(bc))
		}
		j := []uint64{4, 16, 64, 1000, 100000}[r.IntN(5)]
		high := r.IntN(4) == 0
		return func() uint64 {
			i := r.IntN(nb)
			k := res[i] + bcs[i]*r.Uint64N(j)
			if high {
				k = math.MaxUint64 - k
			}
			return k
		}
	case distHuge:
		w := []uint64{1, 8, 64, 10000, 1 << 32}[r.IntN(5)]
		switch r.IntN(4) {
		case 0:
			return func() uint64 { return math.MaxUint64 - r.Uint64N(w) }
		case 1:
			return func() uint64 { return 1<<63 - w/2 + r.Uint64N(w) }
		case 2:
			bc := cfg.bcs[1+r.IntN(len(cfg.bcs)-1)]
			res := r.Uint64N(bc)
			return func() uint64 { return math.MaxUint64 - res - bc*r.Uint64N(w) }
		}
		return r.Uint64
	case distTaxid:
		switch r.IntN(4) {
		case 0:
			return func() uint64 { return 1 + r.Uint64N(2200000) }
		case 1:
			base := 1 + r.Uint64N(2200000)
			w := []uint64{10, 100, 5000}[r.IntN(3)]
			return func() uint64 { return base + r.Uint64N(w) }
		case 2: // RODA v205's orphan internal IDs, with real-like hits around them
			return func() uint64 {
				if r.IntN(3) == 0 {
					return 2158313 + r.Uint64N(246)
				}
				return 1 + r.Uint64N(2158313)
			}
		}
		return func() uint64 {
			if r.IntN(50) == 0 {
				return 0
			}
			return 1 + r.Uint64N(2200000)
		}
	}
	subs := []func() uint64{cfg.keyGen(r, r.IntN(distMixed)), cfg.keyGen(r, r.IntN(distMixed)), cfg.keyGen(r, r.IntN(distMixed))}
	return func() uint64 { return subs[r.IntN(3)]() }
}

func readSize(r *rand.Rand) int {
	switch x := r.IntN(100); {
	case x < 75:
		return 1 + r.IntN(16)
	case x < 95:
		return 17 + r.IntN(112)
	case x < 99:
		return 129 + r.IntN(400)
	}
	return 529 + r.IntN(1500)
}

// genRead: read-shaped histories, as classify.cc uses hit_counts. catRandom: per read, C, the
// hits (repeats, as runs or shuffled), an occasional lookup, dumps every few ops, and at the end
// ResolveTree's shape (V, a lookup of a present, absent or 0 taxon, V). catLookup: the same with
// a lookup (mostly of absent taxa) between most increments.
func (cfg *fuzzCfg) genRead(cat, id int) *fuzzHist {
	r := cfg.rng(cat, id)
	kind := r.IntN(nDist)
	key := cfg.keyGen(r, kind)
	b := newHB(r)
	if r.IntN(4) == 0 {
		b.op('V', 0)
	}
	reads := 1 + r.IntN(4)
	noClear := r.IntN(20) == 0
	lookupP := 8
	if cat == catLookup {
		lookupP = 2
	}
	for rd := 0; rd < reads; rd++ {
		if !noClear || rd == 0 {
			b.op('C', 0)
			if r.IntN(3) == 0 {
				b.dump()
			}
		}
		n := readSize(r)
		var seq []uint64
		for i := 0; i < n; i++ {
			k := key()
			for c := []int{1, 1, 1, 2, 3, 5}[r.IntN(6)]; c > 0; c-- {
				seq = append(seq, k)
			}
		}
		if r.IntN(2) == 0 {
			r.Shuffle(len(seq), func(i, j int) { seq[i], seq[j] = seq[j], seq[i] })
		}
		b.since, b.next = 0, 1+r.IntN(4)
		for _, k := range seq {
			b.op('I', k)
			b.tick()
			if r.IntN(lookupP) == 0 {
				c := byte('G')
				if r.IntN(3) == 0 {
					c = 'L'
				}
				switch x := r.IntN(10); {
				case x < 6 || cat == catLookup && x < 8:
					b.op(c, b.absent(key))
				case x < 9:
					b.op(c, b.anyPresent())
				default:
					b.op(c, 0)
				}
				b.tick()
			}
		}
		b.op('V', 0)
		switch r.IntN(3) {
		case 0:
			b.op('G', b.anyPresent())
		case 1:
			b.op('G', b.absent(key))
		default:
			b.op('G', 0)
		}
		b.op('V', 0)
	}
	return &fuzzHist{cat: []string{"", "lookup", "random"}[cat] + "/" + distNames[kind], id: id, ops: b.ops}
}

// genClearRandom: many clear cycles in one lifetime, refill sizes from empty to well beyond the
// boundaries, B just before and just after each C.
func (cfg *fuzzCfg) genClearRandom(id int) *fuzzHist {
	r := cfg.rng(catClearRandom, id)
	kind := r.IntN(nDist)
	key := cfg.keyGen(r, kind)
	b := newHB(r)
	maxB := 2
	for maxB+1 < len(cfg.bounds) && cfg.bounds[maxB+1] <= 3000 {
		maxB++
	}
	for c := 0; c < cfg.sz.ClearCycles; c++ {
		b.op('B', 0)
		b.op('C', 0)
		b.op('B', 0)
		var n int
		switch x := r.IntN(10); {
		case x == 0:
			n = 0
		case x < 4: // around a boundary
			n = cfg.bounds[r.IntN(maxB+1)] + r.IntN(5) - 2
		case x < 9:
			n = int(math.Exp(r.Float64() * math.Log(1200)))
		default:
			n = int(math.Exp(r.Float64() * math.Log(6000)))
		}
		b.since, b.next = 0, 1+r.IntN(4)
		for len(b.keys) < n {
			if r.IntN(6) == 0 && len(b.keys) > 0 {
				b.op('I', b.anyPresent())
			} else if r.IntN(10) == 0 {
				b.op('G', b.absent(key))
			} else {
				b.op('I', b.absent(key))
			}
			b.tick()
		}
		b.op('V', 0)
	}
	return &fuzzHist{cat: "clear-random/" + distNames[kind], id: id, ops: b.ops}
}

// genClearBeyond: fill to the largest size at bucket count bcs[i], clear, and refill past
// bounds[i] (where a fresh map would leave bcs[i]), with B after every insert and V on both
// sides of the boundary; then clear and refill small, twice.
func (cfg *fuzzCfg) genClearBeyond(i, v int) *fuzzHist {
	r := cfg.rng(catClearBeyond, i*2+v)
	key := cfg.keyGen(r, []int{distTaxid, distCollide}[v])
	b := newHB(r)
	s := cfg.bounds[i]
	for len(b.keys) < s-1 {
		b.op('I', b.absent(key))
	}
	b.op('V', 0)
	b.op('B', 0)
	b.op('C', 0)
	b.op('B', 0)
	b.op('V', 0)
	end := s + s/4 + 2
	for len(b.keys) < end {
		b.op('I', b.absent(key))
		b.op('B', 0)
		if d := len(b.keys) - s; d >= -2 && d <= 2 || len(b.keys)%(s/8+1) == 0 {
			b.op('V', 0)
		}
	}
	for c := 0; c < 2; c++ {
		b.op('C', 0)
		b.op('B', 0)
		for n := 1 + r.IntN(64); len(b.keys) < n; {
			b.op('I', b.absent(key))
			b.tick()
		}
		b.op('V', 0)
	}
	return &fuzzHist{cat: fmt.Sprintf("clear-beyond/bc%d/%s", cfg.bcs[i], []string{"taxid", "collide"}[v]), id: i*2 + v, ops: b.ops}
}

var growthNames = []string{"seq", "taxid", "huge", "collide-each", "lookup-cross-G", "lookup-cross-L",
	"rev", "taxid-repeat", "dense-then-huge", "mixed"}

// genGrowth: one map grown from empty to sz.GrowthMax elements, B after every op, V at sizes 0,
// s-1, s and s+1 for every boundary s and at every power of two. Variant 4 and 5 make the
// crossing insertion (size s-1 -> s) with G or L of a new key instead of I.
func (cfg *fuzzCfg) genGrowth(v int) *fuzzHist {
	r := cfg.rng(catGrowth, v)
	b := newHB(r)
	b.op('V', 0)
	near := map[int]bool{}
	cross := map[int]bool{}
	for _, s := range cfg.bounds {
		near[s-1], near[s], near[s+1] = true, true, true
		cross[s] = true
	}
	taxid := cfg.keyGen(r, distTaxid)
	huge := cfg.keyGen(r, distHuge)
	mixed := cfg.keyGen(r, distMixed)
	seq := uint64(0)
	phase := 0
	resid := r.Uint64N(1 << 20)
	var next func() uint64
	switch growthNames[v] {
	case "seq":
		next = func() uint64 { seq++; return seq }
	case "rev":
		next = func() uint64 { seq++; return 3000000 - seq }
	case "huge":
		next = func() uint64 { return b.absent(huge) }
	case "collide-each": // keys congruent modulo the bucket count the map has now
		next = func() uint64 {
			for phase+1 < len(cfg.bcs) && cfg.bounds[phase] <= len(b.keys) {
				phase++
			}
			bc := cfg.bcs[phase]
			return b.absent(func() uint64 { return resid%bc + bc*r.Uint64N(1<<40) })
		}
	case "dense-then-huge":
		next = func() uint64 {
			if len(b.keys) < cfg.sz.GrowthMax/2 {
				seq++
				return seq - 1
			}
			return b.absent(huge)
		}
	case "mixed":
		next = func() uint64 { return b.absent(mixed) }
	default:
		next = func() uint64 { return b.absent(taxid) }
	}
	for len(b.keys) < cfg.sz.GrowthMax {
		c := byte('I')
		n := len(b.keys) + 1
		switch growthNames[v] {
		case "lookup-cross-G":
			if cross[n] {
				c = 'G'
			}
		case "lookup-cross-L":
			if cross[n] {
				c = 'L'
			}
		case "taxid-repeat":
			if r.IntN(3) == 0 && len(b.keys) > 0 {
				b.op('I', b.anyPresent())
				b.op('B', 0)
			}
		}
		b.op(c, next())
		b.op('B', 0)
		if near[n] || n&(n-1) == 0 {
			b.op('V', 0)
		}
	}
	b.op('V', 0)
	return &fuzzHist{cat: "growth/" + growthNames[v], id: v, ops: b.ops}
}

// fuzzRealHists: the per-read hit sequences of the 16 #44 reads (testdata/issue44_events.jsonl:
// upstream's own events and values on RODA v205, recorded by the #44 RODA recheck; the orphan the
// reads hit is internal 2158558), replayed as one worker's lifetime, read by read, and repeated;
// and the op history our classifier itself performs on HitCounts while classifying them
// (recorded). A hit is every non-ambiguous event with a nonzero value, repeats included, as
// classify.cc's hit_counts[taxon]++ (:1085) counts them (RODA's minimum_acceptable_hash_value is 0).
func fuzzRealHists(t *testing.T, rounds int) []fuzzHist {
	tree, _ := loadRodaLineages(t)
	f, err := os.Open(filepath.Join("testdata", "issue44_events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	type read struct {
		id       string
		hits     [][]uint64 // per mate: the hit taxa in order (0 = no hit)
		len1, l2 uint32
	}
	var reads []read
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<22)
	for sc.Scan() {
		var j struct {
			ID    string `json:"id"`
			Mates []struct {
				Len    uint32   `json:"len"`
				Events []string `json:"events"`
				Values []uint32 `json:"values"`
			} `json:"mates"`
		}
		if err := json.Unmarshal(sc.Bytes(), &j); err != nil {
			t.Fatal(err)
		}
		if len(j.Mates) != 2 {
			t.Fatalf("%s: %d mates", j.ID, len(j.Mates))
		}
		rd := read{id: j.ID, len1: j.Mates[0].Len, l2: j.Mates[1].Len}
		for _, m := range j.Mates {
			var hs []uint64
			for i, e := range m.Events {
				if strings.HasSuffix(e, ":A") || m.Values[i] == 0 {
					continue
				}
				if _, ok := tree[uint64(m.Values[i])]; !ok {
					t.Fatalf("%s: value %d not in the lineage table", j.ID, m.Values[i])
				}
				hs = append(hs, uint64(m.Values[i]))
			}
			rd.hits = append(rd.hits, hs)
		}
		reads = append(reads, rd)
	}
	if len(reads) != 16 {
		t.Fatalf("issue44_events.jsonl: %d reads, want 16", len(reads))
	}
	replay := func(b *hb, rd read, la int) {
		b.op('C', 0)
		for _, m := range rd.hits {
			for _, v := range m {
				if v != 0 {
					b.op('I', v)
				}
			}
		}
		b.op('V', 0)
		switch la % 3 {
		case 0:
			b.op('G', b.anyPresent())
		case 1: // an ancestor of the first hit, as an LCA no hit reached
			b.op('G', tree.Parent(b.keys[0]))
		default:
			b.op('G', 0)
		}
		b.op('V', 0)
	}
	var out []fuzzHist
	b := newHB(rand.New(rand.NewPCG(44, 0)))
	for i, rd := range reads {
		replay(b, rd, i)
	}
	out = append(out, fuzzHist{cat: "real/lifetime", ops: b.ops})
	for i, rd := range reads {
		for la := 0; la < 3; la++ {
			b := newHB(rand.New(rand.NewPCG(44, uint64(i))))
			replay(b, rd, la)
			out = append(out, fuzzHist{cat: "real/read/" + rd.id, id: la, ops: b.ops})
		}
	}
	r := rand.New(rand.NewPCG(44, 1))
	b = newHB(r)
	for k := 0; k < rounds; k++ {
		for _, i := range r.Perm(len(reads)) {
			replay(b, reads[i], r.IntN(3))
		}
	}
	out = append(out, fuzzHist{cat: "real/repeat", ops: b.ops})

	// Our classifier's own op history on the 13 reads, rounds/10+1 passes in one lifetime.
	c, err := New(tree, IndexInfo{DNA: true}, Options{Paired: true, MinimumHitGroups: 2}, nil)
	if err != nil {
		t.Fatal(err)
	}
	rec := &recHC{in: fuzzNewHitCounts(), ops: []hop{{'N', 0}}}
	c.hc = rec
	for p := 0; p < rounds/10+1; p++ {
		for _, rd := range reads {
			toks := c.NewTokens()
			toks.Reset()
			var mm uint64 = 1
			for mi, mate := range rd.hits {
				if mi > 0 {
					toks.MateBorder()
				}
				for _, v := range mate {
					toks.Add(mm, false)
					toks.Vals = append(toks.Vals, uint32(v))
					mm++
				}
			}
			c.Classify(toks, []byte(rd.id), rd.len1, rd.l2, &Worker{})
		}
	}
	out = append(out, fuzzHist{cat: "real/recorded-classify", ops: rec.ops})
	return out
}

// recHC records the operations the classifier performs (Range as V, Lookup as G).
type recHC struct {
	in  HitCounts
	ops []hop
}

func (h *recHC) Clear()                 { h.ops = append(h.ops, hop{'C', 0}); h.in.Clear() }
func (h *recHC) Increment(k uint64)     { h.ops = append(h.ops, hop{'I', k}); h.in.Increment(k) }
func (h *recHC) Lookup(k uint64) uint64 { h.ops = append(h.ops, hop{'G', k}); return h.in.Lookup(k) }
func (h *recHC) Range(f func(taxon, count uint64) bool) {
	h.ops = append(h.ops, hop{'V', 0})
	h.in.Range(f)
}

// harness is one umap_order process.
type harness struct {
	cmd *exec.Cmd
	w   *bufio.Writer
	in  io.WriteCloser
	r   *bufio.Reader
}

func startHarness(t *testing.T, cmdline string) *harness {
	cmd := exec.Command("sh", "-c", cmdline)
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start %q: %v", cmdline, err)
	}
	return &harness{cmd: cmd, w: bufio.NewWriterSize(in, 1<<20), in: in, r: bufio.NewReaderSize(out, 1<<20)}
}

func (h *harness) send(o hop) error {
	h.w.WriteByte(o.c)
	if o.c == 'I' || o.c == 'L' || o.c == 'G' {
		h.w.WriteByte(' ')
		var buf [20]byte
		h.w.Write(strconv.AppendUint(buf[:0], o.k, 10))
	}
	return h.w.WriteByte('\n')
}

func (h *harness) line() (string, error) {
	var sb strings.Builder
	for {
		b, err := h.r.ReadSlice('\n')
		sb.Write(b)
		if err == nil {
			s := sb.String()
			return s[:len(s)-1], nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return sb.String(), err
		}
	}
}

// mirrorHC: the selftest's stand-in for the Go side, the container itself (line-buffered).
type mirrorHC struct{ h *harness }

func (m *mirrorHC) Clear()             { m.h.send(hop{'C', 0}) }
func (m *mirrorHC) Increment(k uint64) { m.h.send(hop{'I', k}) }
func (m *mirrorHC) Lookup(k uint64) uint64 {
	m.h.send(hop{'G', k})
	m.h.w.Flush()
	l, err := m.h.line()
	if err != nil {
		panic(err)
	}
	v, _ := strconv.ParseUint(strings.TrimPrefix(l, "G "), 10, 64)
	return v
}
func (m *mirrorHC) Range(f func(taxon, count uint64) bool) {
	m.h.send(hop{'V', 0})
	m.h.w.Flush()
	l, err := m.h.line()
	if err != nil {
		panic(err)
	}
	for _, tok := range strings.Fields(l)[3:] {
		k, v, _ := strings.Cut(tok, ":")
		a, _ := strconv.ParseUint(k, 10, 64)
		c, _ := strconv.ParseUint(v, 10, 64)
		if !f(a, c) {
			return
		}
	}
}

// probe learns the bucket-count sequence of a fresh, insert-only map.
func probe(t *testing.T, cmdline string, n int) (bcs []uint64, bounds []int, lines []string) {
	h := startHarness(t, cmdline)
	go func() {
		h.send(hop{'B', 0})
		for i := 1; i <= n; i++ {
			h.send(hop{'I', uint64(i)})
			h.send(hop{'B', 0})
		}
		h.w.Flush()
		h.in.Close()
	}()
	for i := 0; i <= n; i++ {
		l, err := h.line()
		if err != nil {
			t.Fatalf("probe: line %d: %v", i, err)
		}
		f := strings.Fields(l)
		if len(f) != 3 || f[0] != "B" || f[2] != strconv.Itoa(i) {
			t.Fatalf("probe: line %d: %q", i, l)
		}
		bc, _ := strconv.ParseUint(f[1], 10, 64)
		if len(bcs) == 0 || bc != bcs[len(bcs)-1] {
			if len(bcs) > 0 {
				if bc < bcs[len(bcs)-1] {
					t.Fatalf("probe: bucket count fell at size %d: %q", i, l)
				}
				bounds = append(bounds, i)
			}
			bcs = append(bcs, bc)
			lines = append(lines, fmt.Sprintf("%d\t%d", i, bc))
		}
	}
	if err := h.cmd.Wait(); err != nil {
		t.Fatalf("probe: harness: %v", err)
	}
	return bcs[:len(bounds)+1], bounds, lines
}

type fuzzStats struct {
	Histories      map[string]int `json:"histories"`
	HistoriesByCat map[string]int `json:"histories_by_category"`
	Ops            int64          `json:"ops"`
	Prints         int64          `json:"prints_compared"`
	Entries        int64          `json:"entries_compared"`
	Lookups        int64          `json:"lookup_values_compared"`
	Clears         int64          `json:"clear_cycles"`
	AbsentInterl   int64          `json:"absent_lookups_interleaved"`
	AbsentLookups  int64          `json:"absent_lookups"`
	RetainedObs    int64          `json:"clear_bucket_observations"`
	RetainedSame   int64          `json:"clear_bucket_count_unchanged"`
	RefillBeyond   map[string]int `json:"refill_beyond_by_retained_bucket_count"`
	CrossI         map[string]int `json:"boundary_crossed_by_increment"`
	CrossLookup    map[string]int `json:"boundary_crossed_by_lookup"`
	MaxSize        int            `json:"max_size"`
	RealHistories  int            `json:"real_histories"`
}

type fuzzMismatch struct {
	hist   *fuzzHist
	opIdx  int
	detail string
	goSide string
	cxx    string
	pos    int // first differing entry of a dump, or -1
}

// replay runs one history through the implementation and compares it with the harness output.
func (st *fuzzStats) replay(h *fuzzHist, out *harness) (mm *fuzzMismatch) {
	opIdx := 0
	defer func() {
		if p := recover(); p != nil {
			mm = &fuzzMismatch{hist: h, opIdx: opIdx, detail: fmt.Sprintf("the Go side panicked: %v", p), pos: -1}
		}
	}()
	fail := func(d, g, c string) *fuzzMismatch {
		return &fuzzMismatch{hist: h, opIdx: opIdx, detail: d, goSide: g, cxx: c, pos: -1}
	}
	m := fuzzNewHitCounts()
	shadow := map[uint64]uint64{}
	type dumpRef struct {
		ok  bool
		bc  uint64
		ops int  // non-dump ops since
		op  byte // the last of them
	}
	var lastAny, lastV dumpRef
	var cycArmed, cycDone bool
	var cycBC uint64
	var prevOp byte
	var ents [][2]uint64
	for i, o := range h.ops {
		opIdx = i
		st.Ops++
		switch o.c {
		case 'N':
			if i > 0 {
				m = fuzzNewHitCounts()
			}
			clear(shadow)
			lastAny, lastV, cycArmed, prevOp = dumpRef{}, dumpRef{}, false, 0
		case 'C':
			m.Clear()
			clear(shadow)
			st.Clears++
			cycArmed, cycDone = false, false
		case 'I':
			m.Increment(o.k)
			shadow[o.k]++
		case 'L', 'G':
			_, had := shadow[o.k]
			if !had {
				st.AbsentLookups++
				if prevOp == 'I' {
					st.AbsentInterl++
				}
			}
			want := shadow[o.k]
			shadow[o.k] = want
			got := m.Lookup(o.k)
			st.Lookups++
			if got != want {
				return fail(fmt.Sprintf("Lookup(%d) returned %d, the count is %d", o.k, got, want), strconv.FormatUint(got, 10), "")
			}
			if o.c == 'G' {
				l, err := out.line()
				if err != nil {
					return fail("harness output ended: "+err.Error(), "", l)
				}
				if l != "G "+strconv.FormatUint(want, 10) {
					return fail(fmt.Sprintf("Lookup(%d): the container read a different value", o.k), "G "+strconv.FormatUint(got, 10), l)
				}
			}
		case 'P', 'V', 'B':
			l, err := out.line()
			if err != nil {
				return fail("harness output ended: "+err.Error(), "", l)
			}
			if len(l) < 2 || l[0] != o.c || l[1] != ' ' {
				return fail("harness protocol: unexpected line for "+string(o.c), "", l)
			}
			f := strings.SplitN(l, " ", 4)
			bc, _ := strconv.ParseUint(f[1], 10, 64)
			if o.c != 'P' {
				size, _ := strconv.Atoi(f[2])
				if size != len(shadow) {
					return fail(fmt.Sprintf("the container's size %d is not the model's %d (harness or model defect)", size, len(shadow)), "", l)
				}
			}
			if o.c != 'B' {
				ents = ents[:0]
				m.Range(func(k, c uint64) bool { ents = append(ents, [2]uint64{k, c}); return true })
				st.Prints++
				st.Entries += int64(len(ents))
				rest := ""
				if hdr := 2 + boolInt(o.c == 'V'); len(f) > hdr {
					rest = strings.Join(f[hdr:], " ")
				}
				if d, p := compareDump(o.c, ents, rest); d != "" {
					x := fail(d, fmtEnts(o.c, ents), l)
					x.pos = p
					return x
				}
				if len(ents) > st.MaxSize {
					st.MaxSize = len(ents)
				}
				if lastV.ok && lastV.ops == 1 && lastV.bc != bc {
					key := fmt.Sprintf("%d->%d", lastV.bc, bc)
					if lastV.op == 'I' {
						st.CrossI[key]++
					} else if lastV.op == 'L' || lastV.op == 'G' {
						st.CrossLookup[key]++
					}
				}
				lastV = dumpRef{ok: true, bc: bc}
			}
			if lastAny.ok && lastAny.ops == 1 && lastAny.op == 'C' {
				st.RetainedObs++
				if lastAny.bc == bc {
					st.RetainedSame++
				}
			}
			if lastAny.ops == 1 && prevOp == 'C' {
				cycArmed, cycBC = true, bc
			} else if cycArmed && !cycDone && bc > cycBC && cycBC > 1 {
				st.RefillBeyond[strconv.FormatUint(cycBC, 10)]++
				cycDone = true
			}
			lastAny = dumpRef{ok: true, bc: bc}
			continue
		default:
			return fail("unknown op", "", "")
		}
		prevOp = o.c
		lastAny.ops++
		lastAny.op = o.c
		lastV.ops++
		lastV.op = o.c
	}
	return nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// compareDump compares the Go side's entries with the entries of a container dump line (rest:
// "k k ..." for P, "k:v k:v ..." for V); "" and -1 if equal.
func compareDump(c byte, ents [][2]uint64, rest string) (string, int) {
	i := 0
	for len(rest) > 0 {
		tok := rest
		if sp := strings.IndexByte(rest, ' '); sp >= 0 {
			tok, rest = rest[:sp], rest[sp+1:]
		} else {
			rest = ""
		}
		if tok == "" {
			continue
		}
		if i >= len(ents) {
			return fmt.Sprintf("%c: Go yields %d entries, the container more (next %s)", c, len(ents), tok), i
		}
		ks, vs := tok, ""
		if c == 'V' {
			ks, vs, _ = strings.Cut(tok, ":")
		}
		k, err := strconv.ParseUint(ks, 10, 64)
		ok := err == nil && k == ents[i][0]
		if ok && c == 'V' {
			v, err := strconv.ParseUint(vs, 10, 64)
			ok = err == nil && v == ents[i][1]
		}
		if !ok {
			want := strconv.FormatUint(ents[i][0], 10)
			if c == 'V' {
				want += ":" + strconv.FormatUint(ents[i][1], 10)
			}
			return fmt.Sprintf("%c: first difference at entry %d (Go %s, container %s)", c, i, want, tok), i
		}
		i++
	}
	if i != len(ents) {
		return fmt.Sprintf("%c: Go yields %d entries, the container %d", c, len(ents), i), i
	}
	return "", -1
}

func fmtEnts(c byte, ents [][2]uint64) string {
	var b strings.Builder
	b.WriteByte(c)
	for _, e := range ents {
		b.WriteByte(' ')
		b.WriteString(strconv.FormatUint(e[0], 10))
		if c == 'V' {
			b.WriteByte(':')
			b.WriteString(strconv.FormatUint(e[1], 10))
		}
	}
	return b.String()
}

// window shows the tokens of a dump line around position p.
func window(line string, hdr, p int) string {
	f := strings.Fields(line)
	if len(f) < hdr {
		return line
	}
	f = f[hdr:]
	lo, hi := p-5, p+6
	if lo < 0 {
		lo = 0
	}
	if hi > len(f) {
		hi = len(f)
	}
	if lo > hi {
		lo = hi
	}
	return fmt.Sprintf("entries [%d:%d] of %d: %s", lo, hi, len(f), strings.Join(f[lo:hi], " "))
}

func TestHitOrderFuzz(t *testing.T) {
	cmdline := os.Getenv("HITORDERFUZZ_CMD")
	if cmdline == "" {
		t.Skip("HITORDERFUZZ_CMD not set (make hitorderfuzz)")
	}
	mode := os.Getenv("HITORDERFUZZ")
	if mode == "" {
		mode = "quick"
	}
	sz, err := fuzzSizesFor(mode)
	if err != nil {
		t.Fatal(err)
	}
	seed := uint64(44)
	if s := os.Getenv("HITORDERFUZZ_SEED"); s != "" {
		if seed, err = strconv.ParseUint(s, 10, 64); err != nil {
			t.Fatal(err)
		}
	}
	outDir := os.Getenv("HITORDERFUZZ_OUT")
	if outDir == "" {
		outDir = t.TempDir()
	}
	if mode == "selftest" {
		mc := os.Getenv("HITORDERFUZZ_MIRROR_CMD")
		if mc == "" {
			t.Fatal("HITORDERFUZZ=selftest needs HITORDERFUZZ_MIRROR_CMD")
		}
		mh := startHarness(t, mc)
		mirror := &mirrorHC{h: mh}
		saved := fuzzNewHitCounts
		fuzzNewHitCounts = func() HitCounts { mh.send(hop{'N', 0}); return mirror }
		defer func() { fuzzNewHitCounts = saved; mh.w.Flush(); mh.in.Close(); mh.cmd.Wait() }()
	}
	start := time.Now()

	cfg := &fuzzCfg{seed: seed, sz: sz}
	if o := os.Getenv("HITORDERFUZZ_ONLY"); o != "" {
		cfg.only = map[string]bool{}
		for _, c := range strings.Split(o, ",") {
			cfg.only[c] = true
		}
	}
	var probeLines []string
	cfg.bcs, cfg.bounds, probeLines = probe(t, cmdline, sz.GrowthMax*3/2)
	os.WriteFile(filepath.Join(outDir, "probe.tsv"), []byte("size\tbucket_count\n"+strings.Join(probeLines, "\n")+"\n"), 0o644)
	t.Logf("probe: bucket counts %v at sizes %v", cfg.bcs, cfg.bounds)
	if len(cfg.bcs) < 3 {
		t.Fatalf("probe: only %d bucket counts", len(cfg.bcs))
	}
	cfg.real = fuzzRealHists(t, sz.RealRepeat)

	st := &fuzzStats{Histories: map[string]int{}, HistoriesByCat: map[string]int{}, RefillBeyond: map[string]int{},
		CrossI: map[string]int{}, CrossLookup: map[string]int{}}
	h := startHarness(t, cmdline)
	stop := make(chan struct{})
	werr := make(chan error, 1)
	go func() {
		var err error
		cfg.each(func(x *fuzzHist) bool {
			for _, o := range x.ops {
				if err = h.send(o); err != nil {
					return false
				}
			}
			select {
			case <-stop:
				return false
			default:
				return true
			}
		})
		if err == nil {
			err = h.w.Flush()
		}
		h.in.Close()
		werr <- err
	}()
	var mm *fuzzMismatch
	cfg.each(func(x *fuzzHist) bool {
		if mm = st.replay(x, h); mm != nil {
			return false
		}
		key := x.cat
		if strings.HasPrefix(key, "real/read/") {
			key = "real/read"
		}
		st.Histories[key]++
		st.HistoriesByCat[strings.SplitN(x.cat, "/", 2)[0]]++
		if strings.HasPrefix(x.cat, "real/") {
			st.RealHistories++
		}
		return true
	})
	var failures []string
	if mm != nil {
		close(stop)
		h.cmd.Process.Kill()
		h.cmd.Wait()
		failures = append(failures, "MISMATCH: "+mm.detail)
		writeMismatch(t, outDir, cfg, mm)
	} else {
		if l, err := h.line(); err != io.EOF || l != "" {
			failures = append(failures, fmt.Sprintf("harness output after the last history: %q (%v)", l, err))
		}
		if err := <-werr; err != nil {
			failures = append(failures, "writing ops: "+err.Error())
		}
		if err := h.cmd.Wait(); err != nil {
			failures = append(failures, "harness: "+err.Error())
		}
	}

	// Coverage targets.
	var required, missingI, missingL, missingBeyond []string
	for i, s := range cfg.bounds {
		if s > sz.GrowthMax {
			continue
		}
		k := fmt.Sprintf("%d->%d", cfg.bcs[i], cfg.bcs[i+1])
		required = append(required, k)
		if st.CrossI[k] == 0 {
			missingI = append(missingI, k)
		}
		if st.CrossLookup[k] == 0 {
			missingL = append(missingL, k)
		}
		if i > 0 && st.RefillBeyond[strconv.FormatUint(cfg.bcs[i], 10)] == 0 {
			missingBeyond = append(missingBeyond, strconv.FormatUint(cfg.bcs[i], 10))
		}
	}
	if cfg.only != nil {
		failures = append(failures, "partial run (HITORDERFUZZ_ONLY="+os.Getenv("HITORDERFUZZ_ONLY")+"): never a pass")
	}
	if mm == nil && cfg.only == nil {
		if n := st.HistoriesByCat["random"]; n < sz.Random {
			failures = append(failures, fmt.Sprintf("random histories %d < %d", n, sz.Random))
		}
		if len(missingI) > 0 {
			failures = append(failures, "boundaries not crossed by an increment between two dumps: "+strings.Join(missingI, " "))
		}
		if len(missingL) > 0 {
			failures = append(failures, "boundaries not crossed by a lookup between two dumps: "+strings.Join(missingL, " "))
		}
		if len(missingBeyond) > 0 {
			failures = append(failures, "retained bucket counts never refilled beyond: "+strings.Join(missingBeyond, " "))
		}
		if st.Clears < int64(sz.MinClears) {
			failures = append(failures, fmt.Sprintf("clear cycles %d < %d", st.Clears, sz.MinClears))
		}
		if st.AbsentInterl < int64(sz.MinAbsent) {
			failures = append(failures, fmt.Sprintf("absent lookups after an increment %d < %d", st.AbsentInterl, sz.MinAbsent))
		}
		if st.RealHistories != len(cfg.real) {
			failures = append(failures, fmt.Sprintf("real histories %d of %d", st.RealHistories, len(cfg.real)))
		}
	}
	sum := map[string]any{
		"pass": len(failures) == 0, "failures": failures, "mode": mode, "seed": seed, "sizes": sz,
		"probe_bucket_counts": cfg.bcs, "probe_boundaries": cfg.bounds, "required_transitions": required,
		"stats": st, "seconds": time.Since(start).Seconds(),
	}
	if mm != nil {
		sum["mismatch"] = map[string]any{"category": mm.hist.cat, "history": mm.hist.id, "op_index": mm.opIdx,
			"op": mm.hist.ops[mm.opIdx].String(), "detail": mm.detail}
	}
	js, _ := json.MarshalIndent(sum, "", "  ")
	os.WriteFile(filepath.Join(outDir, "summary.json"), append(js, '\n'), 0o644)
	os.WriteFile(filepath.Join(outDir, "summary.md"), []byte(fuzzSummaryMD(sum, st, cfg, required)), 0o644)
	for _, f := range failures {
		t.Error(f)
	}
	if mm != nil {
		t.Errorf("history %s #%d, op %d (%s); see %s", mm.hist.cat, mm.hist.id, mm.opIdx, mm.hist.ops[mm.opIdx], filepath.Join(outDir, "mismatch.txt"))
		if mm.pos >= 0 {
			t.Errorf("around entry %d:\n Go        %s\n container %s", mm.pos, window(mm.goSide, 1, mm.pos), window(mm.cxx, offsetOf(mm.cxx), mm.pos))
		} else {
			t.Errorf(" Go        %.400s\n container %.400s", mm.goSide, mm.cxx)
		}
	}
	t.Logf("hitorderfuzz %s seed %d: %d histories, %d ops, %d prints, %d entries, %d lookups, %d clears, %.1fs",
		mode, seed, sumMap(st.HistoriesByCat), st.Ops, st.Prints, st.Entries, st.Lookups, st.Clears, time.Since(start).Seconds())
}

// offsetOf: the number of header fields before the entries of a dump line.
func offsetOf(line string) int {
	if strings.HasPrefix(line, "V ") {
		return 3
	}
	return 2
}

func sumMap(m map[string]int) int {
	n := 0
	for _, v := range m {
		n += v
	}
	return n
}

func writeMismatch(t *testing.T, dir string, cfg *fuzzCfg, mm *fuzzMismatch) {
	var b strings.Builder
	fmt.Fprintf(&b, "hitorderfuzz MISMATCH\nseed %d\nhistory %s #%d (%d ops)\nop index %d: %s\n%s\n\n",
		cfg.seed, mm.hist.cat, mm.hist.id, len(mm.hist.ops), mm.opIdx, mm.hist.ops[mm.opIdx], mm.detail)
	fmt.Fprintf(&b, "Go:\n%s\n\ncontainer:\n%s\n\nreplay: umap_order < mismatch-ops.txt (the history up to and including the op)\n", mm.goSide, mm.cxx)
	os.WriteFile(filepath.Join(dir, "mismatch.txt"), []byte(b.String()), 0o644)
	var o strings.Builder
	for _, x := range mm.hist.ops[:mm.opIdx+1] {
		o.WriteString(x.String())
		o.WriteByte('\n')
	}
	os.WriteFile(filepath.Join(dir, "mismatch-ops.txt"), []byte(o.String()), 0o644)
}

func fuzzSummaryMD(sum map[string]any, st *fuzzStats, cfg *fuzzCfg, required []string) string {
	var b strings.Builder
	pass := sum["pass"].(bool)
	fmt.Fprintf(&b, "# make hitorderfuzz: HitCounts vs std::unordered_map (AL2023 g++)\n\n")
	fmt.Fprintf(&b, "Generated by TestHitOrderFuzz from this run's own counters (summary.json); docs/hitorderfuzz.md.\n\n")
	fmt.Fprintf(&b, "- mode %s, seed %d, %.1f s\n", sum["mode"], cfg.seed, sum["seconds"])
	if pass {
		fmt.Fprintf(&b, "- **PASS**: no mismatch, every coverage target met\n")
	} else {
		fmt.Fprintf(&b, "- **FAIL**:\n")
		for _, f := range sum["failures"].([]string) {
			fmt.Fprintf(&b, "  - %s\n", f)
		}
	}
	fmt.Fprintf(&b, "- ops %d; prints compared %d (entries %d); lookup values compared %d; max map size %d\n",
		st.Ops, st.Prints, st.Entries, st.Lookups, st.MaxSize)
	fmt.Fprintf(&b, "- clear cycles %d; bucket count after C equal to before in %d of %d observations\n", st.Clears, st.RetainedSame, st.RetainedObs)
	fmt.Fprintf(&b, "- absent lookups %d, of which right after an increment %d\n\n", st.AbsentLookups, st.AbsentInterl)
	fmt.Fprintf(&b, "## Histories passed, by category\n\n| category | histories |\n|---|---:|\n")
	var cats []string
	for c := range st.Histories {
		cats = append(cats, c)
	}
	sort.Strings(cats)
	for _, c := range cats {
		fmt.Fprintf(&b, "| %s | %d |\n", c, st.Histories[c])
	}
	fmt.Fprintf(&b, "\n## Rehash boundaries (probe: fresh map, insert only)\n\n")
	fmt.Fprintf(&b, "| transition | at size | crossed by I (V both sides) | crossed by lookup (V both sides) | clear, then refilled beyond (retained = from) |\n|---|---:|---:|---:|---:|\n")
	for i, k := range required {
		beyond := "-"
		if i > 0 {
			beyond = strconv.Itoa(st.RefillBeyond[strconv.FormatUint(cfg.bcs[i], 10)])
		}
		fmt.Fprintf(&b, "| %s | %d | %d | %d | %s |\n", k, cfg.bounds[i], st.CrossI[k], st.CrossLookup[k], beyond)
	}
	if m, ok := sum["mismatch"]; ok {
		js, _ := json.MarshalIndent(m, "", "  ")
		fmt.Fprintf(&b, "\n## First mismatch\n\n```\n%s\n```\n\nFull detail: mismatch.txt; replay: mismatch-ops.txt.\n", js)
	}
	return b.String()
}
