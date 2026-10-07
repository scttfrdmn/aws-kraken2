// Ported from DerrickWood/kraken2 src/classify.cc (InitializeOutputs, OpenOutputStream, the
// ordered output loop of ProcessFiles) at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/scttfrdmn/aws-kraken2/internal/objstore"
	"github.com/scttfrdmn/aws-kraken2/internal/seqout"
)

// Output ordering without a global lock: batches are formatted by the workers, and the
// sequencer (processFiles) only assigns each batch its file offsets, a running prefix sum of
// the batch sizes in input order. The bytes are then written with pwrite (os.File.WriteAt) by a
// small pool of writers, concurrently and in any order. An output that is not a regular file
// (standard output, a pipe, a terminal) cannot be written at an offset; it is written in order
// by the sequencer instead.

// sink is one output file.
type sink struct {
	f       *os.File
	pwrite  bool
	off     int64
	bw      *bufio.Writer // when !pwrite
	discard bool          // upstream's single-end ofstream that failed to open: writes vanish
	// An s3:// output (the multi-node engine's emitter, #24) is one multipart upload, written
	// in read order by the sequencer; parts of at least 8 MiB upload in the background.
	mw *objstore.Writer
}

// isS3 reports whether an output name is an object (s3://bucket/key).
func isS3(name string) bool { return strings.HasPrefix(name, "s3://") }

func (o *outputs) newS3Sink(name string) (*sink, error) {
	w, err := objstore.NewWriter(context.Background(), objstore.FromEnv(), name, objstore.DefaultPartSize, 4)
	if err != nil {
		return nil, err
	}
	s := &sink{mw: w}
	o.s3 = append(o.s3, s)
	return s, nil
}

type wjob struct {
	s   *sink
	b   []byte
	off int64
	put bool // return b to the pool afterwards
}

// outputs is upstream's OutputStreamData.
type outputs struct {
	initialized       bool
	printingSequences bool
	c1, c2, u1, u2    *sink
	// kraken is the --output sink: standard output until InitializeOutputs runs (upstream's
	// &std::cout default), nil when silenced with "-".
	kraken     *sink
	krakenInit bool
	files      []*os.File
	s3         []*sink

	jobs   chan wjob
	wg     sync.WaitGroup
	mu     sync.Mutex
	err    error
	closed bool
}

var stdoutSink = &sink{bw: bufio.NewWriterSize(os.Stdout, 1<<20)}

func (o *outputs) krakenSink() *sink {
	if !o.krakenInit {
		return stdoutSink
	}
	return o.kraken
}

func (o *outputs) krakenWritten() bool { return o.krakenSink() != nil }

func (o *outputs) newSink(f *os.File) *sink {
	s := &sink{f: f}
	if fi, err := f.Stat(); err == nil && fi.Mode().IsRegular() {
		s.pwrite = true
	} else {
		s.bw = bufio.NewWriterSize(f, 1<<20)
	}
	o.files = append(o.files, f)
	return s
}

// openStream is OpenOutputStream: failure ends the run with EXIT_FAILURE.
func (o *outputs) openStream(name string) (*sink, int) {
	if isS3(name) {
		s, err := o.newS3Sink(name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "\rUnable to open file: %s, reason: %v\n", name, err)
			return nil, exitFailure
		}
		return s, 0
	}
	f, err := os.Create(name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "\rUnable to open file: %s, reason: %s\n", name, unwrapPath(err))
		return nil, exitFailure
	}
	return o.newSink(f), 0
}

// openPlain is the single-end `new ofstream(name)`, which upstream does not check.
func (o *outputs) openPlain(name string) *sink {
	if isS3(name) {
		s, err := o.newS3Sink(name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: %s: %v\n", prog, name, err)
			return &sink{discard: true}
		}
		return s
	}
	f, err := os.Create(name)
	if err != nil {
		return &sink{discard: true}
	}
	return o.newSink(f)
}

// unwrapPath is the reason as C strerror words it ("No such file or directory").
func unwrapPath(err error) string {
	if pe, ok := err.(*os.PathError); ok {
		err = pe.Err
	}
	m := err.Error()
	if m != "" && m[0] >= 'a' && m[0] <= 'z' {
		m = string(m[0]-'a'+'A') + m[1:]
	}
	return m
}

