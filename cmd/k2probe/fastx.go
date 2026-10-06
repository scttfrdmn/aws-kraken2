package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
)

// fastxReader is a minimal FASTA/FASTQ reader used only to cross-check that the Go side
// sees the same identifiers and bases as upstream's FastReader. It follows kseq's record
// rules (header to first whitespace; sequence lines until a line starting with '>', '@'
// or '+'; quality lines until they cover the sequence; trailing '\r' dropped). It is not
// internal/seqio.
type fastxReader struct {
	br      *bufio.Reader
	pending []byte // a header line read ahead
	id, seq []byte
	line    int
}

func newFastxReader(r io.Reader) *fastxReader {
	return &fastxReader{br: bufio.NewReaderSize(r, 1<<20)}
}

func (f *fastxReader) readLine() ([]byte, bool, error) {
	l, err := f.br.ReadSlice('\n')
	if err == bufio.ErrBufferFull {
		return nil, false, fmt.Errorf("line %d too long for the cross-check reader", f.line+1)
	}
	if len(l) == 0 && err == io.EOF {
		return nil, false, nil
	}
	if err != nil && err != io.EOF {
		return nil, false, err
	}
	f.line++
	l = bytes.TrimSuffix(l, []byte{'\n'})
	l = bytes.TrimSuffix(l, []byte{'\r'})
	return l, true, nil
}

// next returns false at end of input.
func (f *fastxReader) next() (bool, error) {
	h := f.pending
	f.pending = nil
	for h == nil {
		l, ok, err := f.readLine()
		if err != nil || !ok {
			return false, err
		}
		if len(l) > 0 && (l[0] == '>' || l[0] == '@') {
			h = append([]byte(nil), l...)
		}
	}
	i := bytes.IndexAny(h[1:], " \t\r\v\f")
	if i < 0 {
		i = len(h) - 1
	}
	f.id = append(f.id[:0], h[1:1+i]...)
	f.seq = f.seq[:0]
	for {
		l, ok, err := f.readLine()
		if err != nil {
			return false, err
		}
		if !ok {
			return true, nil
		}
		if len(l) > 0 && (l[0] == '>' || l[0] == '@') {
			f.pending = append([]byte(nil), l...)
			return true, nil
		}
		if len(l) > 0 && l[0] == '+' {
			q := 0
			for q < len(f.seq) {
				l, ok, err := f.readLine()
				if err != nil {
					return false, err
				}
				if !ok {
					break
				}
				q += len(l)
			}
			return true, nil
		}
		f.seq = append(f.seq, l...)
	}
}
