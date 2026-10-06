// Ported from DerrickWood/kraken2 src/fast_reader.{h,cc} at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2026, Ben Langmead <ben.langmead@gmail.com> and Rone Charles
// <rone_charles@fastmail.com>, part of Kraken 2 (Copyright 2013-2023, Derrick Wood
// <dwood@cs.jhu.edu>). MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package seqio reads FASTA and FASTQ the way upstream classify does at the pin.
//
// At the pin classify reads through FastReader (src/fast_reader.cc), not through kseq or
// BatchSequenceReader: a sequential step cuts raw bytes at an exact record boundary, and a
// parse step that may run concurrently splits the block into records in place. This package
// keeps that split. Reader.LoadBlock and Reader.LoadRecords are the sequential step (call them
// from one goroutine at a time per Reader); Block.Parse is the parallel step. NextBatch combines
// the two for callers that do not need the split.
//
// Record rules (identical to kseq's, and to upstream's): a record starts at a line beginning
// with '>' or '@'; anything before the first header is skipped; the sequence spans every line up
// to the next line beginning with '>', '@' or '+'; a '+' line starts a quality string, which
// takes as many lines as it needs to reach the length of the sequence. One trailing '\r' is
// dropped from every line. Whether a record is FASTQ is decided per record: it is FASTQ iff its
// quality string is non-empty and as long as its sequence.
package seqio

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"sync"
)

// Format is a record's (or stream's) sequence format.
type Format uint8

// Formats, in upstream's SequenceFormat order.
const (
	FormatAuto Format = iota
	FormatFASTA
	FormatFASTQ
)

func (f Format) String() string {
	switch f {
	case FormatFASTA:
		return "FASTA"
	case FormatFASTQ:
		return "FASTQ"
	}
	return "auto"
}

// Record is one sequence. Its slices alias the Block it was parsed from and stay valid as long
// as the caller keeps them; nothing reuses a Block's memory.
type Record struct {
	ID      []byte // header up to the first whitespace (space, \t, \r, \v, \f), without '@'/'>'
	Comment []byte // rest of the header after the one separating whitespace character; may be empty
	Seq     []byte // bases, all lines concatenated
	Qual    []byte // quality values; nil for FASTA. May be set on a FASTA record (see Fault).
	Format  Format // FormatFASTQ iff the quality string is non-empty and as long as Seq
}

// Header returns the header line as upstream re-emits it (without the leading marker):
// ID, then a space and Comment if Comment is non-empty.
func (r *Record) Header() []byte {
	if len(r.Comment) == 0 {
		return r.ID
	}
	h := make([]byte, 0, len(r.ID)+1+len(r.Comment))
	h = append(h, r.ID...)
	h = append(h, ' ')
	return append(h, r.Comment...)
}

// Upstream messages, verbatim.
const (
	msgUnrecognized = "sequence reader - unrecognized file format"
	msgCompressed   = "sequence reader - input is %s-compressed; decompress it before classifying"
	msgReadError    = "sequence reader - read error: "
)

// ErrUnrecognizedFormat is returned when the stream's first meaningful line is not a header.
var ErrUnrecognizedFormat = errors.New(msgUnrecognized)

const (
	primeBytes  = 1 << 16 // upstream PrimeStream reads one 64 KiB chunk
	refillChunk = 1 << 20 // upstream REFILL_CHUNK
	// DefaultBlockBytes is upstream's INPUT_BLOCK_BYTES.
	DefaultBlockBytes = 8 * 1024 * 1024
)

// Reader cuts one input stream into blocks of whole records. It is not safe for concurrent use;
// Blocks it returns may be parsed concurrently.
type Reader struct {
	src     io.Reader
	closer  io.Closer
	carry   []byte
	format  Format
	primed  bool
	hasData bool
	eof     bool
	err     error // a failure other than end of input; loads stop once set

	faults     int
	firstFault string
}

// NewReader reads records from r. Decompression, if any, must already have happened (see Open).
func NewReader(r io.Reader) *Reader { return &Reader{src: r} }

// Close closes the underlying input if the Reader was made by Open.
func (r *Reader) Close() error {
	if r.closer != nil {
		c := r.closer
		r.closer = nil
		return c.Close()
	}
	return nil
}

// Err returns the read error that stopped the stream, if any (never io.EOF).
func (r *Reader) Err() error { return r.err }

