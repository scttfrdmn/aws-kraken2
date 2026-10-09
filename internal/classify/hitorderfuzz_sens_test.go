package classify

import "os"

// Sensitivity runs of the hitorderfuzz (docs/hitorderfuzz.md, "Sensitivity"): with
// HITORDERFUZZ_SENSITIVITY set, the fuzz tests a known-wrong order instead of newHitCounts, and
// scripts/hitorderfuzz.sh records the run as a sensitivity run that must FAIL.
//   - reversed:  newHitCounts with Range's order reversed
//   - first-hit: entries in first-insertion order (the pre-fix behaviour)
func init() {
	switch os.Getenv("HITORDERFUZZ_SENSITIVITY") {
	case "reversed":
		fuzzNewHitCounts = func() HitCounts { return &reversedRange{newHitCounts()} }
	case "first-hit":
		fuzzNewHitCounts = func() HitCounts { return &firstInsertion{} }
	}
}

type reversedRange struct{ HitCounts }

func (r *reversedRange) Range(f func(taxon, count uint64) bool) {
	var ts, cs []uint64
	r.HitCounts.Range(func(t, c uint64) bool { ts = append(ts, t); cs = append(cs, c); return true })
	for i := len(ts) - 1; i >= 0; i-- {
		if !f(ts[i], cs[i]) {
			return
		}
	}
}

type firstInsertion struct {
	ts, cs []uint64
}

func (m *firstInsertion) Clear() { m.ts, m.cs = m.ts[:0], m.cs[:0] }
func (m *firstInsertion) find(t uint64) int {
	for i, x := range m.ts {
		if x == t {
			return i
		}
	}
	return -1
}
func (m *firstInsertion) Increment(t uint64) {
	if i := m.find(t); i >= 0 {
		m.cs[i]++
		return
	}
	m.ts, m.cs = append(m.ts, t), append(m.cs, 1)
}
func (m *firstInsertion) Lookup(t uint64) uint64 {
	if i := m.find(t); i >= 0 {
		return m.cs[i]
	}
	m.ts, m.cs = append(m.ts, t), append(m.cs, 0)
	return 0
}
func (m *firstInsertion) Range(f func(taxon, count uint64) bool) {
	for i := range m.ts {
		if !f(m.ts[i], m.cs[i]) {
			return
		}
	}
}
