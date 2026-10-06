package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"math/rand/v2"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
)

type memSource []byte

func (m memSource) ReadRange(_ context.Context, off int64, dst []byte) error {
	copy(dst, m[off:])
	return nil
}

// TestWindowSourceMatchesTable: Probe over point-GET windows (tiny windows, so runs extend
// across several fetches and across the wrap) returns exactly what it returns over the whole
// table, with the same probe count and final slot.
func TestWindowSourceMatchesTable(t *testing.T) {
	rng := rand.New(rand.NewPCG(7, 8))
	const c = 997
	lay := chash.Layout{Capacity: c, KeyBits: 10, ValueBits: 22, CellBytes: 4}
	img := make([]byte, chash.HeaderSize+4*c)
	for i, v := range []uint64{c, 900, 10, 22} {
		binary.LittleEndian.PutUint64(img[8*i:], v)
	}
	cells := img[chash.HeaderSize:]
	// Insert 900 keys by linear probing (dense, so runs are long and wrap).
	for k := 0; k < 900; k++ {
		hc := rng.Uint64()
		i := hc % c
		for binary.LittleEndian.Uint32(cells[4*i:]) != 0 {
			i = (i + 1) % c
		}
		binary.LittleEndian.PutUint32(cells[4*i:], uint32(hc>>54)<<22|uint32(1+rng.IntN(1000)))
	}
	ref := &chash.ReaderAtSource{R: bytes.NewReader(img), Layout: lay}
	wrapped := 0
	for trial := 0; trial < 20000; trial++ {
		hc := rng.Uint64()
		if trial%3 == 0 { // homes near the end of the table
			hc = hc - hc%c + uint64(c-1-rng.IntN(5))
		}
		ws := &windowSource{src: memSource(img), layout: lay, cells: uint64(1 + rng.IntN(7))}
		v, p, idx, err := chash.Probe(lay, chash.Linear, hc, ws)
		if err != nil {
			t.Fatal(err)
		}
		v2, p2, idx2, _ := chash.Probe(lay, chash.Linear, hc, ref)
		if v != v2 || p != p2 || idx != idx2 {
			t.Fatalf("hc %x: windows (%d,%d,%d) vs table (%d,%d,%d)", hc, v, p, idx, v2, p2, idx2)
		}
		if idx < hc%c {
			wrapped++
		}
	}
	if wrapped == 0 {
		t.Fatal("no probe wrapped; the test does not cover the wrap")
	}
}