// Format returns the stream format settled by Prime (FormatAuto for an empty stream, or when
// no header occurs in the first 64 KiB). Output format is decided per record, not by this.
func (r *Reader) Format() Format { return r.format }

// Faults returns the number of malformed records parsed through NextBatch and the message for
// the first of them, as upstream reports it at the end of a run.
func (r *Reader) Faults() (int, string) { return r.faults, r.firstFault }

// Prime reads the first bytes of the stream and settles its format, as upstream PrimeStream.
// It reports whether the stream holds any bytes; upstream opens the classified/unclassified
// outputs only when the first input does. Errors: a read error, a compressed stream
// (compression must be removed before this point), or ErrUnrecognizedFormat. Loads call Prime
// themselves if needed.
func (r *Reader) Prime() (bool, error) {
	if r.primed {
		return r.hasData, r.err
	}
	r.primed = true
	chunk := make([]byte, primeBytes)
	n, err := io.ReadFull(r.src, chunk)
	if err != nil && err != io.EOF && err != io.ErrUnexpectedEOF {
		r.err = fmt.Errorf("%s%w", msgReadError, err)
		r.eof = true
		return false, r.err
	}
	if err != nil {
		r.eof = true // the stream ended inside the first chunk
	}
	if n == 0 {
		return false, nil
	}
	chunk = chunk[:n]
	if name := compressionName(chunk); name != "" {
		r.err = fmt.Errorf(msgCompressed, name)
		r.eof = true
		return false, r.err
	}
	// A UTF-8 byte order mark is not part of the data.
	if bytes.HasPrefix(chunk, []byte{0xef, 0xbb, 0xbf}) {
		chunk = chunk[3:]
	}
	r.carry = append(r.carry[:0], chunk...)
	r.hasData = true
	if err := detectFormat(&r.format, r.carry); err != nil {
		r.err = err
		r.eof = true
		return true, err
	}
	return true, nil
}

// compressionName names the compression whose magic number opens b, if any.
func compressionName(b []byte) string {
	switch {
	case len(b) >= 2 && b[0] == 0x1f && b[1] == 0x8b:
		return "gzip"
	case len(b) >= 3 && b[0] == 'B' && b[1] == 'Z' && b[2] == 'h':
		return "bzip2"
	case len(b) >= 6 && bytes.Equal(b[:6], []byte{0xfd, '7', 'z', 'X', 'Z', 0}):
		return "xz"
	case len(b) >= 4 && bytes.Equal(b[:4], []byte{0x28, 0xb5, 0x2f, 0xfd}):
		return "zstd"
	}
	return ""
}

// detectFormat ports upstream DetectFormat: the format is that of the first line whose first
// byte is a record marker. Only blank lines (spaces, tabs, CRs) and comment lines ('#' or ';',
// without NUL bytes) may precede it; anything else is ErrUnrecognizedFormat. As upstream, the
// line's first byte is tested, not its first non-blank byte.
func detectFormat(f *Format, buf []byte) error {
	if *f != FormatAuto {
		return nil
	}
	for i := 0; i < len(buf); {
		stop := len(buf)
		nl := bytes.IndexByte(buf[i:], '\n')
		if nl >= 0 {
			stop = i + nl
		}
		j := i
		for j < stop && (buf[j] == ' ' || buf[j] == '\t' || buf[j] == '\r') {
			j++
		}
		if j < stop {
			switch c := buf[i]; c {
			case '@':
				*f = FormatFASTQ
				return nil
			case '>':
				*f = FormatFASTA
				return nil
			case '#', ';':
				if bytes.IndexByte(buf[i:stop], 0) >= 0 {
					return ErrUnrecognizedFormat
				}
			default:
				return ErrUnrecognizedFormat
			}
		}
		if nl < 0 {
			break
		}
		i = stop + 1
	}
	return nil
}

// Block holds a whole number of raw records, cut from a stream. Parse splits them.
type Block struct {
	buf     []byte
	nl      []int // offsets of the newlines in buf
	scanned int   // bytes of buf already covered by nl
	records int   // whole records kept by the load
}

// Records returns the number of records the load kept, without parsing.
func (b *Block) Records() int { return b.records }

// Bytes returns the size of the raw block.
func (b *Block) Bytes() int { return len(b.buf) }

func (b *Block) scanNewlines() {
	p := b.scanned
	for p < len(b.buf) {
		k := bytes.IndexByte(b.buf[p:], '\n')
		if k < 0 {
			break
		}
		b.nl = append(b.nl, p+k)
		p += k + 1
	}
	b.scanned = len(b.buf)
}

