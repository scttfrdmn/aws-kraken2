// Ported from DerrickWood/kraken2 src/compact_hash.h (Get) at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package engine is the sharded resident table (G3, issue #24): N shards of hash.k2d, each
// holding a contiguous slot range plus an overlap tail, and a router that sends each lookup to
// the shard owning its home slot.
//
// # Shards
//
// Shard i of N owns the slots [floor(i·C/N), floor((i+1)·C/N)) of a table of capacity C (Cut).
// It holds those cells and the Tail cells that follow, slots taken modulo C, so the last
// shard's tail wraps to slot 0. Upstream's probe is linear (-DLINEAR_PROBING): from the home
// slot it walks forward until a key match, an empty cell, or a full wrap. A probe that starts
// in a shard stops at or before the first empty cell at or after its home slot, so if the
// shard holds an empty cell at or after its last owned slot, every probe it owns ends inside
// it. LoadShard checks exactly that once the cells are in, and refuses the shard otherwise: a
// probe never leaves its shard, and a tail too short for the table is a load error rather
// than a wrong answer. The tail to ask for comes from G0c's run-length measurement
// (results/g0c/*/tables/tails.tsv, docs/g0c.md): the per-N tail for power-of-two N, else the
// global longest run (302 cells for RODA v205).
//
// A shard whose owned range plus tail reaches all C cells (always for N = 1) holds the whole
// table and probes it with upstream's wraparound and full-wrap stop.
package engine

import (
	"context"
	"errors"
	"fmt"
	"math/bits"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

// DefaultTail is the overlap tail used when none is given: RODA v205's global longest
// occupied run (G0c-a, results/g0c/20261006-091414-1b5fe49/tables/tails.tsv), which bounds
// the tail for any cut of that table. LoadShard verifies whatever tail it is given.
const DefaultTail = 302

// Cut returns the slots shard i of n owns: [floor(i·c/n), floor((i+1)·c/n)).
func Cut(i, n int, c uint64) (lo, hi uint64) {
	return cutAt(uint64(i), uint64(n), c), cutAt(uint64(i+1), uint64(n), c)
}

// cutAt is floor(i·c/n) without overflow (i <= n).
func cutAt(i, n, c uint64) uint64 {
	hi, lo := bits.Mul64(i, c)
	q, _ := bits.Div64(hi, lo, n) // hi < n because i <= n
	return q
}

// Owner returns the shard of n that owns slot s of a table of capacity c (s < c): the i with
// Cut(i) <= s < Cut(i+1), which is floor(((s+1)·n − 1)/c).
func Owner(s uint64, n int, c uint64) int {
	hi, lo := bits.Mul64(s+1, uint64(n))
	lo, borrow := bits.Sub64(lo, 1, 0)
	hi -= borrow
	q, _ := bits.Div64(hi, lo, c) // (s+1)·n − 1 < c·n, so hi < c
	return int(q)
}

// Shard is one shard's cells, resident off-heap. It is safe for concurrent lookups.
type Shard struct {
	Layout chash.Layout
	Index  int    // i
	N      int    // shard count
	Lo, Hi uint64 // owned slots [Lo, Hi)
	Tail   uint64 // cells held past Hi (slots mod C); 0 when Full
	Len    uint64 // cells held: Hi−Lo+Tail, or C when Full
	Full   bool   // holds the whole table (probes wrap as upstream's)
	// Empty is the local index of the first empty cell at or after Hi−1: the furthest any
	// probe owned by this shard can read (Len when Full, or when the shard owns no slot).
	Empty uint64
	// TailProbes counts lookups whose probe ended in the tail, past the owned slots: the
	// lookups a shard without its tail would have got wrong. WrapProbes counts those of them
	// that ended past slot C−1, in the wrapped part of the last shard's tail.
	TailProbes, WrapProbes atomic.Int64

	cells32 []uint32
	cells40 []byte
	region  *chash.Region
	mask    uint32
	vb      uint
	shiftK  uint
}

// A Filler copies bytes of a hash.k2d image: len(dst) bytes from byte off of the image.
// Fill may write dst from several goroutines but must not return until every write has
// finished, and must stop early (returning an error) once ctx is done.
type Filler interface {
	Fill(ctx context.Context, dst []byte, off int64) error
}

// RangeFiller fills with concurrent ranged reads of Chunk bytes from Src (a local file or S3
// ranged GETs, internal/rangeread), written straight into dst.
type RangeFiller struct {
	Src     rangeread.Source
	Chunk   int64 // bytes per read (default 64 MiB)
	Workers int   // concurrent reads (default 8)
}

// Fill implements Filler.
func (f RangeFiller) Fill(ctx context.Context, dst []byte, off int64) error {
	chunk := f.Chunk
	if chunk <= 0 {
		chunk = 64 << 20
	}
	workers := max(f.Workers, 1)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	n := (int64(len(dst)) + chunk - 1) / chunk
	next := make(chan int64)
	go func() {
		defer close(next)
		for i := int64(0); i < n; i++ {
			select {
			case next <- i:
			case <-ctx.Done():
				return
			}
		}
	}()
	var wg sync.WaitGroup
	var mu sync.Mutex
	var first error
	for range min(int64(workers), max(n, 1)) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range next {
				s := i * chunk
				e := min(s+chunk, int64(len(dst)))
				if err := f.Src.ReadRange(ctx, off+s, dst[s:e]); err != nil {
					mu.Lock()
					if first == nil {
						first = err
					}
					mu.Unlock()
					cancel()
					return
				}
			}
		}()
	}
	wg.Wait()
	if first == nil && ctx.Err() != nil {
		first = ctx.Err()
	}
	return first
}

