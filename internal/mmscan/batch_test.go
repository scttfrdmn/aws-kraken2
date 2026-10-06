package mmscan_test

import (
	"math/rand/v2"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/mmscan"
)

// nextStream is the reference: Next's output, with ambiguous positions as mmscan.Ambiguous.
func nextStream(t *testing.T, s *mmscan.Scanner, seq []byte) []uint64 {
	t.Helper()
	var out []uint64
	s.Load(seq)
	for {
		m, amb, ok := s.Next()
		if !ok {
			return out
		}
		if amb {
			m = mmscan.Ambiguous
		} else if m == mmscan.Ambiguous {
			t.Fatalf("unambiguous minimizer equal to the Ambiguous mark")
		}
		out = append(out, m)
	}
}

// AppendMinimizers reports exactly what Next does, over DNA and protein scanners, both
// revcom versions, k == l, spaced seeds, ambiguous runs, lower case and short sequences.
func TestAppendMinimizersMatchesNext(t *testing.T) {
	type cfg struct {
		k, l     int
		ssm      uint64
		dna      bool
		revcom   int
		alphabet string
	}
	dnaAlpha := "ACGTACGTACGTACGTacgtNRY."
	protAlpha := "ACDEFGHIKLMNPQRSTVWY*UOBZJXacdefgh"
	cfgs := []cfg{
		{35, 31, viralSSM, true, 1, dnaAlpha},
		{35, 31, viralSSM, true, 0, dnaAlpha},
		{35, 31, 0, true, 1, dnaAlpha},
		{31, 31, 0, true, 1, dnaAlpha},
		{25, 21, 0, true, 1, dnaAlpha},
		{8, 3, 0, true, 0, dnaAlpha},
		{5, 5, 0, true, 0, dnaAlpha},
		{15, 12, 0, false, 1, protAlpha},
		{12, 12, 0, false, 1, protAlpha},
	}
	r := rand.New(rand.NewPCG(39, 1))
	for _, c := range cfgs {
		s, err := mmscan.New(c.k, c.l, c.ssm, mmscan.DefaultToggleMask, c.dna, c.revcom)
		if err != nil {
			t.Fatal(err)
		}
		var buf []uint64
		for i := 0; i < 3000; i++ {
			n := r.IntN(160)
			seq := make([]byte, n)
			// Mostly clean, sometimes ambiguity-heavy.
			rate := []int{0, 200, 20, 3}[r.IntN(4)]
			for j := range seq {
				seq[j] = c.alphabet[r.IntN(16)]
				if rate > 0 && r.IntN(rate) == 0 {
					seq[j] = c.alphabet[r.IntN(len(c.alphabet))]
				}
			}
			want := nextStream(t, s, seq)
			buf = s.AppendMinimizers(seq, buf[:0])
			if len(buf) != len(want) {
				t.Fatalf("k=%d l=%d dna=%v rc=%d %q: %d minimizers, Next %d", c.k, c.l, c.dna, c.revcom, seq, len(buf), len(want))
			}
			for j := range want {
				if buf[j] != want[j] {
					t.Fatalf("k=%d l=%d dna=%v rc=%d %q: #%d = %#x, Next %#x", c.k, c.l, c.dna, c.revcom, seq, j, buf[j], want[j])
				}
			}
			if _, _, ok := s.Next(); ok {
				t.Fatal("scanner not exhausted after AppendMinimizers")
			}
		}
	}
}

func TestAppendMinimizersZeroAllocs(t *testing.T) {
	s, _ := mmscan.New(35, 31, viralSSM, mmscan.DefaultToggleMask, true, 1)
	read := randomRead(rand.New(rand.NewPCG(1, 2)), 150)
	buf := make([]uint64, 0, 256)
	if a := testing.AllocsPerRun(100, func() { buf = s.AppendMinimizers(read, buf[:0]) }); a != 0 {
		t.Fatalf("%v allocs per call", a)
	}
}

// BenchmarkAppendMinimizers100bp is BenchmarkScan100bp through AppendMinimizers.
func BenchmarkAppendMinimizers100bp(b *testing.B) {
	r := rand.New(rand.NewPCG(7, 8))
	reads := make([][]byte, 1024)
	for i := range reads {
		reads[i] = randomRead(r, 100)
	}
	s, _ := mmscan.New(35, 31, viralSSM, mmscan.DefaultToggleMask, true, 1)
	b.ReportAllocs()
	b.SetBytes(100)
	buf := make([]uint64, 0, 128)
	var n int64
	for i := 0; b.Loop(); i++ {
		buf = s.AppendMinimizers(reads[i&1023], buf[:0])
		n += int64(len(buf))
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(n), "ns/minimizer")
}
