// Package rangeread streams a large object in order while fetching it with parallel ranged
// reads: a local file (pread) or an anonymous HTTPS object (S3 ranged GETs pinned to one ETag
// with If-Match). It is the simple in-order streaming reader G0c's run-length pass uses (#7); it
// is not the engine's loader.
package rangeread

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Source fills dst with the bytes at [off, off+len(dst)).
type Source interface {
	ReadRange(ctx context.Context, off int64, dst []byte) error
}

// Counters are a source's request accounting.
type Counters struct {
	Requests atomic.Int64 // every attempt, including retries
	Retries  atomic.Int64
	Bytes    atomic.Int64
}

// FileSource reads a local file.
type FileSource struct {
	F *os.File
	Counters
}

// ReadRange implements Source.
func (s *FileSource) ReadRange(_ context.Context, off int64, dst []byte) error {
	s.Requests.Add(1)
	n, err := s.F.ReadAt(dst, off)
	s.Bytes.Add(int64(n))
	if n == len(dst) {
		return nil
	}
	if err == nil || errors.Is(err, io.EOF) {
		err = io.ErrUnexpectedEOF
	}
	return err
}

// HTTPSource does anonymous ranged GETs of one object. Every GET carries If-Match: ETag, so a
// changed object fails the pass rather than mixing versions; the response's ETag and the total in
// Content-Range are checked too.
type HTTPSource struct {
	URL        string
	ETag       string // without quotes
	Size       int64  // the object's size, checked against Content-Range
	Client     *http.Client
	MaxRetries int // attempts per range beyond the first (default 5)
	Counters
}

// NewHTTPClient is a client sized for `conns` concurrent ranged GETs to one host.
func NewHTTPClient(conns int) *http.Client {
	tr := &http.Transport{
		Proxy:               nil,
		DialContext:         (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		MaxIdleConns:        conns * 2,
		MaxIdleConnsPerHost: conns * 2,
		MaxConnsPerHost:     conns * 2,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
		DisableCompression:  true,
		ReadBufferSize:      256 << 10,
		ForceAttemptHTTP2:   false,
	}
	return &http.Client{Transport: tr}
}

// ReadRange implements Source.
func (s *HTTPSource) ReadRange(ctx context.Context, off int64, dst []byte) error {
	retries := s.MaxRetries
	if retries <= 0 {
		retries = 5
	}
	var err error
	for attempt := 0; attempt <= retries; attempt++ {
		if attempt > 0 {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			s.Retries.Add(1)
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(1<<attempt) * 250 * time.Millisecond):
			}
		}
		s.Requests.Add(1)
		var permanent bool
		permanent, err = s.get(ctx, off, dst)
		if err == nil || permanent {
			return err
		}
	}
	return fmt.Errorf("rangeread: %d bytes at %d after %d attempts: %w", len(dst), off, retries+1, err)
}

func (s *HTTPSource) get(ctx context.Context, off int64, dst []byte) (permanent bool, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.URL, nil)
	if err != nil {
		return true, err
	}
	last := off + int64(len(dst)) - 1
	req.Header.Set("Range", "bytes="+strconv.FormatInt(off, 10)+"-"+strconv.FormatInt(last, 10))
	if s.ETag != "" {
		req.Header.Set("If-Match", `"`+s.ETag+`"`)
	}
	resp, err := s.Client.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusPreconditionFailed:
		return true, fmt.Errorf("rangeread: %s: ETag is no longer %q (412)", s.URL, s.ETag)
	case resp.StatusCode != http.StatusPartialContent:
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return resp.StatusCode < 500 && resp.StatusCode != 429, fmt.Errorf("rangeread: %s range %d-%d: %s: %s",
			s.URL, off, last, resp.Status, strings.TrimSpace(string(b)))
	}
	if s.ETag != "" && strings.Trim(resp.Header.Get("ETag"), `"`) != s.ETag {
		return true, fmt.Errorf("rangeread: response ETag %s, want %q", resp.Header.Get("ETag"), s.ETag)
	}
	want := fmt.Sprintf("bytes %d-%d/", off, last)
	cr := resp.Header.Get("Content-Range")
	if !strings.HasPrefix(cr, want) || (s.Size > 0 && cr != want+strconv.FormatInt(s.Size, 10)) {
		return true, fmt.Errorf("rangeread: Content-Range %q, want %s%d", cr, want, s.Size)
	}
	n, err := io.ReadFull(resp.Body, dst)
	s.Bytes.Add(int64(n))
	if err != nil {
		return false, fmt.Errorf("rangeread: body at %d: %w", off, err)
	}
	return false, nil
}

