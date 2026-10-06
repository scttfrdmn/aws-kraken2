package chash

import (
	"math/rand/v2"
	"testing"
)

// GetBatch returns exactly Get's values: 32- and 40-bit cells, linear and double probing,
// hits, misses and a full table (the wrap case).
func TestGetBatchMatchesGet(t *testing.T) {
	for _, c := range []struct {
		capacity, kb, vb uint64
		cellBytes        int
		mode             Mode
		n                int
	}{
		{10007, 16, 16, 4, Linear, 7000},
		{10007, 16, 16, 4, Linear, 10007}, // full
		{1 << 12, 20, 12, 4, Linear, 3000},
		{10007, 16, 16, 4, Double, 7000},
		{10007, 22, 18, 5, Linear, 7000},
	} {
		img, kv := synth(t, c.capacity, c.kb, c.vb, c.cellBytes, c.mode, c.n, 3)
		tab, err := FromBytes(img, c.mode)
		if err != nil {
			t.Fatal(err)
		}
		r := rand.New(rand.NewPCG(1, 1))
		keys := make([]uint64, 0, 3*len(kv))
		for k := range kv {
			keys = append(keys, k, r.Uint64())
		}
		var s BatchScratch
		var vals []uint32
		for off := 0; off < len(keys); off += 97 {
			batch := keys[off:min(off+97, len(keys))]
			vals = tab.GetBatch(batch, vals[:0], &s)
			for i, k := range batch {
				if want, _ := tab.Get(k); vals[i] != want {
					t.Fatalf("%+v: key %#x: GetBatch %d, Get %d", c, k, vals[i], want)
				}
			}
		}
	}
}

func BenchmarkGetBatchSynth(b *testing.B) {
	tab, hits, misses := benchTable(b, Linear)
	keys := make([]uint64, 0, 1<<20)
	for i := range 1 << 19 {
		keys = append(keys, hits[i], misses[i])
	}
	b.ReportAllocs()
	var s BatchScratch
	vals := make([]uint32, 0, 128)
	for i := 0; b.Loop(); i++ {
		o := (i * 128) & (len(keys) - 1)
		vals = tab.GetBatch(keys[o:o+128], vals[:0], &s)
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*128), "ns/key")
}

func BenchmarkGetLoopSynth(b *testing.B) {
	tab, hits, misses := benchTable(b, Linear)
	keys := make([]uint64, 0, 1<<20)
	for i := range 1 << 19 {
		keys = append(keys, hits[i], misses[i])
	}
	b.ReportAllocs()
	vals := make([]uint32, 0, 128)
	for i := 0; b.Loop(); i++ {
		o := (i * 128) & (len(keys) - 1)
		vals = vals[:0]
		for _, k := range keys[o : o+128] {
			v, _ := tab.Get(k)
			vals = append(vals, v)
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(b.N*128), "ns/key")
}
