// Ported from DerrickWood/kraken2 src/kraken2_data.h, src/kv_store.h, src/compact_hash.h and
// src/classify.cc at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package kdb reads kraken2 database metadata: the opts.k2d IndexOptions record and the
// 32-byte header of hash.k2d, and detects the compact hash cell width.
//
// Layouts are those upstream gets from writing C structs to disk on x86_64/aarch64 Linux
// (LP64, little-endian): size_t and uint64_t are 8 bytes, int is 4, bool is 1.
package kdb

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/bits"
)

// HashHeaderSize is the size of the hash.k2d header: four size_t fields.
const HashHeaderSize = 32

// HashHeader is the header of hash.k2d (CompactHashTable::LoadTable in compact_hash.h).
type HashHeader struct {
	Capacity  uint64 `json:"capacity"`
	Size      uint64 `json:"size"`
	KeyBits   uint64 `json:"key_bits"`
	ValueBits uint64 `json:"value_bits"`
}

// ReadHashHeader reads the 32-byte header at offset 0 of r.
func ReadHashHeader(r io.ReaderAt) (HashHeader, error) {
	var b [HashHeaderSize]byte
	n, err := r.ReadAt(b[:], 0)
	if n < HashHeaderSize {
		if err == nil || errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return HashHeader{}, fmt.Errorf("kdb: hash header: read %d of %d bytes: %w", n, HashHeaderSize, err)
	}
	le := binary.LittleEndian
	return HashHeader{
		Capacity:  le.Uint64(b[0:8]),
		Size:      le.Uint64(b[8:16]),
		KeyBits:   le.Uint64(b[16:24]),
		ValueBits: le.Uint64(b[24:32]),
	}, nil
}

// CellWidth returns the compact hash cell width in bits (32 or 40).
//
// Upstream's GetKVStoreCellType (kv_store.h) decides from key_bits+value_bits alone, and
// LoadTable then aborts on "Capacity mismatch" if the file size disagrees. Here both checks
// are made together, so the width is only reported when the header and the object size
// agree: objectSize must equal 32 + capacity × cellBytes, where the 40-bit cell is the
// packed 5-byte CompactHashCell40.
func CellWidth(h HashHeader, objectSize int64) (int, error) {
	if h.KeyBits == 0 || h.ValueBits == 0 {
		return 0, fmt.Errorf("kdb: key_bits=%d value_bits=%d: both must be non-zero", h.KeyBits, h.ValueBits)
	}
	sum, carry := bits.Add64(h.KeyBits, h.ValueBits, 0)
	if carry != 0 || (sum != 32 && sum != 40) {
		return 0, fmt.Errorf("kdb: key_bits+value_bits = %d+%d is neither 32 nor 40 (upstream: Unknown cell type)",
			h.KeyBits, h.ValueBits)
	}
	if h.Size > h.Capacity {
		return 0, fmt.Errorf("kdb: size %d exceeds capacity %d", h.Size, h.Capacity)
	}
	if objectSize < HashHeaderSize {
		return 0, fmt.Errorf("kdb: object size %d is smaller than the %d-byte header", objectSize, HashHeaderSize)
	}
	cellBytes := sum / 8
	hi, table := bits.Mul64(h.Capacity, cellBytes)
	want, carry := bits.Add64(table, HashHeaderSize, 0)
	if hi != 0 || carry != 0 {
		return 0, fmt.Errorf("kdb: capacity %d × %d bytes overflows uint64", h.Capacity, cellBytes)
	}
	if uint64(objectSize) != want {
		other := uint64(9) - cellBytes // 4 <-> 5
		hint := ""
		if (uint64(objectSize)-HashHeaderSize)%other == 0 && (uint64(objectSize)-HashHeaderSize)/other == h.Capacity {
			hint = fmt.Sprintf("; the size fits %d-bit cells instead", other*8)
		}
		return 0, fmt.Errorf("kdb: object size %d != 32 + capacity %d × %d bytes = %d (key_bits+value_bits=%d)%s",
			objectSize, h.Capacity, cellBytes, want, sum, hint)
	}
	return int(sum), nil
}

// OptionsSize is sizeof(IndexOptions) on LP64 Linux, which is what build_db writes.
const OptionsSize = 64

// Field offsets in IndexOptions (kraken2_data.h). dna_db is followed by 7 bytes of padding
// and the struct by 4 bytes of tail padding; padding bytes are not initialised by upstream
// and are ignored here.
const (
	offK          = 0
	offL          = 8
	offSpacedSeed = 16
	offToggleMask = 24
	offDNADB      = 32
	offMinHash    = 40
	offRevcom     = 48
	offDBVersion  = 52
	offDBType     = 56
)

