package report

// Differential fuzz of stdSort against libstdc++'s std::sort (issue #35, docs/sortfuzz.md).
//
// Opt-in: skipped unless SORTFUZZ_BIN names the upstream/sortfuzz.cc binary, so `make test` stays
// fast. `make sortfuzz [SORTFUZZ=quick|full]` builds the binary and runs this.
//
//	SORTFUZZ_BIN   path to the sortfuzz binary (required)
//	SORTFUZZ       quick (default) or full
//	SORTFUZZ_SEED  corpus seed (default 35)
//	SORTFUZZ_OUT   directory for summary.json, summary.md and, on a mismatch, mismatch.json
//
// Every case is a list of distinct ids (taxids) with a key each (the clade count, or absent from
// the counter map). The C++ side sorts the ids with std::sort and upstream's KrakenReportDFS
// comparator; this side sorts the same ids, in the same initial order, with fuzzSort and the same
// comparator (report.go's, which the mpa-style one is a special case of: no absent keys). The
// permutations must be identical. The first mismatch stops the run with full detail.

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"
)

// fuzzSort is the implementation under test.
var fuzzSort = stdSort

const (
	fuzzMaxEveryN   = 2048 // every n in [0, fuzzMaxEveryN] is covered
	fuzzDefaultSeed = 35
)

type fuzzCase struct {
	cat  string
	ids  []uint32 // initial order; distinct, spanning [base, base+n)
	keys []int32  // keys[i] belongs to ids[i]; < 0 means absent
}

// fuzzLess is report.go's kraken-style comparator over a case's keys, indexed by id - base.
func fuzzLess(byID []int32, base uint64) func(a, b uint64) bool {
	return func(a, b uint64) bool {
		ka := byID[a-base]
		if ka < 0 {
			return false
		}
		kb := byID[b-base]
		if kb < 0 {
			return true
		}
		return int64(ka) > int64(kb)
	}
}

type fuzzSizes struct {
	Random       int   `json:"random"`
	EveryNPerN   int   `json:"every_n_per_n"`
	DenseN       []int `json:"dense_n"`
	DensePerN    int   `json:"dense_per_n"`
	StructuredN  int   `json:"structured_max_n"`
	KillerN      []int `json:"killer_n"`
	KillerVaried int   `json:"killer_variants_per_n"`
}

func fuzzSizesFor(mode string) (fuzzSizes, error) {
	var dense []int
	for n := 8; n <= 40; n++ { // around 15, 16, 17 (_S_threshold) and 32
		dense = append(dense, n)
	}
	var s fuzzSizes
	switch mode {
	case "quick":
		s = fuzzSizes{Random: 20000, EveryNPerN: 1, DensePerN: 40}
		for n := 17; n <= 200; n += 3 {
			s.KillerN = append(s.KillerN, n)
		}
		s.KillerN = append(s.KillerN, 256, 511, 512, 1024, 2048, 4096)
	case "full":
		s = fuzzSizes{Random: 1000000, EveryNPerN: 4, DensePerN: 400}
		for n := 17; n <= 512; n++ {
			s.KillerN = append(s.KillerN, n)
		}
		for n := 519; n <= 2048; n += 7 {
			s.KillerN = append(s.KillerN, n)
		}
		s.KillerN = append(s.KillerN, 2048, 4095, 4096, 8192, 16384, 32768)
	default:
		return s, fmt.Errorf("SORTFUZZ=%q: want quick or full", mode)
	}
	s.DenseN = dense
	s.StructuredN = fuzzMaxEveryN
	s.KillerVaried = 7
	return s, nil
}

type fuzzGen struct {
	r      *rand.Rand
	killer func(n int) ([]int32, error)
}

// finish gives keys their ids: a random base and a random permutation of [base, base+n).
func (g *fuzzGen) finish(cat string, keys []int32) fuzzCase {
	n := len(keys)
	base := 1 + g.r.Uint32N(1<<31)
	ids := make([]uint32, n)
	for i, p := range g.r.Perm(n) {
		ids[i] = base + uint32(p)
	}
	return fuzzCase{cat: cat, ids: ids, keys: keys}
}

