package engine

import (
	"context"
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

// inverse returns a's multiplicative inverse mod 2^64 (a odd), by Newton's iteration.
func inverse(a uint64) uint64 {
	x := a
	for range 6 {
		x *= 2 - a*x
	}
	return x
}

// unmix inverts chash.MurmurHash3 (fmix64 is a bijection): the key whose hashed key is hc.
func unmix(hc uint64) uint64 {
	k := hc
	k ^= k >> 33
	k *= inverse(0xc4ceb9fe1a85ec53)
	k ^= k >> 33
	k *= inverse(0xff51afd7ed558ccd)
	k ^= k >> 33
	return k
}

func TestUnmix(t *testing.T) {
	r := rand.New(rand.NewPCG(3, 4))
	for range 1000 {
		hc := r.Uint64()
		if got := chash.MurmurHash3(unmix(hc)); got != hc {
			t.Fatalf("MurmurHash3(unmix(%x)) = %x", hc, got)
		}
	}
}

// boundaryKeys returns lookups aimed at the run that crosses the shard boundary b (slot b−1
// and on, slots mod C) of tab: from every home slot in that run, plus the two slots after b,
// a miss, and a hit on each stored cell from the home to the run's end (as upstream's Get
// would find it: the first cell holding that compacted key). Their probes walk every cell a
// shard ending at b must hold.
func boundaryKeys(tab *chash.Table, b uint64, r *rand.Rand) []uint64 {
	l := tab.Layout
	c := l.Capacity
	cell := func(i uint64) (uint64, uint32) {
		raw, _ := tab.Cell(i % c)
		return l.Decode(raw)
	}
	occ := func(i uint64) bool { _, v := cell(i); return v != 0 }
	shift := 64 - l.KeyBits
	withSlot := func(ck, s uint64) uint64 { // hc with compacted key ck and home slot s
		base := ck << shift
		return base + (s%c+c-base%c)%c
	}
	// Slots are handled as b−1+d (mod C) for d from −back to the run's end.
	start := b + c - 1 // slot b−1, kept positive
	back := uint64(0)
	for back < 1000 && occ(start-back) && occ(start-back-1) {
		back++
	}
	end := uint64(0) // cells from b−1 to the first empty one
	for end < 1000 && occ(start+end) {
		end++
	}
	var keys []uint64
	for d := uint64(0); d <= back+2; d++ {
		s := start - back + d // homes: the run's start .. b−1, then b, b+1
		keys = append(keys, unmix(withSlot(r.Uint64()>>shift, s)))
		for j := s; j <= start+end && j < s+400; j++ {
			if k, v := cell(j); v != 0 {
				keys = append(keys, unmix(withSlot(k, s)))
			}
		}
	}
	return keys
}

// TestRealDBBoundaries: on the pinned databases, lookups aimed at every shard boundary's run
// (including the wrap from slot C−1 to slot 0) give upstream Get's values through the engine
// at several N, both with the tightest tail G0c's definition allows and with the default.
// Real reads reach a tail only rarely (make oracle-engine, checks.tsv), so this is the
// real-table evidence that the tails are long enough.
func TestRealDBBoundaries(t *testing.T) {
	if testing.Short() {
		t.Skip("loads whole databases")
	}
	for _, name := range []string{"k2_viral_20260626", "k2_standard_08_GB_20260626"} {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(oracletest.DB(t, name), "hash.k2d")
			tab, err := chash.Load(path, chash.Options{})
			if err != nil {
				t.Fatal(err)
			}
			defer tab.Close()
			if tab.Layout.CellBytes != 4 {
				t.Fatalf("%d-byte cells", tab.Layout.CellBytes)
			}
			cells := func(i uint64) uint64 { raw, _ := tab.Cell(i); return raw }
			f, err := os.Open(path)
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			fill := RangeFiller{Src: &rangeread.FileSource{F: f}, Workers: 8}
			r := rand.New(rand.NewPCG(5, 6))
			var crossed int64
			for _, tc := range []struct {
				n     int
				tight bool
			}{{2, true}, {3, true}, {4, true}, {5, true}, {8, true}, {3, false}, {16, true}} {
				l := tab.Layout
				tail := uint64(DefaultTail)
				if tc.tight {
					tail = realTail(l, cells, tc.n)
				}
				var shards []*Shard
				for i := 0; i < tc.n; i++ {
					s, err := LoadShard(context.Background(), l, i, tc.n, tail, fill)
					if err != nil {
						t.Fatalf("N=%d tail %d: %v", tc.n, tail, err)
					}
					shards = append(shards, s)
				}
				var keys []uint64
				for i := 0; i < tc.n; i++ {
					_, b := Cut(i, tc.n, l.Capacity)
					keys = append(keys, boundaryKeys(tab, b, r)...)
				}
				rt := localRouter(shards)
				var sc RouteScratch
				got, err := rt.Lookup(keys, nil, &sc)
				if err != nil {
					t.Fatal(err)
				}
				for i, k := range keys {
					if want, _ := tab.Get(k); got[i] != want {
						t.Fatalf("N=%d tail %d: key %x: engine %d, table %d", tc.n, tail, k, got[i], want)
					}
				}
				var tp, wp int64
				for _, s := range shards {
					tp += s.TailProbes.Load()
					wp += s.WrapProbes.Load()
					s.Close()
				}
				t.Logf("N=%d tail %d: %d lookups, %d ended in a tail, %d of them wrapped", tc.n, tail, len(keys), tp, wp)
				if tail > 0 && tp == 0 {
					t.Errorf("N=%d: tail %d but no lookup reached it", tc.n, tail)
				}
				crossed += tp
			}
			if crossed == 0 {
				t.Error("no lookup crossed a shard boundary")
			}
		})
	}
}

// realTail is neededTail over a loaded table.
func realTail(l chash.Layout, raw func(uint64) uint64, n int) uint64 {
	c := l.Capacity
	occ := func(i uint64) bool { _, v := l.Decode(raw(i % c)); return v != 0 }
	var worst uint64
	for i := 0; i < n; i++ {
		lo, b := Cut(i, n, c)
		if b == lo || !occ(b-1) {
			continue
		}
		var run uint64
		for run < c && occ(b+run) {
			run++
		}
		worst = max(worst, run+1)
	}
	return worst
}
