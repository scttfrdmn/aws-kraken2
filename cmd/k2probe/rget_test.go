package main

import (
	"bytes"
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"
)

// rget -file SRC -out DST copies SRC exactly, range by range (synthetic data: unit test only).
func TestRgetCopiesExactly(t *testing.T) {
	d := t.TempDir()
	src := filepath.Join(d, "src")
	data := make([]byte, 5<<20+12345)
	rng := rand.New(rand.NewPCG(7, 7))
	for i := range data {
		data[i] = byte(rng.Uint32())
	}
	if err := os.WriteFile(src, data, 0o644); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(d, "dst")
	if err := rget([]string{"-file", src, "-out", dst, "-workers", "3", "-chunk-mib", "1", "-every", "0.01"}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("copy differs (%d vs %d bytes)", len(got), len(data))
	}
	// Discard mode and a start offset run too.
	if err := rget([]string{"-file", src, "-workers", "2", "-chunk-mib", "1", "-start", "1048576"}); err != nil {
		t.Fatal(err)
	}
}
