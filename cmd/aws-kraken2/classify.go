// Ported from DerrickWood/kraken2 src/classify.cc (load_index, classify, ProcessFiles,
// InitializeOutputs, ReportStats) at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"math"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/classify"
	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
	"github.com/scttfrdmn/aws-kraken2/internal/mmscan"
	"github.com/scttfrdmn/aws-kraken2/internal/report"
	"github.com/scttfrdmn/aws-kraken2/internal/seqio"
	"github.com/scttfrdmn/aws-kraken2/internal/seqout"
	"github.com/scttfrdmn/aws-kraken2/internal/taxo"
)

// classifyArgs is upstream classify's Options as the wrapper sets them.
type classifyArgs struct {
	hashFile, taxoFile, optsFile string
	threads                      int
	quick, paired, useNames      bool
	confidence                   float64
	minQuality, minHitGroups     int
	mpa, zeroCounts              bool
	memoryMapping                bool
	reportKmerData               bool
	files                        []string
	gzipFlag, bzip2Flag          bool
	// nil = option not given. kraken2Output "" or nil is standard output; "-" silences it.
	kraken2Output, classifiedOut, unclassifiedOut, reportFile *string
}

func (c *classifyArgs) reportName() string {
	if c.reportFile == nil {
		return ""
	}
	return *c.reportFile
}

// index is upstream's IndexData.
type index struct {
	opts  kdb.Options
	tax   *taxo.Taxonomy
	table *chash.Table
}

// loadIndex is load_index. Upstream reads opts.k2d, taxo.k2d, then hash.k2d.
func loadIndex(c *classifyArgs) (*index, int) {
	fmt.Fprint(os.Stderr, "Loading database information...")
	fail := func(status int, format string, a ...any) (*index, int) {
		fmt.Fprintln(os.Stderr)
		return nil, classifyErr(status, format, a...)
	}
	f, err := os.Open(c.optsFile)
	if err != nil {
		return fail(71, "unable to get filesize of %s", c.optsFile) // EX_OSERR
	}
	o, err := kdb.ReadOptions(f)
	f.Close()
	if err != nil {
		return fail(exitFailure, "%s: %v", c.optsFile, err)
	}
	if !o.DNADB {
		return fail(exitFailure, "%s is a translated-search (protein) database (dna_db=0); "+
			"aws-kraken2 does not support translated search", c.optsFile)
	}
	tax, err := taxo.Load(c.taxoFile)
	if err != nil {
		return fail(exitFailure, "%v", err)
	}
	// Probe mode: linear, the mode upstream's default build (-DLINEAR_PROBING) uses, confirmed
	// for both pinned databases by make g0b (docs/g0b.md).
	copt := chash.Options{Mode: chash.Linear}
	if v, err := strconv.Atoi(os.Getenv("K2_DB_READ_THREADS")); err == nil && v > 0 {
		copt.ReadThreads = v
	}
	var tab *chash.Table
	if c.memoryMapping {
		tab, err = chash.Mmap(c.hashFile, copt)
	} else {
		tab, err = chash.Load(c.hashFile, copt)
	}
	if err != nil {
		return fail(exitFailure, "%v", err)
	}
	fmt.Fprintln(os.Stderr, " done.")
	return &index{opts: o, tax: tax, table: tab}, 0
}

// stats is ClassificationStats.
type stats struct {
	sequences, bases, classified uint64
}

// workerState is one worker's scratch and counters, kept across input files (upstream's
// per-thread counters are merged into the run's total; summing per worker first is the same).
type workerState struct {
	scanner *mmscan.Scanner
	cl      *classify.Classifier
	tokens  *classify.Tokens
	w       classify.Worker
}

type job struct {
	seq    uint64
	b1, b2 *seqio.Block
}

type result struct {
	seq    uint64
	kraken []byte
	batch  seqout.Batch
	st     stats
	fault  seqio.Fault
}

