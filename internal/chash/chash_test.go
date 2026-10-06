package chash

import (
	"bytes"
	"encoding/binary"
	"io"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Vectors from upstream's kv_store.h MurmurHash3, compiled at the pin.
func TestMurmurHash3(t *testing.T) {
	for _, c := range []struct{ in, want uint64 }{
		{0, 0},
		{1, 0xb456bcfc34c2cb2c},
		{2, 0x3abf2a20650683e7},
		{0x123456789abcdef, 0x87cbfbfe89022cea},
		{^uint64(0), 0x64b5720b4b825f21},
	} {
		if got := MurmurHash3(c.in); got != c.want {
			t.Errorf("MurmurHash3(%#x) = %#x, want %#x", c.in, got, c.want)
		}
	}
}

// Vectors from upstream's CompactHashCell40::populate, hashed_key and value, compiled at the
// pin. raw is the packed cell (a | b<<32). Rows with value_bits 4 show upstream truncating the
// key to 32 bits.
func TestDecode40(t *testing.T) {
	for _, c := range []struct {
		vb      uint
		ck, raw uint64
		key     uint64
		value   uint32
	}{
		{4, 0x1, 0x14, 0x1, 4},
		{4, 0xabcde, 0xabcde6, 0xabcde, 6},
		{4, 0x123456789, 0x1234567894, 0x23456789, 4},
		{4, 0xfffffffff, 0xfffffffff1, 0xffffffff, 1},
		{8, 0x1, 0x1b4, 0x1, 180},
		{8, 0xabcde, 0xabcde66, 0xabcde, 102},
		{8, 0x23456789, 0x2345678984, 0x23456789, 132},
		{8, 0xffffffff, 0xffffffff01, 0xffffffff, 1},
		{12, 0x1, 0x14b4, 0x1, 1204},
		{12, 0xabcde, 0xabcdec66, 0xabcde, 3174},
		{12, 0x3456789, 0x3456789a84, 0x3456789, 2692},
		{12, 0xfffffff, 0xfffffff001, 0xfffffff, 1},
		{22, 0x1, 0x74b4b4, 0x1, 3454132},
		{22, 0x2bcde, 0xaf3782cc66, 0x2bcde, 183398},
		{22, 0x16789, 0x59e268ea84, 0x16789, 2681476},
		{22, 0x3ffff, 0xffffe80000, 0x3ffff, 2621440},
		{30, 0x1, 0x74b4b4b4, 0x1, 884257972},
		{30, 0xde, 0x37b4b4b466, 0xde, 884257894},
		{30, 0x389, 0xe243c3c284, 0x389, 63160964},
		{30, 0x3ff, 0xffe9696800, 0x3ff, 694773760},
	} {
		l := Layout{Capacity: 1, KeyBits: 40 - c.vb, ValueBits: c.vb, CellBytes: 5}
		k, v := l.Decode(c.raw)
		if k != c.key || v != c.value {
			t.Errorf("vb=%d raw=%#x: got key %#x value %d, want %#x %d", c.vb, c.raw, k, v, c.key, c.value)
		}
		if got := populate(l, c.ck, c.value); got != c.raw {
			t.Errorf("vb=%d populate(%#x, %d) = %#x, want %#x", c.vb, c.ck, c.value, got, c.raw)
		}
	}
}

func TestDecode32(t *testing.T) {
	l := Layout{Capacity: 1, KeyBits: 17, ValueBits: 15, CellBytes: 4}
	k, v := l.Decode(uint64(0x1abcd)<<15 | 0x1234)
	if k != 0x1abcd || v != 0x1234 {
		t.Fatalf("got %#x %#x", k, v)
	}
}

// populate is upstream's Cell::populate (test-only: this package is read-only).
func populate(l Layout, compacted uint64, val uint32) uint64 {
	if l.CellBytes == 4 {
		return uint64(uint32(compacted<<l.ValueBits) | val)
	}
	aBits := 32 - l.ValueBits
	b := uint64(uint8(compacted >> aBits))
	a := uint32((compacted&(uint64(1)<<aBits-1))<<l.ValueBits) | (val & l.valueMask())
	return uint64(a) | b<<32
}

// synth and refGet below are transcriptions of upstream code:
// Ported from DerrickWood/kraken2 src/compact_hash.cc (CompareAndSet, Get) at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// synth builds a hash.k2d image by inserting keys the way upstream's CompareAndSet does.
// Returns the image and the inserted key -> value map.
func synth(t testing.TB, capacity, keyBits, valueBits uint64, cellBytes int, mode Mode, n int, seed uint64) ([]byte, map[uint64]uint32) {
	t.Helper()
	h := Header{Capacity: capacity, KeyBits: keyBits, ValueBits: valueBits}
	l, err := h.Layout()
	if err != nil {
		t.Fatal(err)
	}
	if l.CellBytes != cellBytes {
		t.Fatalf("cell bytes %d, want %d", l.CellBytes, cellBytes)
	}
	cells := make([]uint64, capacity)
	r := rand.New(rand.NewPCG(seed, 1))
	kv := map[uint64]uint32{}
	for len(kv) < n {
		key := r.Uint64() >> 1
		val := uint32(r.Uint64N(uint64(l.valueMask()))) + 1
		hc := MurmurHash3(key)
		ck := hc >> (64 - l.KeyBits)
		idx := hc % capacity
		first := idx
		var step uint64
		for {
			k, v := l.Decode(cells[idx])
			if v == 0 || k == ck {
				if v == 0 {
					h.Size++
				}
				cells[idx] = populate(l, ck, val)
				break
			}
			if step == 0 {
				step = mode.step(hc)
			}
			idx = (idx + step) % capacity
			if idx == first {
				t.Fatal("synthetic table full")
			}
		}
		kv[key] = val // a compacted-key collision overwrites, as upstream's would
	}
	img := make([]byte, HeaderSize+int(capacity)*cellBytes)
	binary.LittleEndian.PutUint64(img[0:], h.Capacity)
	binary.LittleEndian.PutUint64(img[8:], h.Size)
	binary.LittleEndian.PutUint64(img[16:], h.KeyBits)
	binary.LittleEndian.PutUint64(img[24:], h.ValueBits)
	var tmp [8]byte
	for i, c := range cells {
		binary.LittleEndian.PutUint64(tmp[:], c)
		copy(img[HeaderSize+i*cellBytes:], tmp[:cellBytes])
	}
	return img, kv
}

// refGet is a direct transcription of upstream's Get, counting cells examined, over decoded cells.
func refGet(l Layout, mode Mode, cell func(uint64) uint64, key uint64) (uint32, int) {
	hc := MurmurHash3(key)
	ck := hc >> (64 - l.KeyBits)
	idx := hc % l.Capacity
	first := idx
	var step uint64
	probes := 0
	for {
		probes++
		k, v := l.Decode(cell(idx))
		if v == 0 {
			break
		}
		if k == ck {
			return v, probes
		}
		if step == 0 {
			step = mode.step(hc)
		}
		idx += step
		idx %= l.Capacity
		if idx == first {
			break
		}
	}
	return 0, probes
}

func checkTable(t *testing.T, tab *Table, img []byte, kv map[uint64]uint32) {
	t.Helper()
	src := &ReaderAtSource{R: bytes.NewReader(img), Layout: tab.Layout}
	r := rand.New(rand.NewPCG(7, 7))
	keys := make([]uint64, 0, 2*len(kv))
	for k := range kv {
		keys = append(keys, k)
	}
	for range len(kv) {
		keys = append(keys, r.Uint64())
	}
	hits := 0
	for _, k := range keys {
		v, p, idx := tab.Find(k)
		cell := func(i uint64) uint64 { c, _ := tab.Cell(i); return c }
		rv, rp := refGet(tab.Layout, tab.Mode, cell, k)
		if v != rv || p != rp {
			t.Fatalf("key %#x: Find = (%d, %d), reference = (%d, %d)", k, v, p, rv, rp)
		}
		pv, pp, pidx, err := Probe(tab.Layout, tab.Mode, MurmurHash3(k), src)
		if err != nil || pv != v || pp != p || pidx != idx {
			t.Fatalf("key %#x: Probe(ReaderAt) = (%d, %d, %d, %v), Find = (%d, %d, %d)", k, pv, pp, pidx, err, v, p, idx)
		}
		if want, ok := kv[k]; ok {
			hits++
			if v != want {
				// Only a compacted-key collision with a later key may change an inserted value.
				t.Logf("key %#x: value %d, inserted %d (compacted-key collision)", k, v, want)
			}
			if v == 0 {
				t.Fatalf("inserted key %#x missed", k)
			}
		}
	}
	if hits != len(kv) {
		t.Fatalf("hits %d, want %d", hits, len(kv))
	}
}

func TestSynthetic(t *testing.T) {
	for _, c := range []struct {
		name             string
		capacity, kb, vb uint64
		cellBytes        int
		mode             Mode
		n                int
	}{
		{"32-linear", 10007, 17, 15, 4, Linear, 8000},
		{"32-double", 10007, 17, 15, 4, Double, 8000},
		{"32-linear-pow2", 1 << 14, 16, 16, 4, Linear, 15000},
		{"32-double-pow2", 1 << 14, 16, 16, 4, Double, 15000},
		{"40-linear", 10007, 22, 18, 5, Linear, 8000},
		{"40-double", 10007, 22, 18, 5, Double, 8000},
	} {
		t.Run(c.name, func(t *testing.T) {
			img, kv := synth(t, c.capacity, c.kb, c.vb, c.cellBytes, c.mode, c.n, 42)
			tab, err := FromBytes(img, c.mode)
			if err != nil {
				t.Fatal(err)
			}
			checkTable(t, tab, img, kv)

			path := filepath.Join(t.TempDir(), "hash.k2d")
			if err := os.WriteFile(path, img, 0o644); err != nil {
				t.Fatal(err)
			}
			for name, load := range map[string]func(string, Options) (*Table, error){"Load": Load, "Mmap": Mmap} {
				ft, err := load(path, Options{Mode: c.mode, ReadThreads: 3})
				if err != nil {
					t.Fatalf("%s: %v", name, err)
				}
				checkTable(t, ft, img, kv)
				if err := ft.Close(); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

// A full table: a miss examines every cell on its cycle, then stops at the home cell.
func TestFullWrap(t *testing.T) {
	for _, c := range []struct {
		capacity uint64
		mode     Mode
	}{{8, Linear}, {6, Linear}, {8, Double}, {6, Double}, {9, Double}} {
		img := make([]byte, HeaderSize+4*c.capacity)
		binary.LittleEndian.PutUint64(img[0:], c.capacity)
		binary.LittleEndian.PutUint64(img[8:], c.capacity)
		binary.LittleEndian.PutUint64(img[16:], 16)
		binary.LittleEndian.PutUint64(img[24:], 16)
		hc := MurmurHash3(12345)
		other := uint32(hc>>48) ^ 1 // never the probe's compacted key
		for i := range c.capacity {
			binary.LittleEndian.PutUint32(img[HeaderSize+4*i:], other<<16|1)
		}
		tab, err := FromBytes(img, c.mode)
		if err != nil {
			t.Fatal(err)
		}
		v, p, idx := tab.Find(12345)
		// Cycle length of idx -> idx+step mod capacity is capacity/gcd(step, capacity).
		step := c.mode.step(hc) % c.capacity
		g := gcd(step, c.capacity)
		if v != 0 || uint64(p) != c.capacity/g || idx != hc%c.capacity {
			t.Errorf("cap %d %v: got (%d, %d, %d), want (0, %d, %d)", c.capacity, c.mode, v, p, idx, c.capacity/g, hc%c.capacity)
		}
	}
}

func gcd(a, b uint64) uint64 {
	for b != 0 {
		a, b = b, a%b
	}
	return a
}

func TestHeaderErrors(t *testing.T) {
	mk := func(capacity, size, kb, vb uint64) []byte {
		b := make([]byte, HeaderSize)
		binary.LittleEndian.PutUint64(b[0:], capacity)
		binary.LittleEndian.PutUint64(b[8:], size)
		binary.LittleEndian.PutUint64(b[16:], kb)
		binary.LittleEndian.PutUint64(b[24:], vb)
		return b
	}
	for _, c := range []struct {
		name string
		b    []byte
		want string
	}{
		{"short", make([]byte, 31), "header is 31 bytes"},
		{"width", mk(10, 1, 16, 15), "want 32 or 40"},
		{"zero-key", mk(10, 1, 0, 32), "nonzero"},
		{"value31", mk(10, 1, 1, 31), ">= 31"},
		{"capacity", mk(0, 0, 16, 16), "capacity is zero"},
		{"size", mk(10, 11, 16, 16), "exceeds capacity"},
		// 32 + capacity*5 wraps to a small number: must be refused, not sliced.
		{"overflow40", mk(1<<62, 0, 25, 15), "overflows"},
		{"overflow32", mk(1<<63, 0, 16, 16), "overflows"},
	} {
		if _, err := ParseHeader(c.b); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: err = %v, want %q", c.name, err, c.want)
		}
	}

	// File size must be exactly header + capacity x cell bytes.
	img, _ := synth(t, 101, 16, 16, 4, Linear, 50, 1)
	path := filepath.Join(t.TempDir(), "hash.k2d")
	if err := os.WriteFile(path, img[:len(img)-1], 0o644); err != nil {
		t.Fatal(err)
	}
	for _, load := range []func(string, Options) (*Table, error){Load, Mmap} {
		if _, err := load(path, Options{}); err == nil || !strings.Contains(err.Error(), "capacity mismatch") {
			t.Errorf("truncated file: err = %v", err)
		}
	}
}

func TestGetNoAlloc(t *testing.T) {
	img, kv := synth(t, 4099, 16, 16, 4, Linear, 3000, 3)
	tab, err := FromBytes(img, Linear)
	if err != nil {
		t.Fatal(err)
	}
	var key uint64
	for k := range kv {
		key = k
		break
	}
	if a := testing.AllocsPerRun(1000, func() { tab.Get(key); tab.Get(key ^ 0x5555) }); a != 0 {
		t.Fatalf("Get allocates %v per run", a)
	}
}

// Real-database smoke test: Load and Mmap agree. Skips unless K2_VIRAL_DB names a DB directory.
func TestRealDBLoadVsMmap(t *testing.T) {
	dir := os.Getenv("K2_VIRAL_DB")
	if dir == "" {
		t.Skip("K2_VIRAL_DB not set")
	}
	path := filepath.Join(dir, "hash.k2d")
	if _, err := os.Stat(path); err != nil {
		t.Skip(err)
	}
	a, err := Load(path, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := Mmap(path, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	r := rand.New(rand.NewPCG(1, 2))
	for range 100000 {
		k := r.Uint64()
		av, ap := a.Get(k)
		bv, bp := b.Get(k)
		if av != bv || ap != bp {
			t.Fatalf("key %#x: Load (%d, %d) != Mmap (%d, %d)", k, av, ap, bv, bp)
		}
	}
}

// eofAtEnd is an io.ReaderAt that returns io.EOF together with a full read that reaches the end
// of its data, as io.ReaderAt permits.
type eofAtEnd struct{ b []byte }

func (r eofAtEnd) ReadAt(p []byte, off int64) (int, error) {
	if off >= int64(len(r.b)) {
		return 0, io.EOF
	}
	n := copy(p, r.b[off:])
	if off+int64(n) == int64(len(r.b)) {
		return n, io.EOF
	}
	return n, nil
}

func TestReaderAtSourceEOF(t *testing.T) {
	img, _ := synth(t, 101, 25, 15, 5, Linear, 50, 2)
	h, err := ParseHeader(img)
	if err != nil {
		t.Fatal(err)
	}
	l, _ := h.Layout()
	src := &ReaderAtSource{R: eofAtEnd{img}, Layout: l}
	last := l.Capacity - 1
	got, err := src.Cell(last)
	if err != nil {
		t.Fatalf("last cell with io.EOF: %v", err)
	}
	var tmp [8]byte
	copy(tmp[:], img[HeaderSize+int(last)*5:])
	if want := binary.LittleEndian.Uint64(tmp[:]); got != want {
		t.Fatalf("last cell = %#x, want %#x", got, want)
	}
	short := &ReaderAtSource{R: eofAtEnd{img[:len(img)-1]}, Layout: l}
	if _, err := short.Cell(last); err == nil {
		t.Fatal("short last cell: no error")
	}
}
