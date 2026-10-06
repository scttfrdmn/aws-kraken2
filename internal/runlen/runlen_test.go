package runlen

import (
	"encoding/binary"
	"math"
	"math/rand/v2"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
)

// table builds a 32-bit cell image (no header) for value_bits = 22 with the given occupancy.
// Occupied cells carry value 1 and compacted key 0.
func table(occ []bool) []byte {
	b := make([]byte, 4*len(occ))
	for i, o := range occ {
		if o {
			binary.LittleEndian.PutUint32(b[4*i:], 1)
		}
	}
	return b
}

func randOcc(rng *rand.Rand, c int, p float64, clustered bool) []bool {
	occ := make([]bool, c)
	if !clustered {
		for i := range occ {
			occ[i] = rng.Float64() < p
		}
	} else {
		// Insert keys by linear probing from uniform homes, like the real table.
		n := int(p * float64(c))
		for k := 0; k < n; k++ {
			h := rng.IntN(c)
			for occ[h] {
				h = (h + 1) % c
			}
			occ[h] = true
		}
	}
	// Force interesting edges sometimes.
	switch rng.IntN(4) {
	case 0:
		occ[0], occ[c-1] = true, true
	case 1:
		occ[0] = false
	case 2:
		occ[c-1] = false
	}
	ok := false
	for _, o := range occ {
		if !o {
			ok = true
		}
	}
	if !ok {
		occ[rng.IntN(c)] = false
	}
	return occ
}