func classifyRun(c *classifyArgs) int {
	idx, status := loadIndex(c)
	if idx == nil {
		return status
	}
	defer idx.table.Close()

	comp, err := seqio.ResolveCompression(c.gzipFlag, c.bzip2Flag, c.files[0])
	if err != nil {
		return die(err.Error())
	}
	opt := classify.Options{
		Paired:           c.paired,
		Quick:            c.quick,
		Confidence:       c.confidence,
		MinimumHitGroups: c.minHitGroups,
		UseNames:         c.useNames,
		CountTaxa:        c.reportName() != "",
		NoOutput:         c.kraken2Output != nil && *c.kraken2Output == "-",
	}
	o := idx.opts
	workers := make([]*workerState, c.threads)
	for i := range workers {
		sc, err := mmscan.New(int(o.K), int(o.L), o.SpacedSeedMask, o.ToggleMask, o.DNADB, int(o.RevcomVersion))
		if err != nil {
			return classifyErr(exitFailure, "%v", err)
		}
		cl, err := classify.New(idx.tax, classify.IndexInfo{DNA: o.DNADB,
			MinimumAcceptableHashValue: o.MinimumAcceptableHashValue}, opt, nil)
		if err != nil {
			return classifyErr(exitFailure, "%v", err)
		}
		workers[i] = &workerState{scanner: sc, cl: cl, tokens: cl.NewTokens()}
	}

	r := &runner{c: c, idx: idx, opt: opt, comp: comp, workers: workers, tty: isTTY(os.Stderr)}
	defer r.out.close()
	start := time.Now()
	if c.paired {
		for i := 0; i+1 < len(c.files); i += 2 {
			if st := r.processFiles(c.files[i], c.files[i+1]); st != 0 {
				return st
			}
		}
	} else {
		for _, f := range c.files {
			if st := r.processFiles(f, ""); st != 0 {
				return st
			}
		}
	}
	elapsed := time.Since(start)
	if err := r.out.close(); err != nil {
		return classifyErr(exIOErr, "%v", err)
	}
	reportStats(elapsed, r.st, r.tty)

	if name := c.reportName(); name != "" {
		counts := map[uint64]*classify.TaxonCount{}
		for _, w := range workers {
			classify.MergeCounts(counts, w.w.Counts)
		}
		calls := classify.Calls(counts)
		f, err := os.Create(name)
		if err != nil {
			return classifyErr(exitFailure, "unable to open report file %s: %v", name, err)
		}
		bw := bufio.NewWriterSize(f, 1<<20)
		ropt := report.Options{ZeroCounts: c.zeroCounts}
		if c.mpa {
			err = report.MpaStyle(bw, idx.tax, calls, ropt)
		} else {
			err = report.KrakenStyle(bw, idx.tax, calls, r.st.sequences, r.st.sequences-r.st.classified, ropt)
		}
		if err == nil {
			err = bw.Flush()
		}
		if e := f.Close(); err == nil {
			err = e
		}
		if err != nil {
			return classifyErr(exIOErr, "%s: %v", name, err)
		}
	}
	return 0
}

type runner struct {
	c       *classifyArgs
	idx     *index
	opt     classify.Options
	comp    seqio.Compression
	workers []*workerState
	out     outputs
	st      stats
	tty     bool
}

// openInput opens one input as classify sees it. Without compression classify opens the file
// itself (EX_NOINPUT if it cannot). With compression the wrapper has already piped it through
// `gzip -dc` / `bzip2 -dc`, which report a missing file on stderr and leave classify an empty
// stream.
func (r *runner) openInput(name string) (*seqio.Reader, int) {
	if r.comp == seqio.CompressionNone {
		rd, err := seqio.Open(name, r.comp)
		if err != nil {
			return nil, classifyErr(exNoInput, "unable to open %s", name)
		}
		return rd, 0
	}
	if _, err := os.Stat(name); err != nil {
		fmt.Fprintf(os.Stderr, "%s: %s: No such file or directory\n", r.comp, name)
		return seqio.NewReader(bytes.NewReader(nil)), 0
	}
	rd, err := seqio.Open(name, r.comp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %s: %v\n", r.comp, name, err)
		return seqio.NewReader(bytes.NewReader(nil)), 0
	}
	return rd, 0
}