// tiedKeys draws n keys with a random tie density: alphabet size, shape and absent rate vary.
func (g *fuzzGen) tiedKeys(n int) []int32 {
	r := g.r
	alpha := []int{1, 2, 2, 3, 3, 4, 4, 5, 6, 8, 12, 16, 32, 64, n/16 + 1, n/4 + 1, n + 1, 1 << 30}
	k := alpha[r.IntN(len(alpha))]
	absent := []float64{0, 0, 0, 0, 0.02, 0.1, 0.3, 0.6, 0.9, 1}[r.IntN(10)]
	scale, off := 1, 0
	if k < 1<<20 && r.IntN(4) == 0 {
		scale = []int{2, 7, 1000}[r.IntN(3)]
		off = r.IntN(1 << 10)
	}
	shape := r.IntN(8)
	dom, domP := r.IntN(k), 0.5+0.45*r.Float64()
	period := 1 + r.IntN(max(1, n/2+1))
	keys := make([]int32, n)
	for i := range keys {
		var v int
		switch shape {
		case 0, 1: // uniform
			v = r.IntN(k)
		case 2: // skewed towards small values
			v = min(r.IntN(k), r.IntN(k), r.IntN(k))
		case 3: // one dominant value
			if r.Float64() < domP {
				v = dom
			} else {
				v = r.IntN(k)
			}
		case 4: // descending (already in comparator order) with noise
			v = (n - i) * k / (n + 1)
			if r.IntN(8) == 0 {
				v = r.IntN(k)
			}
		case 5: // ascending (reverse order) with noise
			v = i * k / (n + 1)
			if r.IntN(8) == 0 {
				v = r.IntN(k)
			}
		case 6: // organ pipe
			v = min(i, n-1-i) * k / (n/2 + 1)
		case 7: // sawtooth
			v = (i % period) * k / period
		}
		v = v*scale + off
		if r.Float64() < absent {
			v = -1
		}
		keys[i] = int32(v)
	}
	return keys
}

func (g *fuzzGen) randomN() int {
	switch u := g.r.Float64(); {
	case u < 0.55:
		return g.r.IntN(65)
	case u < 0.90:
		return 65 + g.r.IntN(448)
	default:
		return 513 + g.r.IntN(fuzzMaxEveryN-512)
	}
}

func structured(n int) map[string][]int32 {
	m := map[string][]int32{}
	add := func(name string, f func(i int) int) {
		k := make([]int32, n)
		for i := range k {
			k[i] = int32(f(i))
		}
		m[name] = k
	}
	add("all-equal", func(int) int { return 5 })
	add("all-absent", func(int) int { return -1 })
	add("sorted", func(i int) int { return n - i })
	add("reverse", func(i int) int { return i })
	add("sorted-ties", func(i int) int { return (n - i) / 3 })
	add("reverse-ties", func(i int) int { return i / 3 })
	add("sorted-absent-tail", func(i int) int {
		if i >= n-n/4 {
			return -1
		}
		return n - i
	})
	add("reverse-absent-head", func(i int) int {
		if i < n/4 {
			return -1
		}
		return i
	})
	return m
}

// corpus emits every case in a fixed order; emit returns false to stop.
func (g *fuzzGen) corpus(s fuzzSizes, emit func(fuzzCase) bool) error {
	// Structured inputs, every n.
	names := []string{"all-equal", "all-absent", "sorted", "reverse", "sorted-ties", "reverse-ties", "sorted-absent-tail", "reverse-absent-head"}
	for n := 0; n <= s.StructuredN; n++ {
		m := structured(n)
		for _, name := range names {
			if !emit(g.finish("structured/"+name, m[name])) {
				return nil
			}
		}
	}
	// Every n, then dense n.
	for n := 0; n <= fuzzMaxEveryN; n++ {
		for range s.EveryNPerN {
			if !emit(g.finish("every-n", g.tiedKeys(n))) {
				return nil
			}
		}
	}
	for _, n := range s.DenseN {
		for range s.DensePerN {
			if !emit(g.finish("dense-n", g.tiedKeys(n))) {
				return nil
			}
		}
	}
	// Median-of-3 killers (McIlroy's adversary against this std::sort) and variants.
	for _, n := range s.KillerN {
		k, err := g.killer(n)
		if err != nil {
			return err
		}
		variants := []struct {
			name string
			f    func(v int32) int32
		}{
			{"raw", func(v int32) int32 { return v }},
			{"gas-absent", func(v int32) int32 {
				if v == 0 {
					return -1
				}
				return v
			}},
			{"halved", func(v int32) int32 { return v / 2 }},
			{"quartered", func(v int32) int32 { return v / 4 }},
		}
		for _, vr := range variants {
			keys := make([]int32, n)
			for i := range k {
				keys[i] = vr.f(k[i])
			}
			if !emit(g.finish("killer/"+vr.name, keys)) {
				return nil
			}
		}
		swapped := slices.Clone(k)
		for range 1 + g.r.IntN(3) {
			i, j := g.r.IntN(n), g.r.IntN(n)
			swapped[i], swapped[j] = swapped[j], swapped[i]
		}
		rotated := append(slices.Clone(k[1:]), k[0])
		padded := append(slices.Clone(k), g.tiedKeys(1+g.r.IntN(64))...)
		for _, c := range []struct {
			name string
			keys []int32
		}{{"swapped", swapped}, {"rotated", rotated}, {"padded", padded}} {
			if !emit(g.finish("killer/"+c.name, c.keys)) {
				return nil
			}
		}
	}
	// Random heavy-tie cases.
	for range s.Random {
		if !emit(g.finish("random", g.tiedKeys(g.randomN()))) {
			return nil
		}
	}
	return nil
}

