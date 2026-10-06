// Ported from DerrickWood/kraken2 scripts/kraken2 (compression handling) at
// 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package seqio

import (
	"bufio"
	"compress/bzip2"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/klauspost/compress/gzip"
)

// Compression is the decompression applied to every input file of a run.
type Compression uint8

// Compressions.
const (
	CompressionNone Compression = iota
	CompressionGzip
	CompressionBzip2
)

func (c Compression) String() string {
	switch c {
	case CompressionGzip:
		return "gzip"
	case CompressionBzip2:
		return "bzip2"
	}
	return "none"
}

// ErrBothCompressions is the wrapper's error for --gzip-compressed with --bzip2-compressed.
var ErrBothCompressions = errors.New("can't use both gzip and bzip2 compression flags")

// ResolveCompression ports the wrapper's choice. An explicit --gzip-compressed or
// --bzip2-compressed applies to every file. Otherwise the first file alone decides for all of
// them, by its first two bytes (1f 8b gzip, "BZ" bzip2), and only if it is a regular file;
// a pipe or other special file is read as is. A later file whose own compression differs is
// then caught by Reader.Prime (upstream classify's "input is X-compressed" error) or fails to
// decompress.
func ResolveCompression(gzipFlag, bzip2Flag bool, firstPath string) (Compression, error) {
	if gzipFlag && bzip2Flag {
		return CompressionNone, ErrBothCompressions
	}
	if gzipFlag {
		return CompressionGzip, nil
	}
	if bzip2Flag {
		return CompressionBzip2, nil
	}
	fi, err := os.Stat(firstPath)
	if err != nil || !fi.Mode().IsRegular() {
		return CompressionNone, nil
	}
	f, err := os.Open(firstPath)
	if err != nil {
		return CompressionNone, nil // the wrapper ignores this; opening the input reports it
	}
	defer f.Close()
	var magic [2]byte
	if n, _ := io.ReadFull(f, magic[:]); n < 2 {
		return CompressionNone, nil
	}
	switch {
	case magic[0] == 0x1f && magic[1] == 0x8b:
		return CompressionGzip, nil
	case magic[0] == 'B' && magic[1] == 'Z':
		return CompressionBzip2, nil
	}
	return CompressionNone, nil
}

// Open opens path with compression c. Compressed input is decompressed on its own goroutine,
// ahead of the reader, so the two files of a pair decompress in parallel.
//
// Upstream's wrapper pipes each file through `gzip -dc` / `bzip2 -dc` and ignores their exit
// status, so classify sees every byte the tool managed to decompress followed by a clean end
// of input. Open does the same: concatenated members are one stream; a decompression error
// (trailing zero padding or garbage after a member, a truncated member, or a file that is not
// compressed at all, which then reads as empty) ends the stream cleanly after the bytes
// decoded so far, and is only logged to DecompressLog.
func Open(path string, c Compression) (*Reader, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	switch c {
	case CompressionGzip:
		a := newAsyncReader(f, path, c, func(r io.Reader) (io.Reader, error) {
			return gzip.NewReader(r)
		})
		return &Reader{src: a, closer: a}, nil
	case CompressionBzip2:
		a := newAsyncReader(f, path, c, func(r io.Reader) (io.Reader, error) {
			return bzip2.NewReader(r), nil
		})
		return &Reader{src: a, closer: a}, nil
	}
	return &Reader{src: f, closer: f}, nil
}

// DecompressLog receives decompression errors, which (as with the wrapper's gzip -dc) end the
// input rather than failing the run.
var DecompressLog io.Writer = os.Stderr

const (
	asyncChunk = 1 << 20
	asyncDepth = 8
)

type chunk struct {
	b   []byte
	err error
}

// asyncReader runs a decompressor on its own goroutine, handing over 1 MiB chunks.
type asyncReader struct {
	f    *os.File
	path string
	comp Compression
	ch   chan chunk
	free chan []byte
	stop chan struct{}
	cur  []byte
	buf  []byte
	err  error
}

func newAsyncReader(f *os.File, path string, c Compression, wrap func(io.Reader) (io.Reader, error)) *asyncReader {
	a := &asyncReader{
		f:    f,
		path: path,
		comp: c,
		ch:   make(chan chunk, asyncDepth),
		free: make(chan []byte, asyncDepth+2),
		stop: make(chan struct{}),
	}
	go a.produce(wrap)
	return a
}

// end turns a decompression error into a clean end of input, logging it.
func (a *asyncReader) end(err error) {
	if err != io.EOF {
		select {
		case <-a.stop: // closed early; the error is our own doing
		default:
			fmt.Fprintf(DecompressLog, "seqio: %s: %s -dc: %v (input ends here)\n", a.path, a.comp, err)
		}
	}
	a.send(chunk{err: io.EOF})
}

func (a *asyncReader) produce(wrap func(io.Reader) (io.Reader, error)) {
	defer close(a.ch)
	src, err := wrap(bufio.NewReaderSize(a.f, 1<<20))
	if err != nil {
		a.end(err)
		return
	}
	for {
		var b []byte
		select {
		case b = <-a.free:
		default:
			b = make([]byte, asyncChunk)
		}
		b = b[:cap(b)]
		n := 0
		for n < len(b) && err == nil {
			var m int
			m, err = src.Read(b[n:])
			n += m
		}
		if n > 0 && !a.send(chunk{b: b[:n]}) {
			return
		}
		if err != nil {
			a.end(err)
			return
		}
	}
}

func (a *asyncReader) send(c chunk) bool {
	select {
	case a.ch <- c:
		return true
	case <-a.stop:
		return false
	}
}

func (a *asyncReader) Read(p []byte) (int, error) {
	for len(a.cur) == 0 {
		if a.err != nil {
			return 0, a.err
		}
		if a.buf != nil {
			select {
			case a.free <- a.buf:
			default:
			}
			a.buf = nil
		}
		c, ok := <-a.ch
		if !ok {
			if a.err == nil {
				a.err = io.EOF
			}
			continue
		}
		if c.err != nil {
			a.err = c.err
			continue
		}
		a.cur, a.buf = c.b, c.b
	}
	n := copy(p, a.cur)
	a.cur = a.cur[n:]
	return n, nil
}

func (a *asyncReader) Close() error {
	select {
	case <-a.stop:
	default:
		close(a.stop)
	}
	return a.f.Close()
}
