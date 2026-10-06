// Package runlen measures the occupied-run structure of a hash.k2d cell array in one streaming
// pass (G0c, issue #7): occupied count, run-length histogram, longest run (joined across the
// wrap from the last slot to the first), and the overlap tail a shard ending at each of a set of
// slot boundaries would need.
//
// A cell is occupied iff its value (the low value_bits bits) is nonzero, the same test upstream's
// probe loop uses to stop (chash.Probe). Only 32-bit cells are supported here.
//
// The pass is split so the expensive part runs in parallel: ScanChunk summarises one contiguous
// range of cells independently of every other range, and Accumulator.Add merges the summaries in
// slot order. Brute is a separate, deliberately naive implementation over a whole occupancy
// vector, used to cross-check the two.
//
// # Overlap tail
//
// For a boundary b (0 < b <= C, where b = C is the wrap boundary, cell C-1 followed by cell 0), a
// shard ending at b owns slots up to b-1. A linear probe whose home slot is in that shard reads
// cells until it finds the key or an empty cell. It crosses b only if every cell from its home to
// b-1 is occupied, so only probes in the occupied run containing b-1 can cross, and the one that
// reads furthest is a miss, which reads every occupied cell from b onward (RunPast of them) and
// then the empty cell that stops it. So the cells past b the shard must also hold are
//
//	Tail(b) = 0              if cell b-1 is empty
//	Tail(b) = RunPast(b) + 1 otherwise (RunPast occupied cells plus the terminating empty cell)
//
// with slots taken modulo C. A shard set of N needs max over its boundaries of Tail(b).
package runlen

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math/bits"
	"sort"
)

// ExactMax is the largest run length kept in the dense histogram; longer runs go to a map. The
// histogram is exact for every length either way.
const ExactMax = 4096

// Hist is an exact run-length histogram: Dense[L] for L <= ExactMax, Sparse[L] above.
type Hist struct {
	Dense  [ExactMax + 1]uint64
	Sparse map[uint64]uint64
}

func (h *Hist) add(l, n uint64) {
	if l <= ExactMax {
		h.Dense[l] += n
		return
	}
	if h.Sparse == nil {
		h.Sparse = map[uint64]uint64{}
	}
	h.Sparse[l] += n
}

func (h *Hist) merge(o *Hist) {
	for l, n := range o.Dense {
		h.Dense[l] += n
	}
	for l, n := range o.Sparse {
		h.add(l, n)
	}
}

// Lengths returns every (length, count) with count > 0, by length.
func (h *Hist) Lengths() [][2]uint64 {
	var out [][2]uint64
	for l, n := range h.Dense {
		if n > 0 {
			out = append(out, [2]uint64{uint64(l), n})
		}
	}
	var sp [][2]uint64
	for l, n := range h.Sparse {
		if n > 0 {
			sp = append(sp, [2]uint64{l, n})
		}
	}
	sort.Slice(sp, func(i, j int) bool { return sp[i][0] < sp[j][0] })
	return append(out, sp...)
}

// BoundaryObs is what one chunk saw around a boundary b whose cell b-1 lies in the chunk.
type BoundaryObs struct {
	Index    int    // index into the boundary list
	B        uint64 // the boundary (b-1 is the last slot of the shard ending there)
	Occupied bool   // cell b-1 is occupied
	Back     uint64 // occupied cells ending at b-1, within the chunk
	Fwd      uint64 // occupied cells starting at b, within the chunk
	FwdToEnd bool   // the occupied stretch from b reaches the chunk's end
}

// Chunk summarises cells [Start, End).
type Chunk struct {
	Start, End   uint64
	Occupied     uint64
	Prefix       uint64 // occupied cells from Start
	Suffix       uint64 // occupied cells ending at End-1
	Internal     Hist   // runs with an empty cell on both sides inside the chunk
	InternalRuns uint64
	Longest      uint64 // longest internal run
	LongestStart uint64
	Bounds       []BoundaryObs
}

// Full reports whether every cell of the chunk is occupied.
func (c *Chunk) Full() bool { return c.Prefix == c.End-c.Start }

