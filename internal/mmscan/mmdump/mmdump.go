// Package mmdump reads the "K2MMDMP1" stream written by the upstream/mm_dump.cc oracle
// harness: upstream's MinimizerScanner output, per record, for comparison with
// internal/mmscan. It is test and probe tooling, not part of the classifier.
//
// Stream (little-endian):
//
//	header: "K2MMDMP1", k u64, l u64, spaced_seed_mask u64, toggle_mask u64, dna_db u8,
//	        minimum_acceptable_hash_value u64, revcom_version i32, db_version i32,
//	        db_type i32, opts_filesize u64, range_mode u8
//	record: tag u8 (=1), file_idx u8, header_len u32, header, seq_len u32, seq,
//	        start u64, finish u64, n u32, n x (minimizer u64, ambiguous u8)
//	end:    tag u8 (=0), records u64, minimizers u64
package mmdump

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/scttfrdmn/aws-kraken2/internal/mmscan"
)

// Header is the effective scanner configuration the harness used.
type Header struct {
	K, L                       uint64
	SpacedSeedMask, ToggleMask uint64
	DNA                        bool
	MinimumAcceptableHashValue uint64
	RevcomVersion              int32
	DBVersion, DBType          int32
	OptsFileSize               uint64
	RangeMode                  bool
}

// Record is one LoadSequence + NextMinimizer loop.
type Record struct {
	FileIdx       uint8
	Header        []byte
	Seq           []byte
	Start, Finish uint64 // as passed to LoadSequence; Finish may be SIZE_MAX
	Minimizers    []uint64
	Ambiguous     []bool
}

// Reader decodes a dump. Record buffers are reused between calls to Next.
type Reader struct {
	r      *bufio.Reader
	Header Header
	rec    Record
	buf    [9]byte
	// Totals from the end marker, valid once Next has returned io.EOF.
	Records, Minimizers uint64
}

// NewReader reads the stream header.
func NewReader(r io.Reader) (*Reader, error) {
	d := &Reader{r: bufio.NewReaderSize(r, 1<<20)}
	magic := make([]byte, 8)
	if _, err := io.ReadFull(d.r, magic); err != nil {
		return nil, fmt.Errorf("mmdump: header: %w", err)
	}
	if string(magic) != "K2MMDMP1" {
		return nil, fmt.Errorf("mmdump: bad magic %q", magic)
	}
	h := &d.Header
	var err error
	rd64 := func() uint64 {
		var v uint64
		if err == nil {
			v, err = d.u64()
		}
		return v
	}
	rd32 := func() int32 {
		var v uint32
		if err == nil {
			v, err = d.u32()
		}
		return int32(v)
	}
	rd8 := func() uint8 {
		var v uint8
		if err == nil {
			v, err = d.r.ReadByte()
		}
		return v
	}
	h.K, h.L, h.SpacedSeedMask, h.ToggleMask = rd64(), rd64(), rd64(), rd64()
	h.DNA = rd8() != 0
	h.MinimumAcceptableHashValue = rd64()
	h.RevcomVersion, h.DBVersion, h.DBType = rd32(), rd32(), rd32()
	h.OptsFileSize = rd64()
	h.RangeMode = rd8() != 0
	if err != nil {
		return nil, fmt.Errorf("mmdump: header: %w", noEOF(err))
	}
	return d, nil
}

func noEOF(err error) error {
	if err == io.EOF {
		return io.ErrUnexpectedEOF
	}
	return err
}