// Options size the stream.
type Options struct {
	Chunk   int64 // bytes per ranged read
	Workers int   // concurrent reads (and per-chunk work)
	Window  int   // chunk buffers in flight, including those waiting for the in-order consumer
}

// Stats are the stream's timings.
type Stats struct {
	Chunks       int
	Bytes        int64
	Wall         time.Duration
	FetchBusy    time.Duration // summed over workers: time inside Source.ReadRange
	WorkBusy     time.Duration // summed over workers: time inside work
	ConsumeBusy  time.Duration // in-order consumer: time inside consume
	ConsumeStall time.Duration // in-order consumer: time waiting for the next chunk
}

type result struct {
	i   int
	off int64
	buf []byte
	w   any
	err error
}

// Stream reads [start, end) of src in chunks of opt.Chunk bytes (the last may be shorter). Each
// chunk is fetched and passed to work (concurrently, any order) and then to consume (one at a
// time, in offset order). The buffer is reused after consume returns. Any error stops the
// stream.
func Stream(ctx context.Context, src Source, start, end int64, opt Options,
	work func(off int64, b []byte) any,
	consume func(off int64, b []byte, w any) error) (Stats, error) {
	if opt.Chunk <= 0 || opt.Workers <= 0 {
		return Stats{}, errors.New("rangeread: Chunk and Workers must be positive")
	}
	if opt.Window < opt.Workers {
		opt.Window = opt.Workers
	}
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	n := int((end - start + opt.Chunk - 1) / opt.Chunk)
	if end <= start {
		n = 0
	}
	t0 := time.Now()
	pool := make(chan []byte, opt.Window)
	for i := 0; i < opt.Window; i++ {
		pool <- nil
	}
	type job struct {
		i   int
		off int64
		buf []byte
	}
	jobs := make(chan job)
	results := make(chan result, opt.Window)
	var fetchNs, workNs atomic.Int64
	// The dispatcher takes a buffer before handing out a chunk, in chunk order, so the buffers in
	// flight always belong to the oldest unconsumed chunks and the consumer cannot starve.
	go func() {
		defer close(jobs)
		for i := 0; i < n; i++ {
			var b []byte
			select {
			case b = <-pool:
			case <-ctx.Done():
				return
			}
			off := start + int64(i)*opt.Chunk
			sz := min(opt.Chunk, end-off)
			if int64(cap(b)) < sz {
				b = make([]byte, opt.Chunk)
			}
			select {
			case jobs <- job{i, off, b[:sz]}:
			case <-ctx.Done():
				return
			}
		}
	}()
	var wg sync.WaitGroup
	for w := 0; w < opt.Workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				t := time.Now()
				err := src.ReadRange(ctx, j.off, j.buf)
				fetchNs.Add(int64(time.Since(t)))
				r := result{i: j.i, off: j.off, buf: j.buf, err: err}
				if err == nil && work != nil {
					t = time.Now()
					r.w = work(j.off, j.buf)
					workNs.Add(int64(time.Since(t)))
				}
				select {
				case results <- r:
				case <-ctx.Done():
					return
				}
			}
		}()
	}
	go func() { wg.Wait(); close(results) }()

	var st Stats
	pending := map[int]result{}
	next := 0
	var err error
	tw := time.Now()
	for r := range results {
		if r.err != nil {
			err = r.err
			break
		}
		pending[r.i] = r
		for {
			p, ok := pending[next]
			if !ok {
				break
			}
			st.ConsumeStall += time.Since(tw)
			delete(pending, next)
			t := time.Now()
			if e := consume(p.off, p.buf, p.w); e != nil {
				err = e
				break
			}
			st.ConsumeBusy += time.Since(t)
			tw = time.Now()
			st.Chunks++
			st.Bytes += int64(len(p.buf))
			next++
			pool <- p.buf
		}
		if err != nil {
			break
		}
	}
	cancel()
	for range results { // drain so workers exit
	}
	st.Wall = time.Since(t0)
	st.FetchBusy = time.Duration(fetchNs.Load())
	st.WorkBusy = time.Duration(workNs.Load())
	if err == nil && next != n {
		err = fmt.Errorf("rangeread: stream ended after %d of %d chunks", next, n)
	}
	return st, err
}