// Options is IndexOptions from opts.k2d.
type Options struct {
	K                          uint64 `json:"k"`
	L                          uint64 `json:"l"`
	SpacedSeedMask             uint64 `json:"spaced_seed_mask"`
	ToggleMask                 uint64 `json:"toggle_mask"`
	DNADB                      bool   `json:"dna_db"`
	DNADBByte                  uint8  `json:"dna_db_byte"`
	MinimumAcceptableHashValue uint64 `json:"minimum_acceptable_hash_value"`
	RevcomVersion              int32  `json:"revcom_version"`
	DBVersion                  int32  `json:"db_version"`
	DBType                     int32  `json:"db_type"`

	// FileSize is the number of bytes the file held. Upstream (classify.cc load_index)
	// zero-initialises IndexOptions and reads st_size bytes over it, so fields beyond the
	// end of a shorter, older file are zero.
	FileSize int `json:"file_size"`
	// Absent names the fields that lay wholly or partly beyond FileSize and so read as
	// zero (or as a partial little-endian value) exactly as upstream would see them.
	Absent []string `json:"absent_fields"`
	// Layout names the upstream IndexOptions revision whose sizeof equals FileSize.
	Layout string `json:"layout"`
	// Padding names fields that the pin reads but that were struct padding (uninitialised
	// bytes) in the writer's layout. Their values are what upstream sees, and meaningless.
	Padding []string `json:"padding_fields"`
}

// Known on-disk sizes of IndexOptions. The struct grew twice; each older build wrote its own
// sizeof, padding included:
//
//	48: before v2.0.8-beta (5a2a996, 2019-02-04, added revcom_version). Ends at
//	    minimum_acceptable_hash_value; no tail padding.
//	56: v2.0.8-beta to v2.0.9 (5cde83a, 2020-07-13, first in v2.1.0, added db_version and
//	    db_type). Ends at revcom_version plus 4 bytes of tail padding, which the pin reads as
//	    db_version.
//	64: v2.1.0 and later, including the pin.
var layouts = map[int]struct {
	name    string
	padding []string
}{
	48: {"pre-v2.0.8", []string{}},
	56: {"v2.0.8-v2.0.9", []string{"db_version"}},
	64: {"v2.1.0+", []string{}},
}

var optionFields = []struct {
	name     string
	off, len int
}{
	{"k", offK, 8}, {"l", offL, 8}, {"spaced_seed_mask", offSpacedSeed, 8},
	{"toggle_mask", offToggleMask, 8}, {"dna_db", offDNADB, 1},
	{"minimum_acceptable_hash_value", offMinHash, 8}, {"revcom_version", offRevcom, 4},
	{"db_version", offDBVersion, 4}, {"db_type", offDBType, 4},
}

// ReadOptions parses opts.k2d. It accepts any file of at most OptionsSize bytes, reproducing
// upstream's read of st_size bytes into a zeroed struct. A larger file is an error: upstream
// would overrun the struct.
func ReadOptions(r io.Reader) (Options, error) {
	data, err := io.ReadAll(io.LimitReader(r, OptionsSize+1))
	if err != nil {
		return Options{}, fmt.Errorf("kdb: opts: %w", err)
	}
	return ParseOptions(data)
}

// ParseOptions is ReadOptions over an in-memory file.
func ParseOptions(data []byte) (Options, error) {
	if len(data) > OptionsSize {
		return Options{}, fmt.Errorf("kdb: opts is %d+ bytes, larger than sizeof(IndexOptions)=%d; upstream would overrun the struct",
			len(data), OptionsSize)
	}
	if len(data) == 0 {
		return Options{}, errors.New("kdb: opts is empty")
	}
	var b [OptionsSize]byte
	copy(b[:], data)
	le := binary.LittleEndian
	o := Options{
		K:                          le.Uint64(b[offK:]),
		L:                          le.Uint64(b[offL:]),
		SpacedSeedMask:             le.Uint64(b[offSpacedSeed:]),
		ToggleMask:                 le.Uint64(b[offToggleMask:]),
		DNADBByte:                  b[offDNADB],
		DNADB:                      b[offDNADB] != 0,
		MinimumAcceptableHashValue: le.Uint64(b[offMinHash:]),
		RevcomVersion:              int32(le.Uint32(b[offRevcom:])),
		DBVersion:                  int32(le.Uint32(b[offDBVersion:])),
		DBType:                     int32(le.Uint32(b[offDBType:])),
		FileSize:                   len(data),
		Absent:                     []string{},
	}
	if l, ok := layouts[len(data)]; ok {
		o.Layout, o.Padding = l.name, l.padding
	} else {
		o.Layout, o.Padding = "unrecognised", []string{}
	}
	for _, f := range optionFields {
		if f.off+f.len > len(data) {
			o.Absent = append(o.Absent, f.name)
		}
	}
	return o, nil
}
