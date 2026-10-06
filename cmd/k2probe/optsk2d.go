package main

import (
	"encoding/binary"
	"fmt"
	"os"
)

// indexOptions is upstream's IndexOptions (src/kraken2_data.h), as classify.cc load_index
// reads it: a zero-initialised 64-byte struct overwritten by the raw bytes of opts.k2d, so a
// short (pre-2.0.8) file leaves revcom_version, db_version and db_type at 0.
//
// Temporary local helper: internal/kdb (ReadOptions) replaces it at merge.
type indexOptions struct {
	K, L                       uint64
	SpacedSeedMask, ToggleMask uint64
	DNA                        bool
	MinimumAcceptableHashValue uint64
	RevcomVersion              int32
	DBVersion, DBType          int32
	FileSize                   int64
}

func readIndexOptions(path string) (indexOptions, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return indexOptions{}, err
	}
	if len(b) > 64 {
		return indexOptions{}, fmt.Errorf("%s: %d bytes, larger than IndexOptions (64)", path, len(b))
	}
	var s [64]byte
	copy(s[:], b)
	le := binary.LittleEndian
	return indexOptions{
		K:                          le.Uint64(s[0:]),
		L:                          le.Uint64(s[8:]),
		SpacedSeedMask:             le.Uint64(s[16:]),
		ToggleMask:                 le.Uint64(s[24:]),
		DNA:                        s[32] != 0,
		MinimumAcceptableHashValue: le.Uint64(s[40:]),
		RevcomVersion:              int32(le.Uint32(s[48:])),
		DBVersion:                  int32(le.Uint32(s[52:])),
		DBType:                     int32(le.Uint32(s[56:])),
		FileSize:                   int64(len(b)),
	}, nil
}
