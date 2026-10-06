// Ported from DerrickWood/kraken2 src/classify.cc (ProcessFiles input layouts, MatesAgree,
// MaskLowQualityBases) at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package seqio

import (
	"bytes"
	"errors"
	"io"
)

// ErrMateCountMismatch is returned at the end of a two-file paired run whose files hold
// different numbers of records. Upstream classifies the pairs up to the end of the shorter
// file, writes all output, then exits with EX_DATAERR (65) and this text as part of its message.
var ErrMateCountMismatch = errors.New("the two mate files hold different numbers of records, " +
	"so only the pairs up to the end of the shorter one were classified")

// PairedReader reads mate pairs, either from two files in lockstep (upstream -P, the wrapper's
// --paired) or from one interleaved file (upstream classify -S; the wrapper at the pin has no
// flag for it). Not safe for concurrent use; Blocks it returns may be parsed concurrently.
type PairedReader struct {
	r1, r2      *Reader
	interleaved bool
	mismatch    bool
	done        bool
	endChecked  bool

	faults     int
	firstFault string
}

// NewPairedReader pairs record i of r1 with record i of r2.
func NewPairedReader(r1, r2 *Reader) *PairedReader { return &PairedReader{r1: r1, r2: r2} }

// NewInterleavedReader pairs records 2i and 2i+1 of r. An odd final record is dropped silently,
// as upstream does.
func NewInterleavedReader(r *Reader) *PairedReader {
	return &PairedReader{r1: r, interleaved: true}
}

// Close closes both inputs.
func (p *PairedReader) Close() error {
	err := p.r1.Close()
	if p.r2 != nil {
		if e := p.r2.Close(); err == nil {
			err = e
		}
	}
	return err
}

// Prime primes both inputs (upstream primes both before reading) and reports whether the first
// holds any bytes, which is what gates opening the outputs upstream.
func (p *PairedReader) Prime() (bool, error) {
	has, err := p.r1.Prime()
	if err != nil {
		return has, err
	}
	if p.r2 != nil {
		if _, err := p.r2.Prime(); err != nil {
			return has, err
		}
	}
	return has, nil
}

// LoadBlocks is the sequential step of upstream's TWO_FILES and INTERLEAVED layouts: a block of
// about targetBytes from the first input, then exactly as many records from the second (b2 is
// nil when interleaved). ok is false at the end; then call Err. Pass the blocks to PairBlocks
// (possibly on another goroutine).
func (p *PairedReader) LoadBlocks(targetBytes int) (b1, b2 *Block, ok bool) {
	if p.done {
		return nil, nil, false
	}
	if _, err := p.Prime(); err != nil {
		p.done = true
		return nil, nil, false
	}
	if p.interleaved {
		b1 = p.r1.LoadBlock(targetBytes, 2)
		if b1 == nil {
			p.done = true
			return nil, nil, false
		}
		return b1, nil, true
	}
	b1 = p.r1.LoadBlock(targetBytes, 1)
	if b1 == nil {
		p.done = true
		return nil, nil, false
	}
	return p.loadMates(b1)
}

func (p *PairedReader) loadMates(b1 *Block) (*Block, *Block, bool) {
	b2 := p.r2.LoadRecords(b1.Records())
	// A second file that runs out first leaves first mates unpaired.
	if b2 == nil || b2.Records() != b1.Records() {
		p.mismatch = true
	}
	if b2 == nil {
		p.done = true
		return nil, nil, false
	}
	return b1, b2, true
}

// PairBlocks parses blocks from LoadBlocks into mate slices of equal length: mates1[i] pairs
// with mates2[i]. Pairs beyond the shorter mate block are dropped, as upstream does.
func PairBlocks(b1, b2 *Block) (mates1, mates2 []Record, f Fault) {
	recs1, f1 := b1.Parse()
	if b2 == nil { // interleaved
		n := len(recs1) / 2
		mates1 = make([]Record, n)
		mates2 = make([]Record, n)
		for i := 0; i < n; i++ {
			mates1[i], mates2[i] = recs1[2*i], recs1[2*i+1]
		}
		return mates1, mates2, f1
	}
	recs2, f2 := b2.Parse()
	n := min(len(recs1), len(recs2))
	f = f1
	if f.First == "" {
		f.First = f2.First
	}
	f.Count += f2.Count
	return recs1[:n], recs2[:n], f
}