func (b *Block) truncateIndex(keep int) {
	n := len(b.nl)
	for n > 0 && b.nl[n-1] >= keep {
		n--
	}
	b.nl = b.nl[:n]
	b.scanned = keep
}

// fill appends up to n bytes, reading until they arrive or the input ends.
func (r *Reader) fill(b *Block, n int) bool {
	if r.eof {
		return false
	}
	base := len(b.buf)
	if cap(b.buf)-base < n {
		nc := base + n + 1 // +1 for a final newline
		if 2*cap(b.buf) > nc {
			nc = 2 * cap(b.buf)
		}
		nb := make([]byte, base, nc)
		copy(nb, b.buf)
		b.buf = nb
	}
	b.buf = b.buf[:base+n]
	got := 0
	for got < n {
		m, err := r.src.Read(b.buf[base+got:])
		got += m
		if err != nil {
			if err != io.EOF {
				r.err = fmt.Errorf("%s%w", msgReadError, err)
			}
			r.eof = true
			break
		}
	}
	b.buf = b.buf[:base+got]
	if got == 0 || r.err != nil {
		r.eof = true
		return false
	}
	return true
}

// blockPool holds blocks handed back by Recycle, so steady-state loads reuse memory instead
// of allocating (and, on Linux, faulting in) a fresh multi-MB buffer per block, as upstream's
// per-thread FastReader reuses its buffer (issue #39).
var blockPool sync.Pool

// Recycle hands back a block whose records (and anything sliced from them) the caller no
// longer uses; a later LoadBlock may reuse its memory. Safe from any goroutine; nil is a no-op.
func Recycle(b *Block) {
	if b != nil {
		blockPool.Put(b)
	}
}

// reset starts a new block from the carried tail.
func (r *Reader) reset(extra int) *Block {
	need := len(r.carry) + extra + 1
	b, _ := blockPool.Get().(*Block)
	if b != nil && cap(b.buf) >= need {
		*b = Block{buf: b.buf[:0], nl: b.nl[:0]}
	} else {
		b = &Block{buf: make([]byte, 0, need)}
	}
	b.buf = append(b.buf, r.carry...)
	r.carry = r.carry[:0]
	return b
}

func (r *Reader) setCarry(b *Block, keep int) {
	if keep < len(b.buf) {
		// A failed stream is never read again, so a refused tail is dropped.
		if r.err == nil {
			r.carry = append(r.carry[:0], b.buf[keep:]...)
		}
		b.buf = b.buf[:keep]
		b.truncateIndex(keep)
	}
}

// recordScan walks lines with kseq's record rules, counting complete records.
type recordScan struct {
	nextLine int
	state    int // 0 seeking a header, 1 in sequence, 2 in quality
	seqLen   int
	qualsLen int
	count    int
	lastEnd  int
	priorEnd int
	limit    int
	limitSet bool
}

func (s *recordScan) add(end int) { s.priorEnd = s.lastEnd; s.lastEnd = end; s.count++ }
func (s *recordScan) full() bool  { return s.limitSet && s.count >= s.limit }

func lineLen(buf []byte, start, stop int) int {
	if stop > start && buf[stop-1] == '\r' {
		stop--
	}
	return stop - start
}

