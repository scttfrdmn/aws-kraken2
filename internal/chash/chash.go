// Ported from DerrickWood/kraken2 src/compact_hash.h at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package chash is the lookup path of upstream's CompactHashTable (hash.k2d): MurmurHash3's
// fmix64, the 32- and 40-bit cell decodes, and the probe loop of Get/FindIndex, with probe counts.
//
// The probe logic is separate from cell storage: Probe resolves a lookup over any CellSource (an
// in-RAM table, an mmap, or ranged reads through an io.ReaderAt), and Table.Get is the fast
// in-RAM path with the same semantics and no allocation.
package chash

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"math/bits"

	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
)

// MurmurHash3 is upstream's MurmurHash3 (kv_store.h): the 64-bit fmix finalizer.
func MurmurHash3(key uint64) uint64 {
	k := key
	k ^= k >> 33
	k *= 0xff51afd7ed558ccd
	k ^= k >> 33
	k *= 0xc4ceb9fe1a85ec53
	k ^= k >> 33
	return k
}

// Mode is the probe sequence. Upstream chooses it at compile time: src/Makefile and
// CMakeLists.txt define LINEAR_PROBING at the pin, so second_hash() returns 1. Without that
// define, second_hash() is double hashing, (hc >> 8) | 1.
type Mode int

const (
	// Linear matches upstream's default build (-DLINEAR_PROBING). The zero value.
	Linear Mode = iota
	// Double matches an upstream build without -DLINEAR_PROBING.
	Double
)

func (m Mode) String() string {
	switch m {
	case Linear:
		return "linear"
	case Double:
		return "double"
	}
	return fmt.Sprintf("Mode(%d)", int(m))
}

// ParseMode accepts "linear" or "double".
func ParseMode(s string) (Mode, error) {
	switch s {
	case "linear":
		return Linear, nil
	case "double":
		return Double, nil
	}
	return 0, fmt.Errorf("chash: unknown probe mode %q (want linear or double)", s)
}

// step is upstream's second_hash.
func (m Mode) step(hc uint64) uint64 {
	if m == Double {
		return (hc >> 8) | 1
	}
	return 1
}

// HeaderSize is the byte length of the hash.k2d header: four uint64 LE.
const HeaderSize = 32

// Header is the hash.k2d header (upstream writes four size_t: capacity, size, key_bits,
// value_bits).
type Header struct {
	Capacity  uint64
	Size      uint64
	KeyBits   uint64
	ValueBits uint64
}

// ParseHeader decodes (with internal/kdb, the one header parser) and validates a hash.k2d header.
func ParseHeader(b []byte) (Header, error) {
	if len(b) < HeaderSize {
		return Header{}, fmt.Errorf("chash: header is %d bytes, want %d", len(b), HeaderSize)
	}
	kh, err := kdb.ReadHashHeader(bytes.NewReader(b[:HeaderSize]))
	if err != nil {
		return Header{}, err
	}
	h := Header(kh)
	if _, err := h.Layout(); err != nil {
		return Header{}, err
	}
	return h, nil
}

// Layout is the decoded cell format: everything Probe needs besides the cells themselves.
type Layout struct {
	Capacity  uint64
	KeyBits   uint
	ValueBits uint
	CellBytes int // 4 (CompactHashCell) or 5 (CompactHashCell40)
}

// Layout validates the header and derives the cell format. Upstream picks the cell type from
// key_bits+value_bits (GetKVStoreCellType: 32 or 40); anything else, or a combination for which
// upstream's int shifts would be undefined, is an error here rather than a guess.
func (h Header) Layout() (Layout, error) {
	l := Layout{Capacity: h.Capacity, KeyBits: uint(h.KeyBits), ValueBits: uint(h.ValueBits)}
	switch h.KeyBits + h.ValueBits {
	case 32:
		l.CellBytes = 4
	case 40:
		l.CellBytes = 5
	default:
		return Layout{}, fmt.Errorf("chash: key_bits %d + value_bits %d = %d, want 32 or 40",
			h.KeyBits, h.ValueBits, h.KeyBits+h.ValueBits)
	}
	if h.KeyBits == 0 || h.ValueBits == 0 || h.KeyBits > 40 || h.ValueBits > 40 {
		return Layout{}, fmt.Errorf("chash: key_bits %d and value_bits %d must both be nonzero",
			h.KeyBits, h.ValueBits)
	}
	// Upstream computes the value mask as the int expression (1 << value_bits) - 1, and the
	// 40-bit key as int shifts of the 32-bit word: defined only for value_bits < 31.
	if h.ValueBits >= 31 {
		return Layout{}, fmt.Errorf("chash: value_bits %d >= 31 is outside upstream's defined range", h.ValueBits)
	}
	if h.Capacity == 0 {
		return Layout{}, errors.New("chash: capacity is zero")
	}
	if h.Size > h.Capacity {
		return Layout{}, fmt.Errorf("chash: size %d exceeds capacity %d", h.Size, h.Capacity)
	}
	// 32 + capacity*cellBytes must not overflow, and must fit an int (slices, mmap length):
	// a crafted capacity would otherwise wrap past the size check into an out-of-bounds slice.
	hi, cells := bits.Mul64(h.Capacity, uint64(l.CellBytes))
	total, carry := bits.Add64(cells, HeaderSize, 0)
	if hi != 0 || carry != 0 || total > math.MaxInt {
		return Layout{}, fmt.Errorf("chash: capacity %d x %d-byte cells overflows", h.Capacity, l.CellBytes)
	}
	return l, nil
}

