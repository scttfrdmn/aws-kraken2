package engine

// The emitter protocol: home nodes send each classified block to the sample's emitter node,
// which writes the outputs in read order and sum-reduces the report counters.
//
// One TCP connection per home node, opened by the home node:
//
//	hello     node → emitter   magic "AK2C" u32, version u32, rank u32, n u32, run u64
//	          emitter → node   magic u32, version u32, status u32 (0 = accepted)
//	then frames in both directions: type u32, length u64, payload
//	  Result   node → emitter  one block: file u32, seq u64, sequences/bases/classified u64,
//	                           fault count u32, first fault, error, then the five output
//	                           streams (--output, classified 1/2, unclassified 1/2), each
//	                           length-prefixed bytes
//	  Done     node → emitter  status i32, then the node's per-taxon counters (count u64, then
//	                           taxon/reads/kmers u64 each), then per input the blocks it sent and
//	                           their stream bytes (count u64, then blocks/bytes u64 each), after
//	                           its last block
//	  Progress emitter → node  file u32, next seq u64: everything before it is written; the
//	                           node may send blocks up to Window past it (flow control)
//	  Finish   emitter → node  status i32: no node needs any shard any more; exit
//
// Strings and streams are u64-length-prefixed bytes. All integers are little-endian.

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

// Frame types.
const (
	MsgResult   = 1
	MsgDone     = 2
	MsgProgress = 3
	MsgFinish   = 4
)

const (
	ctlMagic   = 0x43324b41 // "AK2C"
	ctlVersion = 1
	maxFrame   = 1 << 34
)

// Streams in a BlockResult.
const (
	StreamKraken = iota
	StreamC1
	StreamC2
	StreamU1
	StreamU2
	NumStreams
)

// BlockResult is one classified input block.
type BlockResult struct {
	File                         uint32
	Seq                          uint64
	Sequences, Bases, Classified uint64
	FaultCount                   uint32
	FaultFirst, Err              string
	Streams                      [NumStreams][]byte
}

// Count is one taxon's report counters.
type Count struct{ Taxon, Reads, Kmers uint64 }

// Done ends a node's results.
type Done struct {
	Status int32
	Counts []Count
	Files  []FileCount // per input, in order: what the node sent
}

// FileCount is what a node sent for one input: blocks, and the bytes of their output streams.
type FileCount struct{ Blocks, Bytes uint64 }

// Progress is the emitter's write position.
type Progress struct {
	File uint32
	Next uint64
}

func putU64(b []byte, v uint64) []byte { return binary.LittleEndian.AppendUint64(b, v) }
func putU32(b []byte, v uint32) []byte { return binary.LittleEndian.AppendUint32(b, v) }
func putBytes(b, s []byte) []byte      { return append(putU64(b, uint64(len(s))), s...) }

// AppendResult encodes r as a Result frame.
func AppendResult(b []byte, r *BlockResult) []byte {
	b = putU32(b, MsgResult)
	at := len(b)
	b = putU64(b, 0) // payload length, set below
	b = putU32(b, r.File)
	b = putU64(b, r.Seq)
	b = putU64(b, r.Sequences)
	b = putU64(b, r.Bases)
	b = putU64(b, r.Classified)
	b = putU32(b, r.FaultCount)
	b = putBytes(b, []byte(r.FaultFirst))
	b = putBytes(b, []byte(r.Err))
	for _, s := range r.Streams {
		b = putBytes(b, s)
	}
	binary.LittleEndian.PutUint64(b[at:], uint64(len(b)-at-8))
	return b
}

// AppendDone encodes d.
func AppendDone(b []byte, d *Done) []byte {
	b = putU32(b, MsgDone)
	b = putU64(b, uint64(4+8+24*len(d.Counts)+8+16*len(d.Files)))
	b = putU32(b, uint32(d.Status))
	b = putU64(b, uint64(len(d.Counts)))
	for _, c := range d.Counts {
		b = putU64(putU64(putU64(b, c.Taxon), c.Reads), c.Kmers)
	}
	b = putU64(b, uint64(len(d.Files)))
	for _, f := range d.Files {
		b = putU64(putU64(b, f.Blocks), f.Bytes)
	}
	return b
}

// AppendProgress encodes p.
func AppendProgress(b []byte, p Progress) []byte {
	return putU64(putU32(putU64(putU32(b, MsgProgress), 12), p.File), p.Next)
}

// AppendFinish encodes a Finish frame.
func AppendFinish(b []byte, status int32) []byte {
	return putU32(putU64(putU32(b, MsgFinish), 4), uint32(status))
}

// Frame is one decoded frame: exactly one of the pointers is set, by Type.
type Frame struct {
	Type     uint32
	Result   *BlockResult
	Done     *Done
	Progress *Progress
	Status   int32 // Finish
}

type reader struct {
	b   []byte
	err error
}

func (r *reader) u32() uint32 {
	if r.err != nil || len(r.b) < 4 {
		r.err = io.ErrUnexpectedEOF
		return 0
	}
	v := binary.LittleEndian.Uint32(r.b)
	r.b = r.b[4:]
	return v
}