func (b *Block) collectRecordEnds(s *recordScan) {
	buf := b.buf
	nlines := len(b.nl)
	for ; s.nextLine < nlines; s.nextLine++ {
		// Fast path for the common four-line FASTQ record.
		for s.state == 0 && s.nextLine+3 < nlines {
			j := s.nextLine
			s0 := 0
			if j > 0 {
				s0 = b.nl[j-1] + 1
			}
			e0, e1, e2, e3 := b.nl[j], b.nl[j+1], b.nl[j+2], b.nl[j+3]
			s1, s2, s3 := e0+1, e1+1, e2+1
			if s0 >= e0 || buf[s0] != '@' || s2 >= e2 || buf[s2] != '+' {
				break
			}
			len1 := e1 - s1
			if len1 > 0 && buf[e1-1] == '\r' {
				len1--
			}
			if len1 > 0 && (buf[s1] == '>' || buf[s1] == '@' || buf[s1] == '+') {
				break
			}
			len3 := e3 - s3
			if len3 > 0 && buf[e3-1] == '\r' {
				len3--
			}
			if len3 < len1 {
				break
			}
			s.add(e3 + 1)
			s.nextLine += 4
			if s.full() {
				return
			}
		}
		if s.nextLine >= nlines {
			break
		}
		start := 0
		if s.nextLine > 0 {
			start = b.nl[s.nextLine-1] + 1
		}
		stop := b.nl[s.nextLine]
		n := lineLen(buf, start, stop)
		var c byte
		if n > 0 {
			c = buf[start]
		}
		if s.state == 1 && (c == '>' || c == '@') {
			s.add(start)
			s.state = 0
			if s.full() {
				return // this header starts the next record, so it is not consumed
			}
		}
		if s.state == 0 {
			if c == '>' || c == '@' {
				s.state = 1
				s.seqLen, s.qualsLen = 0, 0
			}
			continue
		}
		if s.state == 1 {
			if c == '+' {
				s.state = 2
			} else {
				s.seqLen += n
			}
			continue
		}
		s.qualsLen += n
		if s.qualsLen >= s.seqLen {
			s.add(stop + 1)
			s.state = 0
			if s.full() {
				s.nextLine++
				return
			}
		}
	}
}

// LoadBlock is upstream FastReader::LoadBlock: it pulls about targetBytes, then trims back to
// the last complete record. recordMultiple (1 or 2) forces the kept record count to a multiple
// of it, so interleaved mates are never split. It returns nil when the input is exhausted or
// has failed (see Err).
func (r *Reader) LoadBlock(targetBytes, recordMultiple int) *Block {
	if _, err := r.Prime(); err != nil {
		return nil
	}
	if r.err != nil {
		return nil
	}
	if recordMultiple < 1 {
		recordMultiple = 1
	}
	b := r.reset(targetBytes)
	got := r.fill(b, targetBytes)
	if !got && len(b.buf) == 0 {
		return nil
	}
	var scan recordScan
	keep, recs := 0, 0
	for {
		if !got && r.err == nil && len(b.buf) > 0 && b.buf[len(b.buf)-1] != '\n' {
			b.buf = append(b.buf, '\n')
		}
		b.scanNewlines()
		b.collectRecordEnds(&scan)
		if got || r.err != nil {
			recs = scan.count &^ (recordMultiple - 1)
			switch {
			case recs == 0:
				keep = 0
			case recs == scan.count:
				keep = scan.lastEnd
			default:
				keep = scan.priorEnd
			}
		} else {
			recs = scan.count
			if scan.state != 0 {
				recs++
			}
			keep = len(b.buf)
		}
		if keep > 0 || !got {
			break
		}
		got = r.fill(b, targetBytes)
	}
	r.setCarry(b, keep)
	// Blank or comment lines after the last record are not a block.
	if recs == 0 {
		b.buf = b.buf[:0]
	}
	b.records = recs
	if len(b.buf) == 0 {
		return nil
	}
	return b
}

// LoadRecords is upstream FastReader::LoadRecords: it pulls exactly n records (fewer only at
// the end of the input), for the second mate of a pair so the two files stay in step. It
// returns nil when nothing is left. A non-nil Block may hold zero records (only blank or
// comment lines remained).
func (r *Reader) LoadRecords(n int) *Block {
	if _, err := r.Prime(); err != nil {
		return nil
	}
	if r.err != nil || n <= 0 {
		return nil
	}
	b := r.reset(0)
	live := true
	scan := recordScan{limit: n, limitSet: true}
	b.scanNewlines()
	b.collectRecordEnds(&scan)
	for scan.count < n && live {
		live = r.fill(b, refillChunk)
		b.scanNewlines()
		b.collectRecordEnds(&scan)
	}
	if len(b.buf) == 0 {
		return nil
	}
	if !live && r.err == nil && b.buf[len(b.buf)-1] != '\n' {
		b.buf = append(b.buf, '\n')
		b.scanNewlines()
		b.collectRecordEnds(&scan)
	}
	keep, recs := 0, 0
	switch {
	case scan.count >= n:
		keep, recs = scan.lastEnd, n
	case r.err != nil:
		recs = scan.count
		if recs > 0 {
			keep = scan.lastEnd
		}
	default:
		keep = len(b.buf)
		recs = scan.count
		if scan.state != 0 {
			recs++
		}
	}
	r.setCarry(b, keep)
	b.records = recs
	if len(b.buf) == 0 {
		return nil
	}
	return b
}