// ScanChunk32 summarises the 32-bit little-endian cells in b, which are slots start,
// start+1, …. valueMask is (1 << value_bits) - 1. bounds is the sorted boundary list (values in
// (0, C]); only those with b-1 in this chunk are observed. c's slices and map are reused.
func ScanChunk32(b []byte, start uint64, valueMask uint32, bounds []uint64, c *Chunk) {
	if len(b)%4 != 0 {
		panic("runlen: chunk is not a whole number of 32-bit cells")
	}
	n := uint64(len(b) / 4)
	*c = Chunk{Start: start, End: start + n, Bounds: c.Bounds[:0], Internal: Hist{Sparse: c.Internal.Sparse}}
	clear(c.Internal.Sparse)
	var occ uint64
	// run is the length of the occupied stretch ending at the current cell; seenEmpty says an
	// empty cell has been seen in this chunk (so the stretch is not the prefix).
	var run uint64
	seenEmpty := false
	for i := uint64(0); i < n; i++ {
		if binary.LittleEndian.Uint32(b[4*i:])&valueMask != 0 {
			run++
			continue
		}
		if !seenEmpty {
			c.Prefix = run
			seenEmpty = true
		} else if run > 0 {
			c.Internal.add(run, 1)
			c.InternalRuns++
			if run > c.Longest {
				c.Longest, c.LongestStart = run, start+i-run
			}
		}
		occ += run
		run = 0
	}
	occ += run
	c.Occupied = occ
	if !seenEmpty {
		c.Prefix = n
	}
	c.Suffix = run
	if !seenEmpty {
		c.Suffix = n
	}
	// Boundaries with b-1 in [start, start+n).
	i := sort.Search(len(bounds), func(i int) bool { return bounds[i] > start })
	for ; i < len(bounds) && bounds[i] <= start+n; i++ {
		bd := bounds[i]
		o := BoundaryObs{Index: i, B: bd}
		last := bd - 1 - start // local index of b-1
		if binary.LittleEndian.Uint32(b[4*last:])&valueMask != 0 {
			o.Occupied = true
			for j := last; ; j-- {
				if binary.LittleEndian.Uint32(b[4*j:])&valueMask == 0 {
					break
				}
				o.Back++
				if j == 0 {
					break
				}
			}
			j := last + 1
			for ; j < n && binary.LittleEndian.Uint32(b[4*j:])&valueMask != 0; j++ {
				o.Fwd++
			}
			o.FwdToEnd = j == n
		}
		c.Bounds = append(c.Bounds, o)
	}
}

// Boundary is the measured overlap at one boundary.
type Boundary struct {
	B        uint64 `json:"boundary"` // slot b (C for the wrap boundary); the shard ends at b-1
	Occupied bool   `json:"last_slot_occupied"`
	RunPast  uint64 `json:"run_past"`  // occupied cells from b onward (mod C)
	Tail     uint64 `json:"tail"`      // cells past b a probe can read: RunPast+1, or 0 if b-1 is empty
	RunStart uint64 `json:"run_start"` // start slot of the run containing b-1 (if occupied)
	RunLen   uint64 `json:"run_len"`   // its length
}

// Result is the whole-table measurement.
type Result struct {
	Capacity     uint64
	Cells        uint64
	Occupied     uint64
	Runs         uint64
	Hist         Hist
	Longest      uint64
	LongestStart uint64
	Wrapped      bool // the run crossing the wrap boundary was joined
	Boundaries   []Boundary
}

type pending struct {
	idx    int
	start  uint64 // run start (provisional for the head run until the wrap join)
	inHead bool
}

// Accumulator merges chunk summaries in slot order.
type Accumulator struct {
	C      uint64
	bounds []uint64
	next   uint64
	res    Result

	inHead    bool   // no empty cell seen yet
	headLen   uint64 // length of the run starting at slot 0 (once closed)
	openStart uint64 // start of the open run at `next`
	openLen   uint64
	pend      []pending // boundaries whose run has not closed yet
	headBds   []int     // boundaries whose run is the head run (start fixed at the wrap join)
}

// Bounds returns the boundary list for shard counts 2, 4, …, maxN (a power of two): shard i of N
// is [floor(i*C/N), floor((i+1)*C/N)), so its upper boundary is floor((i+1)*C/N), and the
// boundaries of N are a subset of those of 2N. The wrap boundary is C (slot C-1, then slot 0).
// Boundary j/maxN of the result is floor(j*C/maxN) for j = 1..maxN.
func Bounds(capacity uint64, maxN int) []uint64 {
	out := make([]uint64, maxN)
	for j := 1; j <= maxN; j++ {
		hi, lo := bits.Mul64(uint64(j), capacity)
		q, _ := bits.Div64(hi, lo, uint64(maxN))
		out[j-1] = q
	}
	return out
}

// NewAccumulator starts a pass over a table of capacity slots with the given sorted boundaries
// (values in (0, C]).
func NewAccumulator(capacity uint64, bounds []uint64) (*Accumulator, error) {
	if capacity == 0 {
		return nil, errors.New("runlen: capacity 0")
	}
	for i, b := range bounds {
		if b == 0 || b > capacity || (i > 0 && b <= bounds[i-1]) {
			return nil, fmt.Errorf("runlen: boundaries must be sorted, distinct and in (0, C]: %v", bounds)
		}
	}
	a := &Accumulator{C: capacity, bounds: bounds, inHead: true}
	a.res.Capacity = capacity
	a.res.Boundaries = make([]Boundary, len(bounds))
	for i, b := range bounds {
		a.res.Boundaries[i].B = b
	}
	return a, nil
}

// Next is the first slot not yet merged.
func (a *Accumulator) Next() uint64 { return a.next }

// Occupied is the occupied count merged so far.
func (a *Accumulator) Occupied() uint64 { return a.res.Occupied }

