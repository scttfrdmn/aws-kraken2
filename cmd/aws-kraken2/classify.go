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
	"io"
	"math"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/classify"
	"github.com/scttfrdmn/aws-kraken2/internal/engine"
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
	decomp                       seqio.Decompressor // AK2_DECOMPRESS
	// nil = option not given. kraken2Output "" or nil is standard output; "-" silences it.
	kraken2Output, classifiedOut, unclassifiedOut, reportFile *string
	// env looks up the engine's AK2_ENGINE_* settings (nil: the process environment). Tests run
	// several nodes in one process, each with its own.
	env func(string) (string, bool)

	// Cohort mode (cohort.go): the index loaded once for every sample, the block-striped
	// sample's session (nil for a sample-parallel one), the S3 client for this sample's s3://
	// outputs ("" = AK2_S3_CLIENT), and the sample's record (phases, counts).
	pre      *index
	node     *node
	s3client string
	rec      *sampleRec
}

// phase times a phase: into the sample's record in cohort mode (several samples run at once, so
// global phase lines would be ambiguous), else as an ak2-timing line.
func (c *classifyArgs) phase(name string) *phaseMark {
	if c.rec != nil {
		return &phaseMark{name: name, t: time.Now(), rec: c.rec}
	}
	return phase(name)
}

func (c *classifyArgs) lookupEnv() func(string) (string, bool) {
	if c.env != nil {
		return c.env
	}
	return os.LookupEnv
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
	eng   *engineIndex // the sharded engine, instead of table (AK2_ENGINE_N)
}

func (x *index) close() {
	if x.eng != nil {
		x.eng.close()
		return
	}
	x.table.Close()
}

