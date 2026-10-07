package main

import (
	"bytes"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

// TestClusterInProcess runs a 3-node multi-node run in one process (each node with its own
// AK2_ENGINE_* environment; the rendezvous is a directory, the shards talk over loopback TCP)
// and compares every output with the plain path's. CI runs it under -race (go test -race), so
// the node, inbox, flow-control and emitter code is race-checked end to end. The window is one
// block, so flow control is exercised; --output and the sequence outputs go to an emulated S3
// bucket as multipart uploads, the report to a local file.
func TestClusterInProcess(t *testing.T) {
	db := oracletest.DB(t, "k2_viral_20260626")
	r1 := oracletest.Reads(t, "SRR062634_200000_1.fq")
	r2 := oracletest.Reads(t, "SRR062634_200000_2.fq")
	dir := t.TempDir()
	t.Setenv("AK2_S3_EMULATE", filepath.Join(dir, "s3"))
	none := func(string) (string, bool) { return "", false }
	plain := filepath.Join(dir, "plain")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	args := func(out, rep, cls, uncls string) []string {
		return []string{"--db", db, "--threads", "3", "--paired", "--report-zero-counts",
			"--output", out, "--report", rep, "--classified-out", cls, "--unclassified-out", uncls, r1, r2}
	}
	if st := runEnv(args(plain+"/out", plain+"/rep", plain+"/c#.fq", plain+"/u#.fq"), none); st != 0 {
		t.Fatalf("plain run: exit %d", st)
	}
	const n = 3
	rv := filepath.Join(dir, "rv")
	s3 := "s3://bkt/run"
	var wg sync.WaitGroup
	status := make([]int, n)
	for rank := 0; rank < n; rank++ {
		env := map[string]string{"AK2_ENGINE_N": "3", "AK2_ENGINE_RANK": string(rune('0' + rank)),
			"AK2_ENGINE_RENDEZVOUS": rv, "AK2_ENGINE_WINDOW": "1", "AK2_ENGINE_TIMEOUT": "2m"}
		lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
		rep := filepath.Join(dir, "rep-"+string(rune('0'+rank)))
		wg.Add(1)
		go func() {
			defer wg.Done()
			status[rank] = runEnv(args(s3+"/out", rep, s3+"/c#.fq", s3+"/u#.fq"), lookup)
		}()
	}
	wg.Wait()
	for rank, st := range status {
		if st != 0 {
			t.Fatalf("rank %d: exit %d", rank, st)
		}
	}
	read := func(p string) []byte {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	emu := filepath.Join(dir, "s3", "bkt", "run")
	for _, f := range [][2]string{{"out", "out"}, {"c_1.fq", "c_1.fq"}, {"c_2.fq", "c_2.fq"}, {"u_1.fq", "u_1.fq"}, {"u_2.fq", "u_2.fq"}} {
		if !bytes.Equal(read(filepath.Join(plain, f[0])), read(filepath.Join(emu, f[1]))) {
			t.Errorf("%s differs from the plain run", f[0])
		}
	}
	if !bytes.Equal(read(plain+"/rep"), read(filepath.Join(dir, "rep-0"))) {
		t.Error("the emitter's report differs from the plain run's")
	}
	for rank := 1; rank < n; rank++ {
		if _, err := os.Stat(filepath.Join(dir, "rep-"+string(rune('0'+rank)))); err == nil {
			t.Errorf("rank %d wrote a report", rank)
		}
	}
	if ups, _ := os.ReadDir(filepath.Join(dir, "s3", ".uploads")); len(ups) != 0 {
		t.Errorf("%d multipart uploads left open", len(ups))
	}
}