// chunked runs the streaming path with random chunk sizes.
func chunked(t *testing.T, rng *rand.Rand, img []byte, bounds []uint64, maxChunk int) *Result {
	t.Helper()
	c := uint64(len(img) / 4)
	a, err := NewAccumulator(c, bounds)
	if err != nil {
		t.Fatal(err)
	}
	var ch Chunk
	for s := uint64(0); s < c; {
		n := uint64(1 + rng.IntN(maxChunk))
		if rng.IntN(10) == 0 {
			n = 0 // empty chunks are legal
		}
		e := min(s+n, c)
		ScanChunk32(img[4*s:4*e], s, 1<<22-1, bounds, &ch)
		if err := a.Add(&ch); err != nil {
			t.Fatal(err)
		}
		s = e
	}
	r, err := a.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestChunkedMatchesBrute(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	for iter := 0; iter < 3000; iter++ {
		c := 64 + rng.IntN(600)
		p := []float64{0.1, 0.5, 0.7, 0.9, 0.97}[rng.IntN(5)]
		occ := randOcc(rng, c, p, rng.IntN(2) == 0)
		img := table(occ)
		maxN := []int{2, 8, 64}[rng.IntN(3)]
		bounds := Bounds(uint64(c), maxN)
		want, err := Brute(occ, bounds)
		if err != nil {
			t.Fatal(err)
		}
		got := chunked(t, rng, img, bounds, []int{1, 3, 17, 1000}[rng.IntN(4)])
		if err := Check(got, want); err != nil {
			t.Fatalf("iter %d (C=%d p=%v): %v", iter, c, p, err)
		}
		// The reported longest start begins a run of that length.
		s := got.LongestStart
		if occ[(s+uint64(c)-1)%uint64(c)] {
			t.Fatalf("iter %d: longest start %d is not a run start", iter, s)
		}
		for k := uint64(0); k < got.Longest; k++ {
			if !occ[(s+k)%uint64(c)] {
				t.Fatalf("iter %d: longest run at %d breaks at +%d", iter, s, k)
			}
		}
		var sum uint64
		for _, ln := range got.Hist.Lengths() {
			sum += ln[0] * ln[1]
		}
		if sum != got.Occupied {
			t.Fatalf("iter %d: histogram covers %d cells, occupied %d", iter, sum, got.Occupied)
		}
	}
}

// cells adapts an image to chash.CellSource.
type cells []byte

func (c cells) Cell(i uint64) (uint64, error) {
	return uint64(binary.LittleEndian.Uint32(c[4*i:])), nil
}

// TestTailIsWhatProbesRead checks the tail definition against chash.Probe itself: for every
// boundary, the furthest any miss with its home in the shard ending there reads past the
// boundary equals Tail. Misses are forced by a compacted key that never matches (cells hold key
// 0; the probed hash's top key_bits are all ones).
func TestTailIsWhatProbesRead(t *testing.T) {
	rng := rand.New(rand.NewPCG(3, 4))
	for iter := 0; iter < 300; iter++ {
		c := 64 + rng.IntN(300)
		occ := randOcc(rng, c, []float64{0.5, 0.7, 0.9}[rng.IntN(3)], true)
		img := table(occ)
		bounds := Bounds(uint64(c), 64)
		r := chunked(t, rng, img, bounds, 50)
		l := chash.Layout{Capacity: uint64(c), KeyBits: 10, ValueBits: 22, CellBytes: 4}
		for n := 2; n <= 64; n *= 2 {
			step := 64 / n
			var maxTail uint64
			for i := 0; i < n; i++ {
				hi := bounds[(i+1)*step-1]
				lo := uint64(0)
				if i > 0 {
					lo = bounds[i*step-1]
				}
				var past uint64
				for h := lo; h < hi; h++ {
					// hc in [1023<<54, 2^64) has compacted key 1023; pick the one with home h.
					base := uint64(1023) << 54
					hc := base + (h+uint64(c)-base%uint64(c))%uint64(c)
					v, probes, _, err := chash.Probe(l, chash.Linear, hc, cells(img))
					if err != nil || v != 0 {
						t.Fatalf("probe: v=%d err=%v", v, err)
					}
					// Cells read: h, h+1, …, h+probes-1 (mod C); those at or past hi.
					if end := h + uint64(probes); end > hi {
						past = max(past, end-hi)
					}
				}
				if past != r.Boundaries[(i+1)*step-1].Tail {
					t.Fatalf("iter %d N=%d shard %d [%d,%d): probes read %d past, Tail %d",
						iter, n, i, lo, hi, past, r.Boundaries[(i+1)*step-1].Tail)
				}
				maxTail = max(maxTail, past)
			}
			got, _, err := r.TailForN(n)
			if err != nil || got != maxTail {
				t.Fatalf("iter %d N=%d: TailForN %d, probes %d (%v)", iter, n, got, maxTail, err)
			}
		}
	}
}

func TestBoundsNested(t *testing.T) {
	for _, c := range []uint64{64, 65, 1000, 297272917942, math.MaxUint64 / 3} {
		b := Bounds(c, 64)
		if b[63] != c {
			t.Fatalf("C=%d: last boundary %d", c, b[63])
		}
		for n := 2; n <= 64; n *= 2 {
			bn := Bounds(c, n)
			for i := range bn {
				if bn[i] != b[(i+1)*(64/n)-1] {
					t.Fatalf("C=%d N=%d: boundary %d is %d, not in the N=64 set", c, n, i, bn[i])
				}
			}
		}
	}
}

func TestTheorySums(t *testing.T) {
	cells, occ := uint64(1_000_000_000), uint64(699_127_744)
	var runs, cov float64
	for l := uint64(1); l < 20000; l++ {
		e := TheoryRuns(cells, occ, l)
		runs += e
		cov += e * float64(l)
	}
	a := float64(occ) / float64(cells)
	if want := float64(cells-occ) * (1 - math.Exp(-a)); math.Abs(runs-want)/want > 1e-9 {
		t.Fatalf("runs %g, want %g", runs, want)
	}
	if math.Abs(cov-float64(occ))/float64(occ) > 1e-9 {
		t.Fatalf("occupied %g, want %d", cov, occ)
	}
}

func TestMissProbesFromRuns(t *testing.T) {
	rng := rand.New(rand.NewPCG(5, 6))
	occ := randOcc(rng, 500, 0.7, true)
	r, err := Brute(occ, Bounds(500, 2))
	if err != nil {
		t.Fatal(err)
	}
	var tot int
	for h := range occ {
		n := 1
		for i := h; occ[i]; i = (i + 1) % len(occ) {
			n++
		}
		tot += n
	}
	if got, want := r.MissProbesFromRuns(), float64(tot)/500; math.Abs(got-want) > 1e-12 {
		t.Fatalf("MissProbesFromRuns %v, direct %v", got, want)
	}
}