func killerFunc(bin string) func(n int) ([]int32, error) {
	return func(n int) ([]int32, error) {
		out, err := exec.Command(bin, "--killer", strconv.Itoa(n)).Output()
		if err != nil {
			return nil, fmt.Errorf("%s --killer %d: %v", bin, n, err)
		}
		f := strings.Fields(string(out))
		if len(f) != n {
			return nil, fmt.Errorf("%s --killer %d: %d keys", bin, n, len(f))
		}
		k := make([]int32, n)
		for i, s := range f {
			v, err := strconv.ParseInt(s, 10, 32)
			if err != nil {
				return nil, err
			}
			k[i] = int32(v)
		}
		return k, nil
	}
}

type cxxResult struct {
	heap  uint32
	comps uint64
	ids   []uint32
}

// oracle is a running sortfuzz process.
type oracle struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	w   *bufio.Writer
	out *bufio.Reader
}

func startOracle(bin string) (*oracle, error) {
	cmd := exec.Command(bin)
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	return &oracle{cmd: cmd, in: in, w: bufio.NewWriterSize(in, 1<<20), out: bufio.NewReaderSize(out, 1<<20)}, nil
}

func (o *oracle) send(c fuzzCase) error {
	var b [8]byte
	binary.LittleEndian.PutUint32(b[:4], uint32(len(c.ids)))
	if _, err := o.w.Write(b[:4]); err != nil {
		return err
	}
	for i, id := range c.ids {
		binary.LittleEndian.PutUint32(b[:4], id)
		binary.LittleEndian.PutUint32(b[4:], uint32(c.keys[i]))
		if _, err := o.w.Write(b[:]); err != nil {
			return err
		}
	}
	return nil
}

func (o *oracle) recv() (cxxResult, error) {
	var h [16]byte
	if _, err := io.ReadFull(o.out, h[:]); err != nil {
		return cxxResult{}, err
	}
	r := cxxResult{heap: binary.LittleEndian.Uint32(h[:4]), comps: binary.LittleEndian.Uint64(h[4:12])}
	n := binary.LittleEndian.Uint32(h[12:])
	buf := make([]byte, 4*int(n))
	if _, err := io.ReadFull(o.out, buf); err != nil {
		return cxxResult{}, err
	}
	r.ids = make([]uint32, n)
	for i := range r.ids {
		r.ids[i] = binary.LittleEndian.Uint32(buf[4*i:])
	}
	return r, nil
}

// sortOurs runs fuzzSort on the case and returns the ids in output order.
func sortOurs(c fuzzCase) []uint32 {
	n := len(c.ids)
	if n == 0 {
		fuzzSort(nil, func(a, b uint64) bool { return false })
		return []uint32{}
	}
	base := uint64(slices.Min(c.ids))
	byID := make([]int32, n)
	a := make([]uint64, n)
	for i, id := range c.ids {
		a[i] = uint64(id)
		byID[uint64(id)-base] = c.keys[i]
	}
	fuzzSort(a, fuzzLess(byID, base))
	out := make([]uint32, n)
	for i, v := range a {
		out[i] = uint32(v)
	}
	return out
}

type catStats struct {
	Cases     int    `json:"cases"`
	Elements  int64  `json:"elements"`
	HeapCases int    `json:"heap_cases"`
	HeapCalls int64  `json:"heap_calls"`
	MaxComps  uint64 `json:"max_comps"`
}

