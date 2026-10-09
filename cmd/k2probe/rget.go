package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

func init() {
	commands["rget"] = command{
		summary: "#25 probes: parallel ranged GETs of one object to a file or discarded, rate streamed",
		run:     rget,
	}
}

// rgetLine is one streamed JSON line (stdout): kind "progress" every -every seconds, then "done".
type rgetLine struct {
	Kind      string  `json:"kind"`
	Label     string  `json:"label,omitempty"`
	UnixS     float64 `json:"unix_s"`
	ElapsedS  float64 `json:"elapsed_s"`
	Bytes     int64   `json:"bytes"`
	GBpsCum   float64 `json:"gbps_cum"`
	GBpsInt   float64 `json:"gbps_interval"`
	Requests  int64   `json:"requests"`
	Retries   int64   `json:"retries"`
	Complete  bool    `json:"complete"`
	Workers   int     `json:"workers,omitempty"`
	ChunkMiB  int64   `json:"chunk_mib,omitempty"`
	Out       string  `json:"out,omitempty"`
	Object    string  `json:"object,omitempty"`
	ObjBytes  int64   `json:"object_bytes,omitempty"`
	StoppedBy string  `json:"stopped_by,omitempty"`
	Error     string  `json:"error,omitempty"`
}

// rget fetches [start, size) of the object (an anonymous HTTPS URL pinned to its ETag, or a local
// -file) in -chunk-mib ranges on -workers goroutines, each range written at its offset into -out
// (or discarded when -out is empty), until the object is done or -seconds elapse. Only completed
// ranges count. Prints rgetLine JSON to stdout; exits non-zero on any range error.
func rget(args []string) error {
	fs := flag.NewFlagSet("rget", flag.ExitOnError)
	url := fs.String("url", "", "anonymous HTTPS URL of the object")
	etag := fs.String("etag", "", "the object's ETag (If-Match on every GET)")
	size := fs.Int64("size", 0, "the object's size in bytes (with -url)")
	file := fs.String("file", "", "read a local file instead of -url (tests)")
	out := fs.String("out", "", "write into this file at each range's offset (empty: discard)")
	workers := fs.Int("workers", 64, "concurrent ranged GETs")
	chunkMiB := fs.Int64("chunk-mib", 64, "range size in MiB")
	start := fs.Int64("start", 0, "first byte")
	seconds := fs.Float64("seconds", 0, "stop after this many seconds (0: the whole object)")
	every := fs.Float64("every", 5, "progress interval in seconds")
	label := fs.String("label", "", "a label copied into every line")
	if err := fs.Parse(args); err != nil {
		return err
	}
	var src rangeread.Source
	var ctr *rangeread.Counters
	obj := *url
	if *file != "" {
		f, err := os.Open(*file)
		if err != nil {
			return err
		}
		defer f.Close()
		st, err := f.Stat()
		if err != nil {
			return err
		}
		*size = st.Size()
		fsrc := &rangeread.FileSource{F: f}
		src, ctr, obj = fsrc, &fsrc.Counters, *file
	} else {
		if *url == "" || *size <= 0 {
			return errors.New("need -url and -size, or -file")
		}
		h := &rangeread.HTTPSource{URL: *url, ETag: *etag, Size: *size, Client: rangeread.NewHTTPClient(*workers)}
		src, ctr = h, &h.Counters
		obj = rangeread.Redact(*url)
	}
	if *workers <= 0 || *chunkMiB <= 0 || *start < 0 || *start >= *size {
		return errors.New("bad -workers, -chunk-mib or -start")
	}
	var w io.WriterAt
	if *out != "" {
		f, err := os.OpenFile(*out, os.O_RDWR|os.O_CREATE, 0o644)
		if err != nil {
			return err
		}
		defer f.Close()
		w = f
	}
	chunk := *chunkMiB << 20
	n := (*size - *start + chunk - 1) / chunk
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var timedOut atomic.Bool
	stopped := "complete"
	if *seconds > 0 {
		t := time.AfterFunc(time.Duration(*seconds*float64(time.Second)), func() { timedOut.Store(true); cancel() })
		defer t.Stop()
	}
	var next, done, okBytes atomic.Int64
	var firstErr error
	var mu sync.Mutex
	t0 := time.Now()
	enc := json.NewEncoder(os.Stdout)
	emit := func(kind string, prevB int64, prevT time.Time) (int64, time.Time) {
		now := time.Now()
		b := okBytes.Load()
		el := now.Sub(t0).Seconds()
		l := rgetLine{Kind: kind, Label: *label, UnixS: float64(now.UnixNano()) / 1e9, ElapsedS: el, Bytes: b,
			Requests: ctr.Requests.Load(), Retries: ctr.Retries.Load(), Complete: done.Load() == n}
		if el > 0 {
			l.GBpsCum = float64(b) / el / 1e9
		}
		if d := now.Sub(prevT).Seconds(); d > 0 {
			l.GBpsInt = float64(b-prevB) / d / 1e9
		}
		if kind == "done" {
			l.Workers, l.ChunkMiB, l.Out, l.Object, l.ObjBytes, l.StoppedBy = *workers, *chunkMiB, *out, obj, *size, stopped
			if firstErr != nil {
				l.Error = firstErr.Error()
			}
		}
		mu.Lock()
		_ = enc.Encode(l)
		mu.Unlock()
		return b, now
	}
	var wg sync.WaitGroup
	for k := 0; k < *workers; k++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, chunk)
			for {
				i := next.Add(1) - 1
				if i >= n || ctx.Err() != nil {
					return
				}
				off := *start + i*chunk
				b := buf[:min(chunk, *size-off)]
				err := src.ReadRange(ctx, off, b)
				if err == nil && w != nil {
					_, err = w.WriteAt(b, off)
				}
				if err != nil {
					if ctx.Err() != nil {
						return // stopped by -seconds: an unfinished range does not count
					}
					mu.Lock()
					if firstErr == nil {
						firstErr = fmt.Errorf("range at %d: %w", off, err)
					}
					mu.Unlock()
					cancel()
					return
				}
				okBytes.Add(int64(len(b)))
				done.Add(1)
			}
		}()
	}
	fin := make(chan struct{})
	go func() { wg.Wait(); close(fin) }()
	pb, pt := int64(0), t0
	tick := time.NewTicker(time.Duration(*every * float64(time.Second)))
	defer tick.Stop()
loop:
	for {
		select {
		case <-fin:
			break loop
		case <-tick.C:
			pb, pt = emit("progress", pb, pt)
		}
	}
	if timedOut.Load() && done.Load() < n {
		stopped = "seconds"
	}
	if firstErr != nil {
		stopped = "error"
	}
	emit("done", pb, pt)
	return firstErr
}