func (a *Accumulator) addRun(start, l uint64) {
	a.res.Hist.add(l, 1)
	a.res.Runs++
	if l > a.res.Longest {
		a.res.Longest, a.res.LongestStart = l, start
	}
}

// Add merges the next chunk. Chunks must arrive in slot order and cover [0, C) exactly.
func (a *Accumulator) Add(c *Chunk) error {
	if c.Start != a.next || c.End < c.Start || c.End > a.C {
		return fmt.Errorf("runlen: chunk [%d,%d) out of order (next %d, C %d)", c.Start, c.End, a.next, a.C)
	}
	a.next = c.End
	a.res.Cells += c.End - c.Start
	a.res.Occupied += c.Occupied
	if c.End == c.Start {
		return nil
	}
	// The run open at c.Start: where it started, and whether it is the head run.
	runAtStart := c.Start
	if a.openLen > 0 {
		runAtStart = a.openStart
	}
	headAtStart := a.inHead
	if a.inHead {
		runAtStart = 0
	}
	// Boundaries whose occupied stretch reaches the chunk's end wait for the run to close in a
	// later chunk; they join a.pend only after this chunk's prefix has closed the earlier run.
	var later []pending
	for _, o := range c.Bounds {
		r := &a.res.Boundaries[o.Index]
		r.Occupied = o.Occupied
		if !o.Occupied {
			continue
		}
		start := o.B - o.Back
		inHead := false
		if start == c.Start {
			start, inHead = runAtStart, headAtStart
		}
		r.RunStart = start
		if !o.FwdToEnd {
			end := o.B + o.Fwd
			r.RunPast, r.Tail, r.RunLen = o.Fwd, o.Fwd+1, end-start
			if inHead {
				a.headBds = append(a.headBds, o.Index)
			}
			continue
		}
		later = append(later, pending{idx: o.Index, start: start, inHead: inHead})
	}
	if c.Full() {
		if !a.inHead {
			if a.openLen == 0 {
				a.openStart = c.Start
			}
			a.openLen += c.End - c.Start
		}
		a.pend = append(a.pend, later...)
		return nil
	}
	// The prefix closes the open run (or the head run) at e = c.Start + c.Prefix.
	e := c.Start + c.Prefix
	if a.inHead {
		a.headLen = e
		a.inHead = false
		a.closePending(e, true)
	} else {
		if l := a.openLen + c.Prefix; l > 0 {
			s := c.Start
			if a.openLen > 0 {
				s = a.openStart
			}
			a.addRun(s, l)
		}
		a.closePending(e, false)
	}
	a.res.Hist.merge(&c.Internal)
	a.res.Runs += c.InternalRuns
	if c.Longest > a.res.Longest {
		a.res.Longest, a.res.LongestStart = c.Longest, c.LongestStart
	}
	a.openLen = c.Suffix
	a.openStart = c.End - c.Suffix
	a.pend = append(a.pend, later...)
	return nil
}

// closePending resolves the boundaries whose run ends with the empty cell at e (e may exceed C
// at the wrap).
func (a *Accumulator) closePending(e uint64, head bool) {
	for _, p := range a.pend {
		r := &a.res.Boundaries[p.idx]
		r.RunPast = e - r.B
		r.Tail = r.RunPast + 1
		r.RunLen = e - p.start
		if head || p.inHead {
			a.headBds = append(a.headBds, p.idx)
		}
	}
	a.pend = a.pend[:0]
}

// Finish closes the pass: joins the run that wraps from slot C-1 to slot 0 and returns the
// result.
func (a *Accumulator) Finish() (*Result, error) {
	if a.next != a.C {
		return nil, fmt.Errorf("runlen: pass ended at slot %d of %d", a.next, a.C)
	}
	if a.inHead {
		return nil, errors.New("runlen: every cell is occupied; runs are undefined")
	}
	if a.openLen > 0 {
		// The open run continues at slot 0 into the head run (if any): one run.
		l := a.openLen + a.headLen
		a.addRun(a.openStart, l)
		a.res.Wrapped = a.headLen > 0
		a.closePending(a.C+a.headLen, false)
		if a.headLen > 0 {
			for _, i := range a.headBds {
				r := &a.res.Boundaries[i]
				r.RunStart = a.openStart
				r.RunLen += a.openLen
			}
		}
	} else if a.headLen > 0 {
		a.addRun(0, a.headLen)
	}
	r := a.res
	return &r, nil
}

// TailForN is the tail a set of N equal shards (N a power of two dividing len(bounds)) needs:
// the max over its N boundaries, which are every (len(bounds)/N)-th boundary.
func (r *Result) TailForN(n int) (tail uint64, at uint64, err error) {
	m := len(r.Boundaries)
	if n <= 0 || m%n != 0 {
		return 0, 0, fmt.Errorf("runlen: N=%d does not divide %d boundaries", n, m)
	}
	step := m / n
	at = r.Boundaries[step-1].B
	for j := step - 1; j < m; j += step {
		if b := r.Boundaries[j]; b.Tail > tail {
			tail, at = b.Tail, b.B
		}
	}
	return tail, at, nil
}