type fuzzSummary struct {
	Mode       string               `json:"mode"`
	Seed       uint64               `json:"seed"`
	Sizes      fuzzSizes            `json:"sizes"`
	Oracle     string               `json:"oracle"`
	Cases      int                  `json:"cases"`
	Elements   int64                `json:"elements"`
	Mismatches int                  `json:"mismatches"`
	HeapCases  int                  `json:"heap_cases"`
	HeapCalls  int64                `json:"heap_calls"`
	MinN       int                  `json:"min_n"`
	MaxN       int                  `json:"max_n"`
	DistinctN  int                  `json:"distinct_n"`
	EveryNOK   bool                 `json:"every_n_0_to_2048"`
	NCount     map[string]int       `json:"cases_at_n"` // n = 15, 16, 17, 32
	ByCategory map[string]*catStats `json:"by_category"`
	Seconds    float64              `json:"seconds"`
	Pass       bool                 `json:"pass"`
	Failure    string               `json:"failure,omitempty"`
}

type mismatch struct {
	Index    int      `json:"index"`
	Category string   `json:"category"`
	N        int      `json:"n"`
	FirstAt  int      `json:"first_diff_at"`
	Heap     uint32   `json:"cxx_heap_calls"`
	IDs      []uint32 `json:"input_ids"`
	Keys     []int32  `json:"input_keys"`
	Want     []uint32 `json:"cxx_order"`
	Got      []uint32 `json:"go_order"`
}

func fuzzEnv(t *testing.T) (bin, mode string, seed uint64, outDir string) {
	bin = os.Getenv("SORTFUZZ_BIN")
	if bin == "" {
		t.Skip("SORTFUZZ_BIN unset (make sortfuzz; docs/sortfuzz.md)")
	}
	mode = os.Getenv("SORTFUZZ")
	if mode == "" {
		mode = "quick"
	}
	seed = fuzzDefaultSeed
	if s := os.Getenv("SORTFUZZ_SEED"); s != "" {
		v, err := strconv.ParseUint(s, 10, 64)
		if err != nil {
			t.Fatalf("SORTFUZZ_SEED=%q: %v", s, err)
		}
		seed = v
	}
	return bin, mode, seed, os.Getenv("SORTFUZZ_OUT")
}

// TestSortFuzzHeapProbe shows the heapsort detection works both ways: a McIlroy adversary
// input enters the fallback (and stays O(n log n) in comparisons, where without it the adversary
// forces a quadratic count), while inputs that cannot reach the depth limit do not.
func TestSortFuzzHeapProbe(t *testing.T) {
	bin, _, _, _ := fuzzEnv(t)
	o, err := startOracle(bin)
	if err != nil {
		t.Fatal(err)
	}
	g := &fuzzGen{r: rand.New(rand.NewPCG(1, 2)), killer: killerFunc(bin)}
	const n = 4096
	k, err := g.killer(n)
	if err != nil {
		t.Fatal(err)
	}
	random16 := g.tiedKeys(16)
	cases := []struct {
		c        fuzzCase
		wantHeap bool
	}{
		{g.finish("killer", k), true},
		{g.finish("sorted", structured(n)["sorted"]), false},   // perfect median splits: depth lg n
		{g.finish("reverse", structured(n)["reverse"]), false}, // likewise
		{g.finish("n=16", random16), false},                    // never enters the introsort loop
	}
	go func() {
		for _, c := range cases {
			if err := o.send(c.c); err != nil {
				t.Error(err)
			}
		}
		_ = o.w.Flush()
		_ = o.in.Close()
	}()
	for _, c := range cases {
		r, err := o.recv()
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("%-8s n=%d heap_calls=%d comparisons=%d (n*n/4=%d)", c.c.cat, len(c.c.ids), r.heap, r.comps, len(c.c.ids)*len(c.c.ids)/4)
		if (r.heap > 0) != c.wantHeap {
			t.Errorf("%s: heap_calls=%d, want heap=%v", c.c.cat, r.heap, c.wantHeap)
		}
		if c.wantHeap && r.comps > uint64(n*n/16) {
			t.Errorf("%s: %d comparisons, not O(n log n)", c.c.cat, r.comps)
		}
	}
	if err := o.cmd.Wait(); err != nil {
		t.Fatal(err)
	}
}