// FileSize is the exact hash.k2d size this header implies. Layout values from Header.Layout
// are checked not to overflow.
func (l Layout) FileSize() uint64 { return HeaderSize + l.Capacity*uint64(l.CellBytes) }

// valueMask is upstream's (1 << value_bits) - 1 (value_bits < 31 is validated).
func (l Layout) valueMask() uint32 { return uint32(1)<<l.ValueBits - 1 }

// Decode splits a raw cell into upstream's hashed_key() and value(). raw holds the cell's bytes
// as a little-endian integer (4 bytes for 32-bit cells, 5 for 40-bit ones).
func (l Layout) Decode(raw uint64) (hashedKey uint64, value uint32) {
	a := uint32(raw) // CompactHashCell.data, or CompactHashCell40.a
	value = a & l.valueMask()
	if l.CellBytes == 4 {
		return uint64(a >> l.ValueBits), value
	}
	// CompactHashCell40::hashed_key: (a >> value_bits | b << key_bits) with key_bits =
	// 32 - value_bits. b is promoted to int and the result is unsigned int, so the expression is
	// evaluated (and truncated) in 32 bits before widening to hkey_t.
	b := uint32(uint8(raw >> 32))
	return uint64(a>>l.ValueBits | b<<(32-l.ValueBits)), value
}

// CellSource yields raw cells by index (see Layout.Decode for the encoding).
type CellSource interface {
	Cell(idx uint64) (uint64, error)
}

// Probe resolves one lookup of the hashed key hc = MurmurHash3(key) over src, exactly as
// upstream's FindIndex/Get: start at hc % capacity, compare the compacted key hc >> (64 -
// key_bits), and stop on an empty cell (value 0), on a key match, or on wrapping back to the
// first index. It returns the value (0 on a miss), the number of cells examined, and the index
// FindIndex would leave in *idx: the matching cell, the empty cell, or the home cell after a
// full wrap.
func Probe(l Layout, mode Mode, hc uint64, src CellSource) (value uint32, probes int, idx uint64, err error) {
	compacted := hc >> (64 - l.KeyBits)
	idx = hc % l.Capacity
	first := idx
	var step uint64
	for {
		raw, err := src.Cell(idx)
		if err != nil {
			return 0, probes, idx, err
		}
		probes++
		k, v := l.Decode(raw)
		if v == 0 {
			return 0, probes, idx, nil
		}
		if k == compacted {
			return v, probes, idx, nil
		}
		if step == 0 {
			step = mode.step(hc)
		}
		idx = (idx + step) % l.Capacity
		if idx == first {
			return 0, probes, idx, nil
		}
	}
}

// ReaderAtSource reads cells from a hash.k2d image through an io.ReaderAt (a file, or an object
// store adapter doing ranged GETs). Each Cell call is one ReadAt of CellBytes. It keeps a scratch
// buffer, so one ReaderAtSource must not be used by concurrent goroutines.
type ReaderAtSource struct {
	R      io.ReaderAt
	Layout Layout
	buf    [8]byte
}

// Cell implements CellSource.
func (s *ReaderAtSource) Cell(idx uint64) (uint64, error) {
	if idx >= s.Layout.Capacity {
		return 0, fmt.Errorf("chash: cell %d out of range (capacity %d)", idx, s.Layout.Capacity)
	}
	n := s.Layout.CellBytes
	off := int64(HeaderSize + idx*uint64(n))
	s.buf = [8]byte{}
	// io.ReaderAt may return io.EOF with a full read of the last cell.
	if got, err := s.R.ReadAt(s.buf[:n], off); got < n {
		if err == nil || errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return 0, fmt.Errorf("chash: read cell %d at %d: %w", idx, off, err)
	}
	return binary.LittleEndian.Uint64(s.buf[:]), nil
}
