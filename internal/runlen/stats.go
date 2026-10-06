package runlen

import (
	"fmt"
	"math"
	"math/big"
)

// Quantile is the smallest run length L such that at least q of all runs have length <= L.
func (r *Result) Quantile(q float64) uint64 {
	if r.Runs == 0 {
		return 0
	}
	need := uint64(math.Ceil(q * float64(r.Runs)))
	if need == 0 {
		need = 1
	}
	var cum uint64
	for _, ln := range r.Hist.Lengths() {
		cum += ln[1]
		if cum >= need {
			return ln[0]
		}
	}
	return r.Longest
}

// SumSquares is Σ L² over all runs, exactly.
func (r *Result) SumSquares() *big.Int {
	s := new(big.Int)
	for _, ln := range r.Hist.Lengths() {
		t := new(big.Int).SetUint64(ln[0])
		t.Mul(t, t)
		t.Mul(t, new(big.Int).SetUint64(ln[1]))
		s.Add(s, t)
	}
	return s
}

// MissProbesFromRuns is the mean number of cells a linear-probe miss examines, averaged over a
// uniformly random home slot, computed exactly from the measured runs: a home at an empty cell
// examines 1 cell; a home m cells from the end of a run examines m occupied cells and the empty
// one after it, so a run of length L contributes Σ_{m=1..L} (m+1) = L(L+1)/2 + L. It ignores
// compacted-key false matches, which can only shorten a miss.
func (r *Result) MissProbesFromRuns() float64 {
	// Σ (L² + 3L)/2 = (ΣL² + 3·occupied)/2
	s := r.SumSquares()
	s.Add(s, new(big.Int).Mul(big.NewInt(3), new(big.Int).SetUint64(r.Occupied)))
	tot := new(big.Float).SetInt(s)
	tot.Quo(tot, big.NewFloat(2))
	tot.Add(tot, new(big.Float).SetUint64(r.Cells-r.Occupied))
	tot.Quo(tot, new(big.Float).SetUint64(r.Cells))
	f, _ := tot.Float64()
	return f
}

// Bucket is one row of the published histogram: exact lengths 1..64, then log2 buckets
// (2^(k-1), 2^k] for k >= 7.
type Bucket struct {
	Lo, Hi   uint64
	Observed uint64
	Expected float64 // linear-probing theory (TheoryRuns) at the measured load factor
}

// BorelLogPMF is log P(n) of the Borel distribution with parameter a: P(n) = e^{-an}(an)^{n-1}/n!.
func BorelLogPMF(a float64, n uint64) float64 {
	x := float64(n)
	lg, _ := math.Lgamma(x + 1)
	return -a*x + (x-1)*math.Log(a*x) - lg
}

// TheoryRuns is the expected number of runs of length exactly L >= 1 in a linear-probing table
// of `cells` slots with `occupied` keys, in the Poisson (random-hashing, large-table) model:
// (cells - occupied) · Borel_α(L+1), α = occupied/cells.
//
// Derivation: let X_i ~ Poisson(α) be the number of keys whose home is slot i. Scanning from an
// empty slot, the next block has length L iff the walk S_t = Σ_{i<=t} (X_i - 1) first reaches -1
// at t = L+1. By the hitting-time theorem for a walk with steps >= -1, P(T = n) = P(S_n = -1)/n =
// e^{-αn}(αn)^{n-1}/n!, the Borel distribution (the M/D/1 busy period). Every empty slot starts
// one such block (L = 0 is the next slot also being empty), so the expected number of runs of
// length L is (#empty)·P(T = L+1). It sums to (#empty)(1 - e^{-α}) runs and α·cells occupied
// cells. See Flajolet, Poblete & Viola, "On the analysis of linear probing hashing",
// Algorithmica 22(4):490–515 (1998), and Knuth, TAOCP vol. 3, §6.4.
func TheoryRuns(cells, occupied uint64, l uint64) float64 {
	a := float64(occupied) / float64(cells)
	return float64(cells-occupied) * math.Exp(BorelLogPMF(a, l+1))
}

// TheoryRunsAtLeast is Σ_{L' >= l} TheoryRuns, summed until the terms are negligible.
func TheoryRunsAtLeast(cells, occupied, l uint64) float64 {
	var s float64
	for k := l; ; k++ {
		t := TheoryRuns(cells, occupied, k)
		s += t
		if k > l+64 && t < s*1e-17 {
			return s
		}
		if k > l+1<<24 {
			return s
		}
	}
}

// Buckets returns the published histogram with theory alongside: 1..64 exactly, then log2
// buckets up to the one holding the longest run.
func (r *Result) Buckets() []Bucket {
	var out []Bucket
	for l := uint64(1); l <= 64; l++ {
		out = append(out, Bucket{Lo: l, Hi: l})
	}
	for hi := uint64(128); ; hi *= 2 {
		out = append(out, Bucket{Lo: hi/2 + 1, Hi: hi})
		if hi >= r.Longest {
			break
		}
	}
	for _, ln := range r.Hist.Lengths() {
		for i := range out {
			if ln[0] >= out[i].Lo && ln[0] <= out[i].Hi {
				out[i].Observed += ln[1]
				break
			}
		}
	}
	for i := range out {
		b := &out[i]
		if b.Lo == b.Hi {
			b.Expected = TheoryRuns(r.Cells, r.Occupied, b.Lo)
			continue
		}
		for l := b.Lo; l <= b.Hi; l++ {
			t := TheoryRuns(r.Cells, r.Occupied, l)
			b.Expected += t
			if t < 1e-300 {
				break
			}
		}
	}
	return out
}

// Check compares two results field by field (for the brute-force cross-check). Longest-run ties
// may legitimately report different starts, so only the length is compared there.
func Check(a, b *Result) error {
	if a.Capacity != b.Capacity || a.Cells != b.Cells || a.Occupied != b.Occupied || a.Runs != b.Runs ||
		a.Longest != b.Longest || a.Wrapped != b.Wrapped {
		return fmt.Errorf("runlen: totals differ: cap %d/%d cells %d/%d occ %d/%d runs %d/%d longest %d/%d wrapped %v/%v",
			a.Capacity, b.Capacity, a.Cells, b.Cells, a.Occupied, b.Occupied, a.Runs, b.Runs,
			a.Longest, b.Longest, a.Wrapped, b.Wrapped)
	}
	al, bl := a.Hist.Lengths(), b.Hist.Lengths()
	if len(al) != len(bl) {
		return fmt.Errorf("runlen: histograms differ in support: %d vs %d lengths", len(al), len(bl))
	}
	for i := range al {
		if al[i] != bl[i] {
			return fmt.Errorf("runlen: histogram differs at row %d: %v vs %v", i, al[i], bl[i])
		}
	}
	if len(a.Boundaries) != len(b.Boundaries) {
		return fmt.Errorf("runlen: %d vs %d boundaries", len(a.Boundaries), len(b.Boundaries))
	}
	for i := range a.Boundaries {
		if a.Boundaries[i] != b.Boundaries[i] {
			return fmt.Errorf("runlen: boundary %d differs: %+v vs %+v", i, a.Boundaries[i], b.Boundaries[i])
		}
	}
	return nil
}