func TestSortFuzz(t *testing.T) {
	bin, mode, seed, outDir := fuzzEnv(t)
	sizes, err := fuzzSizesFor(mode)
	if err != nil {
		t.Fatal(err)
	}
	ver, err := exec.Command(bin, "--version").Output()
	if err != nil {
		t.Fatalf("%s --version: %v", bin, err)
	}
	sum := &fuzzSummary{Mode: mode, Seed: seed, Sizes: sizes, Oracle: strings.TrimSpace(string(ver)),
		MinN: -1, NCount: map[string]int{}, ByCategory: map[string]*catStats{}}
	t.Logf("oracle: %s; mode %s; seed %d", sum.Oracle, mode, seed)

	o, err := startOracle(bin)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	g := &fuzzGen{r: rand.New(rand.NewPCG(seed, 35)), killer: killerFunc(bin)}
	cases := make(chan fuzzCase, 4096)
	stop := make(chan struct{})
	genErr := make(chan error, 1)
	go func() {
		defer close(cases)
		err := g.corpus(sizes, func(c fuzzCase) bool {
			select {
			case cases <- c:
			default:
				// The reader is waiting on output for cases still in our buffer: flush first.
				if o.w.Flush() != nil {
					return false
				}
				select {
				case cases <- c:
				case <-stop:
					return false
				}
			}
			return o.send(c) == nil
		})
		if ferr := o.w.Flush(); err == nil && ferr != nil {
			select {
			case <-stop:
			default:
				err = ferr
			}
		}
		_ = o.in.Close()
		genErr <- err
	}()

	var bad *mismatch
	seenN := map[int]bool{}
	idx := 0
	for c := range cases {
		r, err := o.recv()
		if err != nil {
			close(stop)
			t.Fatalf("case %d (%s, n=%d): reading the oracle: %v", idx, c.cat, len(c.ids), err)
		}
		got := sortOurs(c)
		n := len(c.ids)
		cs := sum.ByCategory[c.cat]
		if cs == nil {
			cs = &catStats{}
			sum.ByCategory[c.cat] = cs
		}
		cs.Cases++
		cs.Elements += int64(n)
		cs.MaxComps = max(cs.MaxComps, r.comps)
		if r.heap > 0 {
			cs.HeapCases++
			cs.HeapCalls += int64(r.heap)
			sum.HeapCases++
			sum.HeapCalls += int64(r.heap)
		}
		sum.Cases++
		sum.Elements += int64(n)
		seenN[n] = true
		if sum.MinN < 0 || n < sum.MinN {
			sum.MinN = n
		}
		sum.MaxN = max(sum.MaxN, n)
		switch n {
		case 15, 16, 17, 32:
			sum.NCount[strconv.Itoa(n)]++
		}
		if !slices.Equal(got, r.ids) {
			first := 0
			for first < len(got) && first < len(r.ids) && got[first] == r.ids[first] {
				first++
			}
			bad = &mismatch{Index: idx, Category: c.cat, N: n, FirstAt: first, Heap: r.heap,
				IDs: c.ids, Keys: c.keys, Want: r.ids, Got: got}
			sum.Mismatches = 1
			close(stop)
			_ = o.cmd.Process.Kill()
			for range cases { // let the generator exit
			}
			break
		}
		idx++
	}
	if bad == nil {
		if err := <-genErr; err != nil {
			t.Fatalf("corpus: %v", err)
		}
		if err := o.cmd.Wait(); err != nil {
			t.Fatalf("oracle exited: %v", err)
		}
	} else {
		_ = o.cmd.Wait()
	}
	sum.Seconds = time.Since(start).Seconds()
	sum.DistinctN = len(seenN)
	sum.EveryNOK = true
	for n := 0; n <= fuzzMaxEveryN; n++ {
		sum.EveryNOK = sum.EveryNOK && seenN[n]
	}

	var fails []string
	if bad != nil {
		fails = append(fails, fmt.Sprintf("mismatch at case %d (%s, n=%d)", bad.Index, bad.Category, bad.N))
	}
	if bad == nil && sum.HeapCases == 0 {
		fails = append(fails, "the heapsort fallback was never hit")
	}
	if bad == nil && !sum.EveryNOK {
		fails = append(fails, "n coverage 0..2048 incomplete")
	}
	if bad == nil {
		kh := 0
		for cat, cs := range sum.ByCategory {
			if strings.HasPrefix(cat, "killer/raw") {
				kh += cs.HeapCases
			}
		}
		if kh == 0 {
			fails = append(fails, "no raw killer case hit the heapsort fallback")
		}
	}
	sum.Pass = len(fails) == 0
	sum.Failure = strings.Join(fails, "; ")
	if outDir != "" {
		if err := writeFuzzOut(outDir, sum, bad); err != nil {
			t.Error(err)
		}
	}
	t.Logf("cases %d (elements %d), mismatches %d, heapsort cases %d (calls %d), n %d..%d (%d distinct, every 0..2048: %v), %.1fs",
		sum.Cases, sum.Elements, sum.Mismatches, sum.HeapCases, sum.HeapCalls, sum.MinN, sum.MaxN, sum.DistinctN, sum.EveryNOK, sum.Seconds)
	if bad != nil {
		t.Fatalf("MISMATCH: %s\n%s", sum.Failure, describeMismatch(bad))
	}
	if !sum.Pass {
		t.Fatal(sum.Failure)
	}
}