// NextBatch returns up to maxRecords pairs in input order. At the end it returns io.EOF, or an
// error: a read error, or ErrMateCountMismatch (after every pair up to the shorter file has
// been returned).
func (p *PairedReader) NextBatch(maxRecords int) (mates1, mates2 []Record, err error) {
	for {
		b1, b2, ok := p.nextRecords(maxRecords)
		if !ok {
			return nil, nil, p.Err()
		}
		m1, m2, f := PairBlocks(b1, b2)
		if f.Count > 0 && p.firstFault == "" {
			p.firstFault = f.First
		}
		p.faults += f.Count
		if len(m1) > 0 {
			return m1, m2, nil
		}
	}
}

func (p *PairedReader) nextRecords(maxRecords int) (*Block, *Block, bool) {
	if p.done {
		return nil, nil, false
	}
	if _, err := p.Prime(); err != nil {
		p.done = true
		return nil, nil, false
	}
	if p.interleaved {
		b1 := p.r1.LoadRecords(2 * maxRecords)
		if b1 == nil || b1.Records() == 0 {
			p.done = true
			return nil, nil, false
		}
		return b1, nil, true
	}
	b1 := p.r1.LoadRecords(maxRecords)
	if b1 == nil || b1.Records() == 0 { // trailing blank/comment lines are not a block
		p.done = true
		return nil, nil, false
	}
	return p.loadMates(b1)
}

// Faults returns the malformed-record count and first message seen through NextBatch.
func (p *PairedReader) Faults() (int, string) { return p.faults, p.firstFault }

// Err returns the reason reading stopped, once LoadBlocks or NextBatch has reported the end:
// io.EOF for a clean end, a read error, or ErrMateCountMismatch. As upstream, once the run is
// over a first file that ran out first is detected by reading one more record from the second.
func (p *PairedReader) Err() error {
	if err := p.r1.Err(); err != nil {
		return err
	}
	if p.r2 == nil {
		return io.EOF
	}
	if err := p.r2.Err(); err != nil {
		return err
	}
	if p.done && !p.mismatch && !p.endChecked {
		p.endChecked = true
		if rest := p.r2.LoadRecords(1); rest != nil && rest.Records() > 0 {
			p.mismatch = true
		}
		if err := p.r2.Err(); err != nil {
			return err
		}
	}
	if p.mismatch {
		return ErrMateCountMismatch
	}
	return io.EOF
}

// MatesAgree is upstream's pair-order check (classify -c; the wrapper never passes it): mate
// identifiers agree once any '/' suffix is discounted. Names without a '/' must match exactly;
// names with one must agree up to a '/' at the same position.
func MatesAgree(a, b *Record) bool {
	sa := bytes.IndexByte(a.ID, '/')
	sb := bytes.IndexByte(b.ID, '/')
	if sa < 0 && sb < 0 {
		return bytes.Equal(a.ID, b.ID)
	}
	if sa < 0 || sb < 0 || sa != sb {
		return false
	}
	return bytes.Equal(a.ID[:sa], b.ID[:sb])
}

// MaskLowQuality is upstream MaskLowQualityBases, which lives in classify.cc's per-read loop,
// not in the reader: with --minimum-base-quality Q > 0, every base whose quality value minus
// '!' is below Q is overwritten with 'x' in place, before classification and therefore also in
// the classified/unclassified output. It applies to any record that carries quality values,
// bounded by the shorter of sequence and quality (a malformed record is masked over the part
// its quality covers). Quality bytes are treated as C signed char, as on x86-64 and Apple
// arm64 (bytes >= 0x80 are negative and always masked); on Linux arm64, where char is
// unsigned, upstream would not mask them. Real FASTQ never contains such bytes.
func MaskLowQuality(r *Record, minQ int) {
	if minQ <= 0 || r.Qual == nil {
		return
	}
	n := min(len(r.Seq), len(r.Qual))
	for i := 0; i < n; i++ {
		if int(int8(r.Qual[i]))-'!' < minQ {
			r.Seq[i] = 'x'
		}
	}
}