func (d *Reader) u64() (uint64, error) {
	if _, err := io.ReadFull(d.r, d.buf[:8]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint64(d.buf[:8]), nil
}

func (d *Reader) u32() (uint32, error) {
	if _, err := io.ReadFull(d.r, d.buf[:4]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(d.buf[:4]), nil
}

func (d *Reader) bytes(dst []byte) ([]byte, error) {
	n, err := d.u32()
	if err != nil {
		return nil, err
	}
	if cap(dst) < int(n) {
		dst = make([]byte, n)
	}
	dst = dst[:n]
	_, err = io.ReadFull(d.r, dst)
	return dst, err
}

// Next returns the next record, or io.EOF after the end marker. A stream that ends
// without the end marker is an error (a harness that died mid-run).
func (d *Reader) Next() (*Record, error) {
	tag, err := d.r.ReadByte()
	if err != nil {
		return nil, fmt.Errorf("mmdump: missing end marker: %w", noEOF(err))
	}
	if tag == 0 {
		if d.Records, err = d.u64(); err == nil {
			d.Minimizers, err = d.u64()
		}
		if err != nil {
			return nil, fmt.Errorf("mmdump: end marker: %w", noEOF(err))
		}
		return nil, io.EOF
	}
	if tag != 1 {
		return nil, fmt.Errorf("mmdump: bad record tag %d", tag)
	}
	rec := &d.rec
	if rec.FileIdx, err = d.r.ReadByte(); err != nil {
		return nil, d.recErr(err)
	}
	if rec.Header, err = d.bytes(rec.Header); err != nil {
		return nil, d.recErr(err)
	}
	if rec.Seq, err = d.bytes(rec.Seq); err != nil {
		return nil, d.recErr(err)
	}
	if rec.Start, err = d.u64(); err != nil {
		return nil, d.recErr(err)
	}
	if rec.Finish, err = d.u64(); err != nil {
		return nil, d.recErr(err)
	}
	n, err := d.u32()
	if err != nil {
		return nil, d.recErr(err)
	}
	rec.Minimizers = rec.Minimizers[:0]
	rec.Ambiguous = rec.Ambiguous[:0]
	for i := uint32(0); i < n; i++ {
		if _, err := io.ReadFull(d.r, d.buf[:9]); err != nil {
			return nil, d.recErr(err)
		}
		rec.Minimizers = append(rec.Minimizers, binary.LittleEndian.Uint64(d.buf[:8]))
		rec.Ambiguous = append(rec.Ambiguous, d.buf[8] != 0)
	}
	return rec, nil
}

func (d *Reader) recErr(err error) error {
	return errors.Join(errors.New("mmdump: truncated record"), noEOF(err))
}

// NewScanner builds the Go scanner for the configuration the harness used.
func (h Header) NewScanner() (*mmscan.Scanner, error) {
	return mmscan.New(int(h.K), int(h.L), h.SpacedSeedMask, h.ToggleMask, h.DNA, int(h.RevcomVersion))
}

// Mismatch describes the first difference between a record and the Go scanner.
type Mismatch struct {
	Index               int // minimizer ordinal within the record
	Want, Got           uint64
	WantAmbig, GotAmbig bool
	WantCount           int  // upstream's minimizer count for the record
	WantEnded, GotEnded bool // one stream ended at Index
	Batch               bool // the mismatch is in AppendMinimizers' stream, not Next's
}

func (m *Mismatch) String() string {
	if m.Batch {
		return fmt.Sprintf("AppendMinimizers: minimizer #%d: upstream %#016x ambig=%v, Go %#016x (count upstream %d)",
			m.Index, m.Want, m.WantAmbig, m.Got, m.WantCount)
	}
	switch {
	case m.GotEnded:
		return fmt.Sprintf("minimizer #%d: Go stream ended; upstream has %#016x ambig=%v (upstream count %d)",
			m.Index, m.Want, m.WantAmbig, m.WantCount)
	case m.WantEnded:
		return fmt.Sprintf("minimizer #%d: upstream stream ended (count %d); Go has %#016x ambig=%v",
			m.Index, m.WantCount, m.Got, m.GotAmbig)
	}
	return fmt.Sprintf("minimizer #%d: upstream %#016x ambig=%v, Go %#016x ambig=%v",
		m.Index, m.Want, m.WantAmbig, m.Got, m.GotAmbig)
}

// Check rescans rec.Seq over [rec.Start, rec.Finish) with s and compares the stream.
// It returns nil on an exact match (values, ambiguous flags and length). For a record over the
// whole sequence (the way classify scans), it then also checks AppendMinimizers, the batched
// form classify uses: its output must be upstream's stream with ambiguous positions as
// mmscan.Ambiguous.
func Check(s *mmscan.Scanner, rec *Record) *Mismatch {
	if m := checkNext(s, rec); m != nil {
		return m
	}
	n := uint64(len(rec.Seq))
	if rec.Start != 0 || rec.Finish < n {
		return nil
	}
	got := s.AppendMinimizers(rec.Seq, nil)
	for i, want := range rec.Minimizers {
		w := want
		if rec.Ambiguous[i] {
			w = mmscan.Ambiguous
		}
		if i >= len(got) || got[i] != w {
			g := uint64(0)
			if i < len(got) {
				g = got[i]
			}
			return &Mismatch{Index: i, Want: want, WantAmbig: rec.Ambiguous[i], Got: g,
				WantCount: len(rec.Minimizers), Batch: true}
		}
	}
	if len(got) != len(rec.Minimizers) {
		return &Mismatch{Index: len(rec.Minimizers), Got: got[len(rec.Minimizers)],
			WantCount: len(rec.Minimizers), Batch: true}
	}
	return nil
}

func checkNext(s *mmscan.Scanner, rec *Record) *Mismatch {
	n := uint64(len(rec.Seq))
	finish := min(rec.Finish, n) // upstream clamps finish_ to str_len_
	start := min(rec.Start, n+1) // any start > finish behaves the same
	s.LoadRange(rec.Seq, int(start), int(finish))
	for i := 0; ; i++ {
		mm, amb, ok := s.Next()
		if !ok {
			if i < len(rec.Minimizers) {
				return &Mismatch{Index: i, Want: rec.Minimizers[i], WantAmbig: rec.Ambiguous[i],
					WantCount: len(rec.Minimizers), GotEnded: true}
			}
			return nil
		}
		if i >= len(rec.Minimizers) {
			return &Mismatch{Index: i, Got: mm, GotAmbig: amb, WantCount: len(rec.Minimizers), WantEnded: true}
		}
		if mm != rec.Minimizers[i] || amb != rec.Ambiguous[i] {
			return &Mismatch{Index: i, Want: rec.Minimizers[i], WantAmbig: rec.Ambiguous[i],
				Got: mm, GotAmbig: amb, WantCount: len(rec.Minimizers)}
		}
	}
}