func describeMismatch(m *mismatch) string {
	var b strings.Builder
	fmt.Fprintf(&b, "case %d, category %s, n=%d, C++ heapsort calls %d, first differing output position %d\n",
		m.Index, m.Category, m.N, m.Heap, m.FirstAt)
	lim := len(m.IDs)
	if lim > 64 {
		lim = 64
		fmt.Fprintf(&b, "(first 64 of %d shown; mismatch.json has all)\n", len(m.IDs))
	}
	b.WriteString("input (id:key, key<0 = absent):")
	for i := range lim {
		fmt.Fprintf(&b, " %d:%d", m.IDs[i], m.Keys[i])
	}
	lo, hi := max(0, m.FirstAt-8), min(m.N, m.FirstAt+8)
	fmt.Fprintf(&b, "\nstd::sort [%d:%d]: %v\nGo        [%d:%d]: %v\n", lo, hi, m.Want[lo:hi], lo, hi, m.Got[lo:min(hi, len(m.Got))])
	return b.String()
}

func writeFuzzOut(dir string, sum *fuzzSummary, bad *mismatch) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	j, err := json.MarshalIndent(sum, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "summary.json"), append(j, '\n'), 0o644); err != nil {
		return err
	}
	if bad != nil {
		j, err := json.MarshalIndent(bad, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "mismatch.json"), append(j, '\n'), 0o644); err != nil {
			return err
		}
	}
	var b strings.Builder
	verdict := "PASS"
	if !sum.Pass {
		verdict = "FAIL: " + sum.Failure
	}
	fmt.Fprintf(&b, "# sortfuzz (%s): %s\n\n", sum.Mode, verdict)
	fmt.Fprintf(&b, "Generated by internal/report/sortfuzz_test.go. Oracle: `%s`. Seed %d.\n\n", sum.Oracle, sum.Seed)
	fmt.Fprintf(&b, "| cases | elements | mismatches | heapsort-hit cases | heapsort calls | n range | distinct n | every n 0..2048 | cases at n=15/16/17/32 | seconds |\n|---|---|---|---|---|---|---|---|---|---|\n")
	fmt.Fprintf(&b, "| %d | %d | %d | %d | %d | %d..%d | %d | %v | %d/%d/%d/%d | %.1f |\n\n",
		sum.Cases, sum.Elements, sum.Mismatches, sum.HeapCases, sum.HeapCalls, sum.MinN, sum.MaxN, sum.DistinctN, sum.EveryNOK,
		sum.NCount["15"], sum.NCount["16"], sum.NCount["17"], sum.NCount["32"], sum.Seconds)
	b.WriteString("| category | cases | elements | heapsort-hit cases | heapsort calls | max comparisons |\n|---|---|---|---|---|---|\n")
	cats := make([]string, 0, len(sum.ByCategory))
	for c := range sum.ByCategory {
		cats = append(cats, c)
	}
	slices.Sort(cats)
	for _, c := range cats {
		cs := sum.ByCategory[c]
		fmt.Fprintf(&b, "| %s | %d | %d | %d | %d | %d |\n", c, cs.Cases, cs.Elements, cs.HeapCases, cs.HeapCalls, cs.MaxComps)
	}
	if bad != nil {
		fmt.Fprintf(&b, "\n## First mismatch\n\n```\n%s```\n\nFull case: `mismatch.json`.\n", describeMismatch(bad))
	}
	return os.WriteFile(filepath.Join(dir, "summary.md"), []byte(b.String()), 0o644)
}