// loadIndex is load_index. Upstream reads opts.k2d, taxo.k2d, then hash.k2d.
func loadIndex(c *classifyArgs) (*index, int) {
	fmt.Fprint(os.Stderr, "Loading database information...")
	fail := func(status int, format string, a ...any) (*index, int) {
		fmt.Fprintln(os.Stderr)
		return nil, classifyErr(status, format, a...)
	}
	po := phase("opts")
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
	po.end()
	pt := phase("taxo")
	tax, err := taxo.Load(c.taxoFile)
	if err != nil {
		return fail(exitFailure, "%v", err)
	}
	pt.end()
	// Probe mode: linear, the mode upstream's default build (-DLINEAR_PROBING) uses, confirmed
	// for both pinned databases by make g0b (docs/g0b.md).
	copt := chash.Options{Mode: chash.Linear}
	if v, err := strconv.Atoi(os.Getenv("K2_DB_READ_THREADS")); err == nil && v > 0 {
		copt.ReadThreads = v
	}
	ph := phase("hash")
	if ec, err := engineFromEnv(c.lookupEnv()); err != nil {
		return fail(exUsage, "%v", err)
	} else if ec != nil {
		readThreads := copt.ReadThreads
		if readThreads <= 0 {
			readThreads = 8
		}
		var eng *engineIndex
		if ec.cluster != nil {
			inputs := len(c.files)
			if c.paired {
				inputs /= 2
			}
			eng, err = loadNode(c.hashFile, ec, readThreads, c.threads, inputs)
		} else {
			eng, err = loadEngine(c.hashFile, ec, readThreads, c.threads)
		}
		if err != nil {
			return fail(exitFailure, "%v", err)
		}
		ph.end()
		fmt.Fprintln(os.Stderr, " done.")
		return &index{opts: o, tax: tax, eng: eng}, 0
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
	ph.end()
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
	batch   chash.BatchScratch
	// engine path: one token stream per read of the block, the block's keys and values
	toks []*classify.Tokens
	keys []uint64
	vals []uint32
	rs   engine.RouteScratch
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
	err    error // the engine could not resolve the block's lookups
}

func classifyRun(c *classifyArgs) int {
	idx, status := c.pre, 0
	if idx == nil {
		if idx, status = loadIndex(c); idx == nil {
			return status
		}
		defer func() {
			p := phase("unmap")
			idx.close()
			p.end()
		}()
	}
	if idx.eng != nil && c.pre == nil {
		// The engine's counters once everything is written (outputs closed, the report put), so
		// the request counts include the last CompleteMultipartUpload and the report's PutObject.
		defer idx.eng.report()
	}
	ps := c.phase("setup")

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
	switch {
	case c.pre != nil:
		r.node = c.node // cohort mode: a block-striped sample's session, or nil
	case idx.eng != nil:
		r.node = idx.eng.node
	}
	if c.rec != nil {
		defer func() { c.rec.st = r.st }()
	}
	defer r.out.close()
	ps.end()
	pc := c.phase("classify")
	start := time.Now()
	status = 0
	if c.paired {
		for i := 0; i+1 < len(c.files) && status == 0; i += 2 {
			status = r.processFiles(c.files[i], c.files[i+1])
		}
	} else {
		for i := 0; i < len(c.files) && status == 0; i++ {
			status = r.processFiles(c.files[i], "")
		}
	}
	elapsed := time.Since(start)
	pc.end()
	counts := map[uint64]*classify.TaxonCount{}
	for _, w := range workers {
		classify.MergeCounts(counts, w.w.Counts)
	}
	if nd := r.node; nd != nil {
		// Every node waits here until no node needs its shard; the emitter collects the others'
		// counters (the report's sum-reduce).
		merged, st, err := nd.endRun(status, counts)
		if err != nil {
			r.out.abandon()
			return classifyErr(st, "%v", err)
		}
		if !nd.emitter || st != 0 {
			return st
		}
		counts = merged
	}
	if status != 0 {
		return status
	}
	pf := c.phase("close")
	if err := r.out.close(); err != nil {
		return classifyErr(exIOErr, "%v", err)
	}
	pf.end()
	reportStats(elapsed, r.st, r.tty)
	if timingsOn && idx.eng != nil && c.pre == nil {
		fmt.Fprintf(os.Stderr, "ak2-engine\tresult\tsequences\t%d\tbases\t%d\tclassified\t%d\n",
			r.st.sequences, r.st.bases, r.st.classified)
	}

	if name := c.reportName(); name != "" {
		pr := c.phase("report")
		defer pr.end()
		calls := classify.Calls(counts)
		// Upstream writes the report through an unchecked ofstream: a report that cannot be
		// created is silently not written, and the run still exits 0. An s3:// report (the
		// engine's) is one PutObject of the same bytes.
		var f io.WriteCloser
		if isS3(name) {
			f = &s3Report{name: name, client: c.s3client}
		} else {
			lf, err := os.Create(name)
			if err != nil {
				return 0
			}
			f = lf
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
			// Upstream does not check the report's writes either; say so, keep its status.
			fmt.Fprintf(os.Stderr, "%s: warning: report %s: %v\n", prog, name, err)
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
	node    *node // multi-node engine (AK2_ENGINE_RANK); nil otherwise

	failed   atomic.Bool
	failOnce sync.Once
	failErr  error
}

// openInput opens one input as classify sees it. Without compression classify opens the file
// itself (EX_NOINPUT if it cannot). With compression the wrapper has already piped it through
// `gzip -dc` / `bzip2 -dc`, which report a missing file on stderr and leave classify an empty
// stream. With AK2_DECOMPRESS=pipe that is literally what happens (seqio.OpenPipe): the tool
// itself reports, and only a tool missing from PATH (the wrapper's shell would say "not found")
// is reported here.
func (r *runner) openInput(name string) (*seqio.Reader, int) {
	if r.comp == seqio.CompressionNone {
		rd, err := seqio.Open(name, r.comp)
		if err != nil {
			return nil, classifyErr(exNoInput, "unable to open %s", name)
		}
		return rd, 0
	}
	if r.c.decomp == seqio.DecompressPipe {
		rd, err := seqio.OpenPipe(name, r.comp)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %s -dc %s: %v\n", prog, r.comp, name, err)
			return seqio.NewReader(bytes.NewReader(nil)), 0
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

// inputs is one processFiles call's open inputs.
type inputs struct {
	name1, name2 string
	r1, r2       *seqio.Reader
	pr           *seqio.PairedReader
}

func (in *inputs) close() {
	if in.r1 != nil {
		in.r1.Close()
	}
	if in.r2 != nil {
		in.r2.Close()
	}
}

// open is ProcessFiles' prologue: open and prime both inputs, and initialize the outputs once
// an input holds data. It returns 0 or the exit status upstream ends the run with.
func (r *runner) open(name1, name2 string, initOutputs bool) (*inputs, int) {
	in := &inputs{name1: name1, name2: name2}
	var st int
	if in.r1, st = r.openInput(name1); st != 0 {
		return in, st
	}
	if name2 != "" {
		if in.r2, st = r.openInput(name2); st != 0 {
			return in, st
		}
	}
	// Prime both inputs before checking either, as upstream.
	haveInput, err1 := in.r1.Prime()
	var err2 error
	if in.r2 != nil {
		_, err2 = in.r2.Prime()
	}
	if err1 != nil {
		return in, classifyErr(exIOErr, "%v (%s)", err1, name1)
	}
	if err2 != nil {
		return in, classifyErr(exIOErr, "%v (%s)", err2, name2)
	}
	if haveInput && initOutputs {
		if st := r.out.initialize(r.c); st != 0 {
			return in, st
		}
	}
	if in.r2 != nil {
		in.pr = seqio.NewPairedReader(in.r1, in.r2)
	}
	return in, 0
}

// next cuts the next block of whole records (ok false at the end of the input).
func (in *inputs) next(seq uint64) (job, bool) {
	if in.pr != nil {
		b1, b2, ok := in.pr.LoadBlocks(seqio.DefaultBlockBytes)
		return job{seq, b1, b2}, ok
	}
	b := in.r1.LoadBlock(seqio.DefaultBlockBytes, 1)
	return job{seq: seq, b1: b}, b != nil
}

// processFiles is ProcessFiles for one input (name2 == "") or one mate pair. It returns 0, or
// the exit status upstream ends the run with.
func (r *runner) processFiles(name1, name2 string) int {
	if r.node != nil {
		return r.processFilesCluster(name1, name2)
	}
	in, st := r.open(name1, name2, true)
	defer in.close()
	if st != 0 {
		return st
	}
	jobs := make(chan job, len(r.workers))
	results := make(chan *result, 2*len(r.workers))
	// Sequential step: cut blocks of whole records, in order. After a failed block nothing
	// more is cut, and workers skip what is queued, so no further lookups are scheduled.
	go func() {
		defer close(jobs)
		for seq := uint64(0); !r.failed.Load(); seq++ {
			j, ok := in.next(seq)
			if !ok {
				return
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
			if p.err != nil || r.failed.Load() {
				continue // drain; nothing after a failed block is written
			}
			r.emitResult(p, &fault)
		}
	}
	if err := r.out.flush(); err != nil {
		return classifyErr(exIOErr, "%v", err)
	}
	if err := r.failure(); err != nil {
		r.out.abandon() // no truncated object is completed
		return classifyErr(exitFailure, "%v", err)
	}
	return r.finishInput(in, fault, true)
}

// emitResult accounts for and writes one block, in input order.
func (r *runner) emitResult(p *result, fault *seqio.Fault) {
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

// fail records the first failed block's error and stops further work (no more blocks are cut
// or looked up).
func (r *runner) fail(err error) {
	r.failOnce.Do(func() { r.failErr = err })
	r.failed.Store(true)
	if nd := r.node; nd != nil {
		nd.aborted.Store(true)
		if nd.box != nil {
			nd.box.wake()
		}
	}
}

func (r *runner) failure() error {
	if !r.failed.Load() {
		return nil
	}
	return r.failErr
}

// finishInput is ProcessFiles' end: the end-of-run problems, reported once everything readable
// is written. writing is false on a home node that is not the emitter (it writes nothing).
func (r *runner) finishInput(in *inputs, fault seqio.Fault, writing bool) int {
	c := r.c
	r1, r2, pr := in.r1, in.r2, in.pr
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
		problems = append(problems, fmt.Sprintf("%v (%s)", e1, in.name1))
	}
	if e2 != nil {
		problems = append(problems, fmt.Sprintf("%v (%s)", e2, in.name2))
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
	if len(problems) == 0 {
		return 0
	}
	if !writing {
		return exDataErr // the emitter reports it
	}
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

// work is one block on one worker: parse, mask, scan, look up, classify, format.
func (r *runner) work(ws *workerState, j job, printing bool) *result {
	res := &result{seq: j.seq}
	if r.failed.Load() {
		res.err = errAborted
		return res
	}
	var m1, m2 []seqio.Record
	if j.b2 != nil {
		m1, m2, res.fault = seqio.PairBlocks(j.b1, j.b2)
	} else {
		m1, res.fault = j.b1.Parse()
	}
	if r.idx.eng != nil {
		r.workEngine(ws, res, m1, m2, printing)
		if res.err != nil {
			r.fail(res.err)
		}
		return res
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
		tk.Vals = tab.GetBatch(tk.Keys, tk.Vals[:0], &ws.batch)
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

// workEngine is work's engine path: scan every read of the block, route all of the block's
// lookups at once, then classify each read with its values, in order.
func (r *runner) workEngine(ws *workerState, res *result, m1, m2 []seqio.Record, printing bool) {
	eng := r.idx.eng
	paired := r.c.paired
	minQ := r.c.minQuality
	t0 := time.Now()
	for len(ws.toks) < len(m1) {
		ws.toks = append(ws.toks, ws.cl.NewTokens())
	}
	ws.keys = ws.keys[:0]
	for i := range m1 {
		s1 := &m1[i]
		var s2 *seqio.Record
		if paired {
			s2 = &m2[i]
		}
		if minQ > 0 {
			seqio.MaskLowQuality(s1, minQ)
			if paired {
				seqio.MaskLowQuality(s2, minQ)
			}
		}
		tk := ws.toks[i]
		tk.Reset()
		tk.Scan(ws.scanner, s1.Seq)
		if paired {
			tk.MateBorder()
			tk.Scan(ws.scanner, s2.Seq)
		}
		ws.keys = append(ws.keys, tk.Keys...)
	}
	t1 := time.Now()
	vals, err := eng.router.Lookup(ws.keys, ws.vals[:0], &ws.rs)
	ws.vals = vals
	t2 := time.Now()
	eng.scanNs.Add(int64(t1.Sub(t0)))
	eng.lookupNs.Add(int64(t2.Sub(t1)))
	if err != nil {
		res.err = err
		return
	}
	before := ws.w.Classified
	ws.w.Out = getBuf()
	off := 0
	for i := range m1 {
		s1 := &m1[i]
		var s2 *seqio.Record
		var len2 uint32
		if paired {
			s2 = &m2[i]
			len2 = uint32(len(s2.Seq))
		}
		res.st.sequences++
		tk := ws.toks[i]
		k := len(tk.Keys)
		tk.Vals = vals[off : off+k : off+k]
		off += k
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
	eng.classifyNs.Add(int64(time.Since(t2)))
}

// errAborted marks a block skipped after another block failed.
var errAborted = errors.New("aborted after an earlier failure")

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