// ReadLayout reads and validates the hash.k2d header through src, and checks it against the
// object's size as upstream's LoadTable does ("Capacity mismatch").
func ReadLayout(ctx context.Context, src rangeread.Source, size int64) (chash.Header, chash.Layout, error) {
	var hb [chash.HeaderSize]byte
	if err := src.ReadRange(ctx, 0, hb[:]); err != nil {
		return chash.Header{}, chash.Layout{}, fmt.Errorf("engine: read header: %w", err)
	}
	h, err := chash.ParseHeader(hb[:])
	if err != nil {
		return chash.Header{}, chash.Layout{}, err
	}
	if _, err := kdb.CellWidth(kdb.HashHeader(h), size); err != nil {
		return chash.Header{}, chash.Layout{}, fmt.Errorf("engine: capacity mismatch: %w", err)
	}
	l, _ := h.Layout()
	return h, l, nil
}

// ErrTailTooShort is LoadShard's error when the loaded tail holds no empty cell: some probe
// owned by the shard could read past it.
var ErrTailTooShort = errors.New("engine: overlap tail holds no empty cell")

// LoadShard loads shard i of n of the table l describes, holding its owned slots plus tail
// cells, through fill, and verifies the tail (see the package comment).
func LoadShard(ctx context.Context, l chash.Layout, i, n int, tail uint64, fill Filler) (*Shard, error) {
	if n < 1 || i < 0 || i >= n {
		return nil, fmt.Errorf("engine: shard %d of %d", i, n)
	}
	if l.CellBytes != 4 && l.CellBytes != 5 {
		return nil, fmt.Errorf("engine: %d-byte cells", l.CellBytes)
	}
	c := l.Capacity
	lo, hi := Cut(i, n, c)
	s := &Shard{Layout: l, Index: i, N: n, Lo: lo, Hi: hi, vb: l.ValueBits,
		mask: uint32(1)<<l.ValueBits - 1, shiftK: 64 - l.KeyBits}
	own := hi - lo
	if n == 1 || tail >= c-own {
		s.Full, s.Len, s.Tail = true, c, 0
		s.Lo, s.Hi = lo, hi
	} else {
		s.Tail, s.Len = tail, own+tail
	}
	cb := uint64(l.CellBytes)
	r, err := chash.AllocRegion(int(s.Len * cb))
	if err != nil {
		return nil, err
	}
	s.region = r
	buf := r.Bytes()
	// Global cells [lo, lo+Len) mod C: one segment, or two when it wraps past C−1.
	first := min(s.Len, c-lo)
	if err := fill.Fill(ctx, buf[:first*cb], int64(chash.HeaderSize+lo*cb)); err != nil {
		r.Close()
		return nil, fmt.Errorf("engine: load shard %d/%d cells [%d,%d): %w", i, n, lo, lo+first, err)
	}
	if rest := s.Len - first; rest > 0 {
		if err := fill.Fill(ctx, buf[first*cb:], chash.HeaderSize); err != nil {
			r.Close()
			return nil, fmt.Errorf("engine: load shard %d/%d wrapped cells [0,%d): %w", i, n, rest, err)
		}
	}
	if cb == 4 {
		s.cells32 = unsafe.Slice((*uint32)(unsafe.Pointer(unsafe.SliceData(buf))), s.Len)
	} else {
		s.cells40 = buf
	}
	if err := s.checkTail(); err != nil {
		r.Close()
		return nil, err
	}
	return s, nil
}

// raw returns local cell j.
func (s *Shard) raw(j uint64) uint32 {
	if s.cells32 != nil {
		return s.cells32[j]
	}
	_, v := s.Layout.Decode(s.raw40(j))
	return v // only the value matters to callers of raw
}

func (s *Shard) raw40(j uint64) uint64 {
	c := s.cells40[j*5 : j*5+5]
	return uint64(c[0]) | uint64(c[1])<<8 | uint64(c[2])<<16 | uint64(c[3])<<24 | uint64(c[4])<<32
}