// processFiles is ProcessFiles for one input (name2 == "") or one mate pair. It returns 0, or
// the exit status upstream ends the run with.
func (r *runner) processFiles(name1, name2 string) int {
	c := r.c
	r1, st := r.openInput(name1)
	if st != 0 {
		return st
	}
	defer r1.Close()
	var r2 *seqio.Reader
	if name2 != "" {
		if r2, st = r.openInput(name2); st != 0 {
			return st
		}
		defer r2.Close()
	}
	// Prime both inputs before checking either, as upstream.
	haveInput, err1 := r1.Prime()
	var err2 error
	if r2 != nil {
		_, err2 = r2.Prime()
	}
	if err1 != nil {
		return classifyErr(exIOErr, "%v (%s)", err1, name1)
	}
	if err2 != nil {
		return classifyErr(exIOErr, "%v (%s)", err2, name2)
	}
	if haveInput {
		if st := r.out.initialize(c); st != 0 {
			return st
		}
	}

	var pr *seqio.PairedReader
	if r2 != nil {
		pr = seqio.NewPairedReader(r1, r2)
	}
	jobs := make(chan job, len(r.workers))
	results := make(chan *result, 2*len(r.workers))
	// Sequential step: cut blocks of whole records, in order.
	go func() {
		defer close(jobs)
		for seq := uint64(0); ; seq++ {
			var j job
			if pr != nil {
				b1, b2, ok := pr.LoadBlocks(seqio.DefaultBlockBytes)
				if !ok {
					return
				}
				j = job{seq, b1, b2}
			} else {
				b := r1.LoadBlock(seqio.DefaultBlockBytes, 1)
				if b == nil {
					return
				}
				j = job{seq: seq, b1: b}
			}
			jobs <- j
		}
	}()
	var wg sync.WaitGroup
	printing := r.out.printingSequences
	for _, ws := range r.workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				results <- r.work(ws, j, printing)
			}
		}()
	}
	go func() { wg.Wait(); close(results) }()

	// Ordered emission: results arrive in any order and are written in input order.
	var fault seqio.Fault
	pending := map[uint64]*result{}
	next := uint64(0)
	for res := range results {
		pending[res.seq] = res
		for {
			p, ok := pending[next]
			if !ok {
				break
			}
			delete(pending, next)
			next++
			r.st.sequences += p.st.sequences
			r.st.bases += p.st.bases
			r.st.classified += p.st.classified
			if p.fault.Count > 0 && fault.First == "" {
				fault.First = p.fault.First
			}
			fault.Count += p.fault.Count
			r.out.emit(p)
			if r.tty {
				fmt.Fprintf(os.Stderr, "\rProcessed %d sequences (%d bp) ...", r.st.sequences, r.st.bases)
			}
		}
	}
	if err := r.out.flush(); err != nil {
		return classifyErr(exIOErr, "%v", err)
	}

	// The end-of-run problems, reported once everything readable is written.
	var problems []string
	e1, e2 := r1.Err(), error(nil)
	if r2 != nil {
		e2 = r2.Err()
	}
	mismatch := false
	if pr != nil && e1 == nil && e2 == nil {
		mismatch = errors.Is(pr.Err(), seqio.ErrMateCountMismatch)
		e2 = r2.Err()
	}
	if e1 != nil {
		problems = append(problems, fmt.Sprintf("%v (%s)", e1, name1))
	}
	if e2 != nil {
		problems = append(problems, fmt.Sprintf("%v (%s)", e2, name2))
	}
	if mismatch && e1 == nil && e2 == nil {
		problems = append(problems, seqio.ErrMateCountMismatch.Error())
	}
	if fault.First != "" {
		f := fault.First
		if fault.Count > 1 {
			f += ", and " + strconv.Itoa(fault.Count-1) + " further malformed records"
		}
		problems = append(problems, f+"; their bases were classified with the rest")
	}
	if len(problems) > 0 {
		var msg bytes.Buffer
		for i, p := range problems {
			if i > 0 {
				msg.WriteString("; ")
			}
			msg.WriteString(p)
		}
		fmt.Fprintf(&msg, ". %d records were classified", r.st.sequences)
		if r.out.krakenWritten() {
			name := "standard output"
			if c.kraken2Output != nil && *c.kraken2Output != "" {
				name = *c.kraken2Output
			}
			msg.WriteString(" and written to " + name)
		}
		if c.reportName() != "" {
			msg.WriteString("; the report was not written")
		}
		r.out.close()
		return classifyErr(exDataErr, "%s", msg.String())
	}
	return 0
}

