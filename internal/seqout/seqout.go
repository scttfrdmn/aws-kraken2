// Ported from DerrickWood/kraken2 src/classify.cc (WriteSeqView, InitializeOutputs, the
// classified/unclassified emission in ProcessFiles) and src/utilities.cc (SplitString) at
// 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package seqout writes --classified-out and --unclassified-out byte-identically to upstream.
//
// Output format, per record (not per file): FASTQ records are written as
//
//	@<id>[ kraken:taxid|<external taxid>][ <comment>]\n<seq>\n+\n<qual>\n
//
// and FASTA records (including FASTQ records whose quality is empty or malformed) as
//
//	><id>[ kraken:taxid|<external taxid>][ <comment>]\n<seq>\n
//
// with the sequence on one line whatever its input wrapping, and '\n' line ends whatever the
// input's. The taxid suffix is added only to classified reads, so unclassified reads keep their
// header as read (there is no "kraken:taxid|0"). It goes after the identifier and before the
// comment. In paired mode both mates are written, each to the _1 / _2 file of its class, with the
// same suffix; mate identifiers are written as read (a trailing /1 or /2 is kept). Bases masked by
// --minimum-base-quality are written masked ('x').
//
// Ordering: workers format into their own Batch, with no shared state; Writers.Write must then
// see the batches in input order. Ordered does that reordering on one goroutine.
package seqout

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/scttfrdmn/aws-kraken2/internal/seqio"
)

// AppendRecord appends r as upstream WriteSeqView does, with suffix after the identifier.
func AppendRecord(dst []byte, r *seqio.Record, suffix []byte) []byte {
	fastq := r.Format == seqio.FormatFASTQ
	if fastq {
		dst = append(dst, '@')
	} else {
		dst = append(dst, '>')
	}
	dst = append(dst, r.ID...)
	dst = append(dst, suffix...)
	if len(r.Comment) > 0 {
		dst = append(dst, ' ')
		dst = append(dst, r.Comment...)
	}
	dst = append(dst, '\n')
	dst = append(dst, r.Seq...)
	dst = append(dst, '\n')
	if fastq {
		dst = append(dst, "+\n"...)
		dst = append(dst, r.Qual...)
		dst = append(dst, '\n')
	}
	return dst
}

// AppendTaxidSuffix appends upstream's " kraken:taxid|%llu" for an external taxid.
func AppendTaxidSuffix(dst []byte, externalTaxid uint64) []byte {
	dst = append(dst, " kraken:taxid|"...)
	return strconv.AppendUint(dst, externalTaxid, 10)
}

// Batch holds one input block's formatted output. Each worker owns its Batch; no locking.
type Batch struct {
	C1, C2, U1, U2 []byte
	suffix         []byte
}

// Reset empties the batch, keeping its memory.
func (b *Batch) Reset() {
	b.C1, b.C2, b.U1, b.U2 = b.C1[:0], b.C2[:0], b.U1[:0], b.U2[:0]
}

// Add formats one read (m2 nil for single-end) the way upstream does: classified reads (an
// internal call != 0) carry the external taxid in their headers. Upstream formats both classes
// whenever either output is requested; the caller may skip Add when neither is.
func (b *Batch) Add(m1, m2 *seqio.Record, classified bool, externalTaxid uint64) {
	if classified {
		b.suffix = AppendTaxidSuffix(b.suffix[:0], externalTaxid)
		b.C1 = AppendRecord(b.C1, m1, b.suffix)
		if m2 != nil {
			b.C2 = AppendRecord(b.C2, m2, b.suffix)
		}
		return
	}
	b.U1 = AppendRecord(b.U1, m1, nil)
	if m2 != nil {
		b.U2 = AppendRecord(b.U2, m2, nil)
	}
}

// PairedNames ports the '#' substitution: "a#b" becomes "a_1b" and "a_2b". The errors are
// upstream's (EX_DATAERR) verbatim.
func PairedNames(pattern string) (string, string, error) {
	fields := strings.SplitN(pattern, "#", 3) // upstream SplitString(…, "#", 3)
	if len(fields) < 2 {
		//lint:ignore ST1005 upstream message, verbatim
		return "", "", fmt.Errorf("Paired filename format missing # character: %s", pattern)
	}
	if len(fields) > 2 {
		//lint:ignore ST1005 upstream message, verbatim
		return "", "", fmt.Errorf("Paired filename format has >1 # character: %s", pattern)
	}
	return fields[0] + "_1" + fields[1], fields[0] + "_2" + fields[1], nil
}

// Writers holds the classified and unclassified output files of a run.
type Writers struct {
	files             []*os.File
	c1, c2, u1, u2    *bufio.Writer
	printingSequences bool
}

// Open creates the outputs as upstream InitializeOutputs does (classified first, then
// unclassified; an empty name means not requested). In paired mode each name must hold exactly
// one '#'. Upstream calls this only once the first input file is known to hold data, so an
// empty input creates no files; callers keep that order (see seqio.Reader.Prime).
func Open(classified, unclassified string, paired bool) (*Writers, error) {
	w := &Writers{}
	open := func(name string) (*bufio.Writer, error) {
		f, err := os.Create(name)
		if err != nil {
			//lint:ignore ST1005 upstream message, verbatim
			return nil, fmt.Errorf("Unable to open file: %s, reason: %w", name, err)
		}
		w.files = append(w.files, f)
		return bufio.NewWriterSize(f, 1<<20), nil
	}
	both := func(pattern string) (*bufio.Writer, *bufio.Writer, error) {
		if !paired {
			o, err := open(pattern)
			return o, nil, err
		}
		n1, n2, err := PairedNames(pattern)
		if err != nil {
			return nil, nil, err
		}
		o1, err := open(n1)
		if err != nil {
			return nil, nil, err
		}
		o2, err := open(n2)
		return o1, o2, err
	}
	var err error
	if classified != "" {
		if w.c1, w.c2, err = both(classified); err != nil {
			w.Close()
			return nil, err
		}
		w.printingSequences = true
	}
	if unclassified != "" {
		if w.u1, w.u2, err = both(unclassified); err != nil {
			w.Close()
			return nil, err
		}
		w.printingSequences = true
	}
	return w, nil
}

// PrintingSequences reports whether any sequence output was requested (upstream's
// printing_sequences): only then do reads need formatting into a Batch.
func (w *Writers) PrintingSequences() bool { return w != nil && w.printingSequences }

// Write appends a batch to the outputs. Batches must arrive in input order.
func (w *Writers) Write(b *Batch) error {
	for _, p := range []struct {
		o *bufio.Writer
		d []byte
	}{{w.c1, b.C1}, {w.c2, b.C2}, {w.u1, b.U1}, {w.u2, b.U2}} {
		if p.o != nil && len(p.d) > 0 {
			if _, err := p.o.Write(p.d); err != nil {
				return err
			}
		}
	}
	return nil
}

// Close flushes and closes every output, returning the first error.
func (w *Writers) Close() error {
	var first error
	for _, o := range []*bufio.Writer{w.c1, w.c2, w.u1, w.u2} {
		if o != nil {
			if err := o.Flush(); err != nil && first == nil {
				first = err
			}
		}
	}
	for _, f := range w.files {
		if err := f.Close(); err != nil && first == nil {
			first = err
		}
	}
	w.files = nil
	return first
}
