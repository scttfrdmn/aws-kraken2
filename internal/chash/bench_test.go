package chash

import (
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"
)

// benchTable is a synthetic 2^24-cell table at 70% occupancy (Viral's is 162M cells at 70%).
func benchTable(b *testing.B, mode Mode) (*Table, []uint64, []uint64) {
	b.Helper()
	const capacity = 1<<24 + 3
	img, kv := synth(b, capacity, 17, 15, 4, mode, capacity*7/10, 11)
	tab, err := FromBytes(img, mode)
	if err != nil {
		b.Fatal(err)
	}
	hits := make([]uint64, 0, 1<<20)
	for k := range kv {
		if len(hits) == cap(hits) {
			break
		}
		hits = append(hits, k)
	}
	r := rand.New(rand.NewPCG(5, 5))
	misses := make([]uint64, 1<<20)
	for i := range misses {
		misses[i] = r.Uint64()
	}
	return tab, hits, misses
}

func benchGet(b *testing.B, tab *Table, keys []uint64) {
	b.ReportAllocs()
	b.ResetTimer()
	var sink uint32
	for i := 0; b.Loop(); i++ {
		v, _ := tab.Get(keys[i&(len(keys)-1)])
		sink += v
	}
	_ = sink
}

func BenchmarkGetSynthLinearHit(b *testing.B) {
	tab, hits, _ := benchTable(b, Linear)
	benchGet(b, tab, hits)
}

func BenchmarkGetSynthLinearMiss(b *testing.B) {
	tab, _, misses := benchTable(b, Linear)
	benchGet(b, tab, misses)
}

func BenchmarkGetSynthDoubleMiss(b *testing.B) {
	tab, _, misses := benchTable(b, Double)
	benchGet(b, tab, misses)
}

// BenchmarkGetRealDB runs uniform random keys against a real hash.k2d (K2_VIRAL_DB); skips without.
func BenchmarkGetRealDB(b *testing.B) {
	dir := os.Getenv("K2_VIRAL_DB")
	if dir == "" {
		b.Skip("K2_VIRAL_DB not set")
	}
	tab, err := Load(filepath.Join(dir, "hash.k2d"), Options{})
	if err != nil {
		b.Fatal(err)
	}
	defer tab.Close()
	r := rand.New(rand.NewPCG(5, 5))
	keys := make([]uint64, 1<<20)
	for i := range keys {
		keys[i] = r.Uint64()
	}
	benchGet(b, tab, keys)
}