func (r *reader) u64() uint64 {
	if r.err != nil || len(r.b) < 8 {
		r.err = io.ErrUnexpectedEOF
		return 0
	}
	v := binary.LittleEndian.Uint64(r.b)
	r.b = r.b[8:]
	return v
}

func (r *reader) bytes() []byte {
	n := r.u64()
	if r.err != nil || uint64(len(r.b)) < n {
		r.err = io.ErrUnexpectedEOF
		return nil
	}
	v := r.b[:n:n]
	r.b = r.b[n:]
	return v
}

// ReadFrame reads one frame. The returned byte slices alias a fresh buffer per frame.
func ReadFrame(br *bufio.Reader) (*Frame, error) {
	var h [12]byte
	if _, err := io.ReadFull(br, h[:]); err != nil {
		return nil, err
	}
	t := binary.LittleEndian.Uint32(h[0:])
	n := binary.LittleEndian.Uint64(h[4:])
	if n > maxFrame {
		return nil, fmt.Errorf("engine: frame of %d bytes", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(br, buf); err != nil {
		return nil, err
	}
	r := &reader{b: buf}
	f := &Frame{Type: t}
	switch t {
	case MsgResult:
		x := &BlockResult{File: r.u32(), Seq: r.u64(), Sequences: r.u64(), Bases: r.u64(), Classified: r.u64(),
			FaultCount: r.u32()}
		x.FaultFirst = string(r.bytes())
		x.Err = string(r.bytes())
		for i := range x.Streams {
			x.Streams[i] = r.bytes()
		}
		f.Result = x
	case MsgDone:
		d := &Done{Status: int32(r.u32())}
		k := r.u64()
		if k > n/24 {
			return nil, errors.New("engine: Done frame count too large")
		}
		d.Counts = make([]Count, k)
		for i := range d.Counts {
			d.Counts[i] = Count{r.u64(), r.u64(), r.u64()}
		}
		nf := r.u64()
		if nf > n/16 {
			return nil, errors.New("engine: Done frame file count too large")
		}
		d.Files = make([]FileCount, nf)
		for i := range d.Files {
			d.Files[i] = FileCount{r.u64(), r.u64()}
		}
		f.Done = d
	case MsgProgress:
		f.Progress = &Progress{File: r.u32(), Next: r.u64()}
	case MsgFinish:
		f.Status = int32(r.u32())
	default:
		return nil, fmt.Errorf("engine: unknown frame type %d", t)
	}
	if r.err != nil {
		return nil, fmt.Errorf("engine: frame type %d: %w", t, r.err)
	}
	if len(r.b) != 0 {
		return nil, fmt.Errorf("engine: frame type %d has %d trailing bytes", t, len(r.b))
	}
	return f, nil
}

// HelloControl is the node side of the control hello.
func HelloControl(rw io.ReadWriter, rank, n int, run uint64) error {
	var h [24]byte
	le := binary.LittleEndian
	le.PutUint32(h[0:], ctlMagic)
	le.PutUint32(h[4:], ctlVersion)
	le.PutUint32(h[8:], uint32(rank))
	le.PutUint32(h[12:], uint32(n))
	le.PutUint64(h[16:], run)
	if _, err := rw.Write(h[:]); err != nil {
		return err
	}
	var rb [12]byte
	if _, err := io.ReadFull(rw, rb[:]); err != nil {
		return err
	}
	if le.Uint32(rb[0:]) != ctlMagic || le.Uint32(rb[4:]) != ctlVersion {
		return errors.New("engine: emitter speaks another protocol")
	}
	if st := le.Uint32(rb[8:]); st != 0 {
		return fmt.Errorf("engine: emitter refused rank %d of %d (status %d)", rank, n, st)
	}
	return nil
}

// AcceptControl is the emitter side: it reads a hello and answers it, returning the rank.
func AcceptControl(rw io.ReadWriter, n int, run uint64) (int, error) {
	var h [24]byte
	if _, err := io.ReadFull(rw, h[:]); err != nil {
		return 0, err
	}
	le := binary.LittleEndian
	rank, hn := int(le.Uint32(h[8:])), int(le.Uint32(h[12:]))
	st := uint32(0)
	switch {
	case le.Uint32(h[0:]) != ctlMagic || le.Uint32(h[4:]) != ctlVersion:
		st = 1
	case hn != n || rank < 0 || rank >= n:
		st = 2
	case le.Uint64(h[16:]) != run:
		st = 4
	}
	var rb [12]byte
	le.PutUint32(rb[0:], ctlMagic)
	le.PutUint32(rb[4:], ctlVersion)
	le.PutUint32(rb[8:], st)
	if _, err := rw.Write(rb[:]); err != nil {
		return 0, err
	}
	if st != 0 {
		return 0, fmt.Errorf("engine: refused control hello (rank %d of %d, status %d)", rank, hn, st)
	}
	return rank, nil
}
