package main

import (
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

// TestMemoryMappingIndex: --memory-mapping on the plain path (no AK2_ENGINE_N) loads the table
// as chash.Mmap's shared read-only mapping of hash.k2d (no copy; internal/chash
// TestMmapSharedReadOnly), and without the flag as a resident copy. With AK2_ENGINE_N set the
// engine is used and --memory-mapping does not apply (engine.go): the shards are resident. That
// is what ladder O0 at c1 (843e958) ran by accident, the node's cohort env leaking into ours'
// plain path; the ladder body now strips it (scripts/tests/ladder_stream_test.sh, case P).
func TestMemoryMappingIndex(t *testing.T) {
	db := oracletest.DB(t, "k2_viral_20260626")
	r1 := oracletest.Reads(t, "SRR062634_200000_1.fq")
	noEnv := func(string) (string, bool) { return "", false }
	engEnv := func(k string) (string, bool) {
		if k == "AK2_ENGINE_N" {
			return "1", true
		}
		return "", false
	}
	for _, c := range []struct {
		name   string
		mm     bool
		env    func(string) (string, bool)
		mapped bool
		engine bool
	}{
		{"plain -M", true, noEnv, true, false},
		{"plain", false, noEnv, false, false},
		{"engine N=1 -M", true, engEnv, false, true},
	} {
		t.Run(c.name, func(t *testing.T) {
			args := []string{"--db", db, "--threads", "2"}
			if c.mm {
				args = append(args, "--memory-mapping")
			}
			ca, st := buildArgs(append(args, r1), c.env)
			if ca == nil {
				t.Fatalf("buildArgs: status %d", st)
			}
			idx, st := loadIndex(ca)
			if idx == nil {
				t.Fatalf("loadIndex: status %d", st)
			}
			defer idx.close()
			if got := idx.eng != nil; got != c.engine {
				t.Fatalf("engine %v, want %v", got, c.engine)
			}
			if !c.engine && idx.table.Mapped() != c.mapped {
				t.Fatalf("table mapped %v, want %v", idx.table.Mapped(), c.mapped)
			}
		})
	}
}