func (s *Shard) checkTail() error {
	if s.Full || s.Hi == s.Lo {
		s.Empty = s.Len
		return nil
	}
	for j := s.Hi - s.Lo - 1; j < s.Len; j++ {
		if s.raw(j)&s.mask == 0 {
			s.Empty = j
			return nil
		}
	}
	return fmt.Errorf("%w: shard %d/%d owns slots [%d,%d) and holds %d tail cells, all occupied, "+
		"as is slot %d; ask for a longer tail (docs/g0c.md, tails.tsv)",
		ErrTailTooShort, s.Index, s.N, s.Lo, s.Hi, s.Tail, s.Hi-1)
}

// Close releases the shard's memory.
func (s *Shard) Close() error {
	s.cells32, s.cells40 = nil, nil
	if s.region == nil {
		return nil
	}
	return s.region.Close()
}

// sink keeps LookupBatch's touch loads from being optimised away.
var sink atomic.Uint32

// Owns reports whether slot is one of the shard's owned slots.
func (s *Shard) Owns(slot uint64) bool { return slot >= s.Lo && slot < s.Hi }

// LookupBatch sets vals[i] to upstream Get's value for the hashed key hcs[i] =
// MurmurHash3(key). Every home slot hcs[i] % C must be owned by the shard. Like
// chash.Table.GetBatch it touches a group of home cells before probing them, so the cache
// misses overlap.
func (s *Shard) LookupBatch(hcs []uint64, vals []uint32) error {
	if len(vals) != len(hcs) {
		return fmt.Errorf("engine: %d values for %d keys", len(vals), len(hcs))
	}
	if s.cells32 == nil {
		for i, hc := range hcs {
			v, err := s.lookup40(hc)
			if err != nil {
				return err
			}
			vals[i] = v
		}
		return nil
	}
	for start := 0; start < len(hcs); start += touchGroup {
		end := min(start+touchGroup, len(hcs))
		if err := s.lookup32(hcs[start:end], vals[start:end]); err != nil {
			return err
		}
	}
	return nil
}

// touchGroup is how many home cells LookupBatch touches before probing them: about a read's
// worth of lookups, as chash.Table.GetBatch does per read, so the touched lines are still
// cached when the probes reach them.
const touchGroup = 32

func (s *Shard) lookup32(hcs []uint64, vals []uint32) error {
	c := s.Layout.Capacity
	cells := s.cells32
	var touch uint32
	for _, hc := range hcs {
		slot := hc % c
		if slot < s.Lo || slot >= s.Hi {
			return fmt.Errorf("engine: shard %d/%d [%d,%d) asked for slot %d", s.Index, s.N, s.Lo, s.Hi, slot)
		}
		touch |= cells[slot-s.Lo]
	}
	sink.Store(touch)
	mask, vb, shift, n := s.mask, s.vb, s.shiftK, s.Len
	own := s.Hi - s.Lo
	var tail, wrap int64
	for i, hc := range hcs {
		compacted := hc >> shift
		j := hc%c - s.Lo
		first := j
		var v uint32
		for {
			d := cells[j]
			v = d & mask
			if v == 0 || uint64(d>>vb) == compacted {
				break
			}
			if j++; j == n {
				if !s.Full {
					return s.leftShard(hc)
				}
				j = 0
			}
			if j == first {
				v = 0
				break
			}
		}
		if j >= own { // ended in the tail (never for a Full shard, whose j stays below C)
			tail++
			if s.Lo+j >= c {
				wrap++
			}
		}
		vals[i] = v
	}
	s.count(tail, wrap)
	return nil
}

// count adds to the tail counters.
func (s *Shard) count(tail, wrap int64) {
	if tail != 0 {
		s.TailProbes.Add(tail)
		s.WrapProbes.Add(wrap)
	}
}

func (s *Shard) leftShard(hc uint64) error {
	return fmt.Errorf("engine: probe for slot %d left shard %d/%d (holds %d cells from slot %d)",
		hc%s.Layout.Capacity, s.Index, s.N, s.Len, s.Lo)
}

// lookup40 is the probe over 40-bit cells (CompactHashCell40), through Layout.Decode.
func (s *Shard) lookup40(hc uint64) (uint32, error) {
	c := s.Layout.Capacity
	slot := hc % c
	if slot < s.Lo || slot >= s.Hi {
		return 0, fmt.Errorf("engine: shard %d/%d [%d,%d) asked for slot %d", s.Index, s.N, s.Lo, s.Hi, slot)
	}
	compacted := hc >> s.shiftK
	j := slot - s.Lo
	first := j
	done := func(v uint32) (uint32, error) {
		if j >= s.Hi-s.Lo {
			var w int64
			if s.Lo+j >= c {
				w = 1
			}
			s.count(1, w)
		}
		return v, nil
	}
	for {
		k, v := s.Layout.Decode(s.raw40(j))
		if v == 0 {
			return done(0)
		}
		if k == compacted {
			return done(v)
		}
		if j++; j == s.Len {
			if !s.Full {
				return 0, s.leftShard(hc)
			}
			j = 0
		}
		if j == first {
			return 0, nil
		}
	}
}