// initialize is InitializeOutputs: classified, then unclassified, then --output.
func (o *outputs) initialize(c *classifyArgs) int {
	if o.initialized {
		return 0
	}
	pair := func(pattern string) (*sink, *sink, int) {
		if !c.paired {
			return o.openPlain(pattern), nil, 0
		}
		n1, n2, err := seqout.PairedNames(pattern)
		if err != nil {
			return nil, nil, classifyErr(exDataErr, "%v", err)
		}
		s1, st := o.openStream(n1)
		if st != 0 {
			return nil, nil, st
		}
		s2, st := o.openStream(n2)
		return s1, s2, st
	}
	var st int
	if c.classifiedOut != nil && *c.classifiedOut != "" {
		if o.c1, o.c2, st = pair(*c.classifiedOut); st != 0 {
			return st
		}
		o.printingSequences = true
	}
	if c.unclassifiedOut != nil && *c.unclassifiedOut != "" {
		if o.u1, o.u2, st = pair(*c.unclassifiedOut); st != 0 {
			return st
		}
		o.printingSequences = true
	}
	if c.kraken2Output != nil && *c.kraken2Output != "" {
		o.krakenInit = true
		if *c.kraken2Output != "-" {
			if o.kraken, st = o.openStream(*c.kraken2Output); st != 0 {
				return st
			}
		}
	}
	o.initialized = true
	return 0
}

func (o *outputs) setErr(err error) {
	o.mu.Lock()
	if o.err == nil {
		o.err = err
	}
	o.mu.Unlock()
}

func (o *outputs) startWriters() {
	if o.jobs != nil {
		return
	}
	o.jobs = make(chan wjob, 64)
	for range 4 {
		go func() {
			for j := range o.jobs {
				if _, err := j.s.f.WriteAt(j.b, j.off); err != nil {
					o.setErr(err)
				}
				if j.put {
					putBuf(j.b)
				}
				o.wg.Done()
			}
		}()
	}
}

// write queues b for s at s's next offset (pwrite), or writes it in order.
func (o *outputs) write(s *sink, b []byte, put bool) {
	if s == nil || s.discard || len(b) == 0 {
		if put {
			putBuf(b)
		}
		return
	}
	if s.mw != nil {
		if _, err := s.mw.Write(b); err != nil {
			o.setErr(err)
		}
		if put {
			putBuf(b)
		}
		return
	}
	if !s.pwrite {
		if _, err := s.bw.Write(b); err != nil {
			o.setErr(err)
		}
		if put {
			putBuf(b)
		}
		return
	}
	o.startWriters()
	off := s.off
	s.off += int64(len(b))
	o.wg.Add(1)
	o.jobs <- wjob{s, b, off, put}
}

// emit writes one batch; called by the sequencer in input order.
func (o *outputs) emit(r *result) {
	o.write(o.krakenSink(), r.kraken, true)
	o.write(o.c1, r.batch.C1, false)
	o.write(o.c2, r.batch.C2, false)
	o.write(o.u1, r.batch.U1, false)
	o.write(o.u2, r.batch.U2, false)
}

// flush waits for every queued write and flushes the ordered writers (upstream flushes every
// output at the end of each ProcessFiles).
func (o *outputs) flush() error {
	o.wg.Wait()
	for _, s := range []*sink{o.krakenSink(), o.c1, o.c2, o.u1, o.u2} {
		if s != nil && s.bw != nil {
			if err := s.bw.Flush(); err != nil {
				o.setErr(err)
			}
		}
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.err
}

// abandon aborts every s3:// output after an engine failure: a truncated object is never
// completed (an upload with parts left behind is aborted by make run, docs/run.md). Local files
// keep upstream's behaviour, and an upstream-style data error (exit 65) still completes them.
func (o *outputs) abandon() {
	o.wg.Wait()
	for _, s := range o.s3 {
		_ = s.mw.Abort()
	}
}

// close flushes and closes every file. Safe to call more than once.
func (o *outputs) close() error {
	if o.closed {
		return o.err
	}
	err := o.flush()
	o.closed = true
	if o.jobs != nil {
		close(o.jobs)
	}
	for _, f := range o.files {
		if e := f.Close(); err == nil && e != nil {
			err = e
		}
	}
	for _, s := range o.s3 {
		if err != nil {
			_ = s.mw.Abort()
		} else if e := s.mw.Close(); e != nil {
			err = e
		}
	}
	if err := stdoutSink.bw.Flush(); err != nil && o.err == nil {
		o.err = err
	}
	if o.err == nil {
		o.err = err
	}
	return o.err
}
