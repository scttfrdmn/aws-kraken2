package classify

import (
	"slices"
	"testing"
)

func hcOrder(m *hitCounts) []uint64 {
	var out []uint64
	m.Range(func(t, _ uint64) bool { out = append(out, t); return true })
	return out
}

func hcInsert(m *hitCounts, keys ...uint64) {
	for _, k := range keys {
		m.Lookup(k)
	}
}

func hcSeq(lo, hi uint64) []uint64 {
	var s []uint64
	for k := lo; k <= hi; k++ {
		s = append(s, k)
	}
	return s
}

func hcCheck(t *testing.T, name string, m *hitCounts, wantB uint64, want ...uint64) {
	t.Helper()
	if got := hcOrder(m); !slices.Equal(got, want) {
		t.Errorf("%s: order %v, want %v", name, got, want)
	}
	if m.nb != wantB {
		t.Errorf("%s: B = %d, want %d", name, m.nb, wantB)
	}
}

// TestHitCountsSpecExamples encodes the specification's worked examples 1-7 (#44).
func TestHitCountsSpecExamples(t *testing.T) {
	m := newHitCountsMap()
	hcInsert(m, 5, 18, 3)
	hcCheck(t, "Ex 1", m, 13, 3, 18, 5)

	m = newHitCountsMap()
	hcInsert(m, 1, 2, 14, 27, 15)
	hcCheck(t, "Ex 2", m, 13, 15, 2, 27, 14, 1)

	m = newHitCountsMap()
	hcInsert(m, hcSeq(0, 12)...)
	hcCheck(t, "Ex 3 before", m, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0)
	hcInsert(m, 13)
	hcCheck(t, "Ex 3", m, 29, append([]uint64{13}, hcSeq(0, 12)...)...)
	if m.thresh != 29 {
		t.Errorf("Ex 3: T = %d, want 29", m.thresh)
	}

	m = newHitCountsMap()
	hcInsert(m, 0, 29, 58, 1, 30, 2, 3, 4, 5, 6, 7, 8, 9)
	hcCheck(t, "Ex 4 before", m, 13, 9, 8, 7, 5, 2, 4, 30, 1, 6, 58, 3, 29, 0)
	hcInsert(m, 59)
	hcCheck(t, "Ex 4", m, 29, 3, 0, 29, 58, 6, 59, 1, 30, 4, 2, 5, 7, 8, 9)

	m = newHitCountsMap()
	hcInsert(m, hcSeq(0, 13)...)
	m.Clear()
	if m.nb != 29 || m.thresh != 29 {
		t.Errorf("Ex 5: after Clear B, T = %d, %d, want 29, 29", m.nb, m.thresh)
	}
	hcInsert(m, 1, 14, 30)
	hcCheck(t, "Ex 5", m, 29, 14, 30, 1)
	m = newHitCountsMap()
	hcInsert(m, 1, 14, 30)
	hcCheck(t, "Ex 5 fresh", m, 13, 30, 14, 1)

	m = newHitCountsMap()
	hcInsert(m, hcSeq(0, 12)...)
	if v := m.Lookup(100); v != 0 {
		t.Errorf("Ex 6: m[100] = %d", v)
	}
	m.Increment(5)
	m.Increment(42)
	hcCheck(t, "Ex 6", m, 29, append([]uint64{42, 100}, hcSeq(0, 12)...)...)
	if m.Lookup(5) != 1 || m.Lookup(42) != 1 || m.Lookup(100) != 0 {
		t.Errorf("Ex 6: counts 5=%d 42=%d 100=%d", m.Lookup(5), m.Lookup(42), m.Lookup(100))
	}

	m = newHitCountsMap()
	m.Clear()
	hcInsert(m, 20)
	hcCheck(t, "Ex 7", m, 13, 20)
}

// TestHitCountsGrowth checks the spec's derived bucket-count sequence (§3.4).
func TestHitCountsGrowth(t *testing.T) {
	steps := []struct{ at, b uint64 }{
		{1, 13}, {14, 29}, {30, 59}, {60, 127}, {128, 257}, {258, 541}, {542, 1109},
		{1110, 2357}, {2358, 5087}, {5088, 10273}, {10274, 20753}, {20754, 42043},
		{42044, 85229}, {85230, 172933},
	}
	m := newHitCountsMap()
	var k uint64
	for _, s := range steps {
		for k+1 < s.at {
			k++
			m.Increment(k * 7919)
		}
		before := m.nb
		k++
		m.Increment(k * 7919)
		if m.nb != s.b || m.thresh != s.b || before == s.b {
			t.Fatalf("insert %d: B %d -> %d, T %d, want B = T = %d", s.at, before, m.nb, m.thresh, s.b)
		}
	}
	if b, tt := hcNextBuckets(1<<63+1, 0); b != 18446744073709551557 || tt != ^uint64(0) {
		t.Errorf("cap: %d, %d", b, tt)
	}
}

// TestHitCountsNoAllocs checks the per-read hot path allocates nothing after warm-up.
func TestHitCountsNoAllocs(t *testing.T) {
	m := newHitCountsMap()
	read := func() {
		m.Clear()
		for i := uint64(0); i < 300; i++ {
			m.Increment(i * 2654435761 % 100003)
			m.Increment(i % 17)
		}
		m.Lookup(0)
		m.Range(func(_, _ uint64) bool { return true })
	}
	read()
	if a := testing.AllocsPerRun(100, read); a != 0 {
		t.Errorf("%v allocs per read", a)
	}
}