// Fault describes the malformed records of a block: those whose quality string and sequence
// disagree in length. Upstream still emits and classifies them (written out as FASTA), and
// reports the first one, with a count, at the end of the run with exit status EX_DATAERR (65).
type Fault struct {
	Count int
	First string // upstream's message for the first malformed record, or ""
}

func faultMessage(id []byte, verb string, seqLen, qualsLen int) string {
	if len(id) > 200 {
		id = id[:200]
	}
	return fmt.Sprintf("sequence reader - record '%s' %s %d bases and %d quality values", id, verb, seqLen, qualsLen)
}

func isHeaderSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\v' || c == '\f'
}

// Parse splits the block into records in place (upstream FastReader::Parse). It may run
// concurrently with loads and with other Blocks' Parse. Call it once.
func (b *Block) Parse() ([]Record, Fault) {
	buf := b.buf
	recs := make([]Record, 0, b.records)
	var fault Fault
	trim := func(s, e int) int {
		if e > s && buf[e-1] == '\r' {
			e--
		}
		return e
	}
	emit := func(v Record) {
		if len(v.Qual) > 0 {
			v.Format = FormatFASTQ
		} else {
			v.Format = FormatFASTA
		}
		recs = append(recs, v)
	}
	faulty := func(v Record, verb string) {
		fault.Count++
		if fault.First == "" {
			fault.First = faultMessage(v.ID, verb, len(v.Seq), len(v.Qual))
		}
		emit(v)
		recs[len(recs)-1].Format = FormatFASTA
	}

	state := 0
	var v Record
	seqStart, seqDst := -1, 0
	qualStart, qualDst := -1, 0
	for j := range b.nl {
		ls := 0
		if j > 0 {
			ls = b.nl[j-1] + 1
		}
		le := trim(ls, b.nl[j])
		n := le - ls
		var c byte
		if n > 0 {
			c = buf[ls]
		}
		if state == 1 && (c == '>' || c == '@') {
			v.Qual = nil
			emit(v)
			state = 0
		}
		if state == 0 {
			if c != '>' && c != '@' {
				continue
			}
			v = Record{}
			hs, he := ls+1, le
			p := hs
			for p < he && !isHeaderSpace(buf[p]) {
				p++
			}
			v.ID = buf[hs:p:p]
			if p < he {
				p++ // the one separator; further whitespace stays in the comment
			}
			ce := trim(p, he)
			v.Comment = buf[p:ce:ce]
			v.Seq = buf[ls:ls:ls] // empty, non-nil
			seqStart, qualStart = -1, -1
			state = 1
			continue
		}
		if state == 1 {
			if c == '+' {
				state = 2
				continue
			}
			if seqStart < 0 {
				seqStart, seqDst = ls, ls
			}
			if seqDst != ls {
				copy(buf[seqDst:], buf[ls:le])
			}
			seqDst += n
			v.Seq = buf[seqStart:seqDst:seqDst]
			continue
		}
		if qualStart < 0 {
			qualStart, qualDst = ls, ls // a line is read here even for an empty read
		}
		if qualDst != ls {
			copy(buf[qualDst:], buf[ls:le])
		}
		qualDst += n
		v.Qual = buf[qualStart:qualDst:qualDst]
		if len(v.Qual) >= len(v.Seq) {
			if len(v.Qual) != len(v.Seq) {
				faulty(v, "has")
			} else {
				emit(v)
			}
			state = 0
		}
	}
	switch state {
	case 1:
		v.Qual = nil
		emit(v)
	case 2:
		if len(v.Qual) != len(v.Seq) {
			faulty(v, "ends with")
		} else {
			emit(v)
		}
	}
	return recs, fault
}

// NextBatch returns up to maxRecords records, in input order. At the end of the input it
// returns io.EOF, or the read error that stopped the stream. Malformed records are returned
// like the rest and counted in Faults.
func (r *Reader) NextBatch(maxRecords int) ([]Record, error) {
	for {
		b := r.LoadRecords(maxRecords)
		if b == nil {
			return nil, r.endErr()
		}
		recs, f := b.Parse()
		r.addFault(f)
		if len(recs) > 0 {
			return recs, nil
		}
	}
}

func (r *Reader) addFault(f Fault) {
	if f.Count > 0 && r.firstFault == "" {
		r.firstFault = f.First
	}
	r.faults += f.Count
}

func (r *Reader) endErr() error {
	if r.err != nil {
		return r.err
	}
	return io.EOF
}