// work is one block on one worker: parse, mask, scan, look up, classify, format.
func (r *runner) work(ws *workerState, j job, printing bool) *result {
	res := &result{seq: j.seq}
	var m1, m2 []seqio.Record
	if j.b2 != nil {
		m1, m2, res.fault = seqio.PairBlocks(j.b1, j.b2)
	} else {
		m1, res.fault = j.b1.Parse()
	}
	paired := r.c.paired
	minQ := r.c.minQuality
	tab := r.idx.table
	tk := ws.tokens
	before := ws.w.Classified
	ws.w.Out = getBuf()
	for i := range m1 {
		s1 := &m1[i]
		var s2 *seqio.Record
		if paired {
			s2 = &m2[i]
		}
		res.st.sequences++
		if minQ > 0 {
			seqio.MaskLowQuality(s1, minQ)
			if paired {
				seqio.MaskLowQuality(s2, minQ)
			}
		}
		tk.Reset()
		tk.Scan(ws.scanner, s1.Seq)
		var len2 uint32
		if paired {
			tk.MateBorder()
			tk.Scan(ws.scanner, s2.Seq)
			len2 = uint32(len(s2.Seq))
		}
		tk.Vals = tk.Vals[:0]
		for _, k := range tk.Keys {
			v, _ := tab.Get(k)
			tk.Vals = append(tk.Vals, v)
		}
		call := ws.cl.Classify(tk, s1.ID, uint32(len(s1.Seq)), len2, &ws.w)
		if printing {
			res.batch.Add(s1, s2, call != 0, r.idx.tax.ExternalID(call))
		}
		res.st.bases += uint64(len(s1.Seq))
		if paired {
			res.st.bases += uint64(len(s2.Seq))
		}
	}
	res.st.classified = ws.w.Classified - before
	res.kraken = ws.w.Out
	ws.w.Out = nil
	return res
}

var bufPool = sync.Pool{New: func() any { return []byte(nil) }}

func getBuf() []byte { return bufPool.Get().([]byte)[:0] }

func putBuf(b []byte) {
	if cap(b) > 0 {
		//lint:ignore SA6002 the slice header is small; the backing array is what is pooled
		bufPool.Put(b[:0])
	}
}

// reportStats is ReportStats (stderr; not under the oracle law, but the same format).
func reportStats(elapsed time.Duration, st stats, tty bool) {
	seconds := elapsed.Seconds()
	unclassified := st.sequences - st.classified
	if tty {
		fmt.Fprint(os.Stderr, "\r")
	}
	fmt.Fprintf(os.Stderr, "%d sequences (%s Mbp) processed in %.3fs (%s Kseq/m, %s Mbp/m).\n",
		st.sequences, cfloat(float64(st.bases)/1.0e6, 2), seconds,
		cfloat(float64(st.sequences)/1.0e3/(seconds/60), 1),
		cfloat(float64(st.bases)/1.0e6/(seconds/60), 2))
	fmt.Fprintf(os.Stderr, "  %d sequences classified (%s%%)\n", st.classified,
		cfloat(float64(st.classified)*100.0/float64(st.sequences), 2))
	fmt.Fprintf(os.Stderr, "  %d sequences unclassified (%s%%)\n", unclassified,
		cfloat(float64(unclassified)*100.0/float64(st.sequences), 2))
}

// cfloat formats like C printf %.Nf on glibc/aarch64 (nan, inf).
func cfloat(f float64, prec int) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	}
	return strconv.FormatFloat(f, 'f', prec, 64)
}

func isTTY(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}
