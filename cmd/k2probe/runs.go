package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
	"github.com/scttfrdmn/aws-kraken2/internal/runlen"
)

func init() {
	commands["runs"] = command{
		summary: "G0c (#7): one streaming pass over hash.k2d: sha256, occupancy, run lengths, overlap tails",
		run:     runs,
	}
}

// runsSummary is summary.json: a flat object (make report renders it as a field/value table).
type runsSummary struct {
	Object             string  `json:"object"`
	ETag               string  `json:"etag,omitempty"`
	ObjectBytes        int64   `json:"object_bytes"`
	BytesStreamed      int64   `json:"bytes_streamed"`
	Complete           bool    `json:"complete"`
	SHA256             string  `json:"sha256"`
	SHA256Scope        string  `json:"sha256_scope"`
	Capacity           uint64  `json:"capacity"`
	HeaderSize         uint64  `json:"header_size"`
	KeyBits            uint64  `json:"key_bits"`
	ValueBits          uint64  `json:"value_bits"`
	Cells              uint64  `json:"cells"`
	CellsEqualCapacity bool    `json:"cells_equal_capacity"`
	Occupied           uint64  `json:"occupied"`
	OccupiedEqualsSize bool    `json:"occupied_equals_header_size"`
	LoadFactor         float64 `json:"load_factor"`
	Runs               uint64  `json:"runs,omitempty"`
	MeanRun            float64 `json:"mean_run,omitempty"`
	P50                uint64  `json:"run_p50,omitempty"`
	P90                uint64  `json:"run_p90,omitempty"`
	P99                uint64  `json:"run_p99,omitempty"`
	P999               uint64  `json:"run_p99_9,omitempty"`
	P9999              uint64  `json:"run_p99_99,omitempty"`
	P99999             uint64  `json:"run_p99_999,omitempty"`
	P999999            uint64  `json:"run_p99_9999,omitempty"`
	Longest            uint64  `json:"longest_run,omitempty"`
	LongestStart       uint64  `json:"longest_run_start_slot"`
	LongestWraps       bool    `json:"longest_run_wraps"`
	WrapJoined         bool    `json:"wrap_run_joined"`
	TheoryRuns         float64 `json:"theory_runs,omitempty"`
	TheoryRunsGELong   float64 `json:"theory_runs_ge_longest,omitempty"`
	TheoryMeanRun      float64 `json:"theory_mean_run,omitempty"`
	MissProbesFromRuns float64 `json:"miss_probes_from_runs,omitempty"`
	KnuthMiss          float64 `json:"knuth_miss_probes"`
	KnuthHit           float64 `json:"knuth_hit_probes"`
	ShardRule          string  `json:"shard_rule"`
	TailRule           string  `json:"tail_rule"`
	ChunkBytes         int64   `json:"chunk_bytes"`
	Workers            int     `json:"workers"`
	Window             int     `json:"window"`
	GOMAXPROCS         int     `json:"gomaxprocs"`
	GoVersion          string  `json:"go_version"`
	Started            string  `json:"started"`
	Finished           string  `json:"finished"`
	WallSeconds        float64 `json:"wall_seconds"`
	WallGBps           float64 `json:"wall_gb_per_s"`
	SHABusySeconds     float64 `json:"sha_busy_seconds"`
	SHAGBps            float64 `json:"sha_gb_per_s_while_busy"`
	ConsumerStallSec   float64 `json:"consumer_stall_seconds"`
	FetchBusySeconds   float64 `json:"fetch_busy_seconds_summed"`
	PerStreamMBps      float64 `json:"fetch_mb_per_s_per_stream"`
	ScanBusySeconds    float64 `json:"scan_busy_seconds_summed"`
	ScanGBpsPerCore    float64 `json:"scan_gb_per_s_per_worker"`
	SHABenchBytes      int64   `json:"sha_bench_bytes,omitempty"`
	SHABenchGBps       float64 `json:"sha_bench_gb_per_s,omitempty"`
	Requests           int64   `json:"get_requests"`
	Retries            int64   `json:"get_retries"`
}

type chunkWork struct {
	c   runlen.Chunk
	err error
}

func runs(args []string) error {
	fs := flag.NewFlagSet("runs", flag.ContinueOnError)
	file := fs.String("file", "", "local hash.k2d")
	url := fs.String("url", "", "anonymous HTTPS URL of hash.k2d (ranged GETs)")
	etag := fs.String("etag", "", "with -url: the object's ETag (sent as If-Match on every GET)")
	size := fs.Int64("size", 0, "with -url: the object's size in bytes")
	chunkMiB := fs.Int64("chunk-mib", 64, "bytes per ranged read, MiB")
	workers := fs.Int("workers", 32, "concurrent ranged reads (each also scans its chunk)")
	window := fs.Int("window", 0, "chunk buffers in flight (default 1.5 x workers)")
	limit := fs.Int64("limit", 0, "stream only the first N bytes (a pilot rung: rates only, no run statistics)")
	maxN := fs.Int("max-shards", 64, "largest shard count (a power of two); tails for 2, 4, …, this")
	out := fs.String("out", "", "output directory (required)")
	brute := fs.Bool("brute", false, "with -file: also compute everything with the brute-force reference and require equality")
	shaBench := fs.Int64("sha-bench-mib", 0, "before the pass, hash this many MiB in memory to measure the SHA-256 ceiling")
	progressGiB := fs.Int64("progress-gib", 16, "log progress every this many GiB")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *out == "" || (*file == "") == (*url == "") {
		return errors.New("usage: k2probe runs (-file F | -url U -etag E -size N) -out DIR [flags]")
	}
	if *maxN < 2 || *maxN&(*maxN-1) != 0 {
		return fmt.Errorf("-max-shards %d is not a power of two >= 2", *maxN)
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return err
	}
	sum := runsSummary{Workers: *workers, ChunkBytes: *chunkMiB << 20, GOMAXPROCS: runtime.GOMAXPROCS(0),
		GoVersion: runtime.Version()}
	if *window <= 0 {
		*window = *workers * 3 / 2
	}
	sum.Window = *window
	if *shaBench > 0 {
		sum.SHABenchBytes, sum.SHABenchGBps = shaBenchmark(*shaBench << 20)
		logf("sha-bench: %d bytes at %.3f GB/s", sum.SHABenchBytes, sum.SHABenchGBps)
	}

	var src rangeread.Source
	var counters *rangeread.Counters
	var fileForBrute *os.File
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
		src, counters, fileForBrute = fsrc, &fsrc.Counters, f
		sum.Object = *file
	} else {
		if *size <= 0 {
			return errors.New("-url needs -size")
		}
		hsrc := &rangeread.HTTPSource{URL: *url, ETag: *etag, Size: *size, Client: rangeread.NewHTTPClient(*workers)}
		src, counters = hsrc, &hsrc.Counters
		sum.Object, sum.ETag = *url, *etag
	}
	sum.ObjectBytes = *size

	var hb [chash.HeaderSize]byte
	if err := src.ReadRange(context.Background(), 0, hb[:]); err != nil {
		return fmt.Errorf("header: %w", err)
	}
	hdr, err := chash.ParseHeader(hb[:])
	if err != nil {
		return err
	}
	lay, _ := hdr.Layout()
	if lay.CellBytes != 4 {
		return fmt.Errorf("only 32-bit cells are supported (key_bits %d + value_bits %d)", hdr.KeyBits, hdr.ValueBits)
	}
	if uint64(*size) != lay.FileSize() {
		return fmt.Errorf("object is %d bytes, header implies %d", *size, lay.FileSize())
	}
	sum.Capacity, sum.HeaderSize, sum.KeyBits, sum.ValueBits = hdr.Capacity, hdr.Size, hdr.KeyBits, hdr.ValueBits
	vmask := uint32(1)<<hdr.ValueBits - 1
	bounds := runlen.Bounds(hdr.Capacity, *maxN)
	sum.ShardRule = fmt.Sprintf("shard i of N (N = 2, 4, ..., %d) owns slots [floor(i*C/N), floor((i+1)*C/N)), C = capacity; its boundary is floor((i+1)*C/N), and i = N-1 ends at the wrap (slot C-1 then slot 0)", *maxN)
	sum.TailRule = "tail(b) = 0 if slot b-1 is empty, else run_past(b) + 1: the occupied cells from b on (mod C) plus the empty cell that stops a miss probing from b-1; tail(N) = max over its N boundaries"
	acc, err := runlen.NewAccumulator(hdr.Capacity, bounds)
	if err != nil {
		return err
	}

	end := *size
	if *limit > 0 && *limit < end {
		end = *limit - *limit%4
	}
	h := sha256.New()
	var shaBusy time.Duration
	nextLog := *progressGiB << 30
	t0 := time.Now()
	sum.Started = t0.UTC().Format(time.RFC3339)
	logf("pass: %s bytes [0,%d) of %d, chunk %d MiB, %d workers, window %d, GOMAXPROCS %d",
		sum.Object, end, *size, *chunkMiB, *workers, *window, sum.GOMAXPROCS)
	st, err := rangeread.Stream(context.Background(), src, 0, end,
		rangeread.Options{Chunk: *chunkMiB << 20, Workers: *workers, Window: *window},
		func(off int64, b []byte) any {
			w := &chunkWork{}
			cb := b
			first := off
			if off < chash.HeaderSize {
				cb = b[chash.HeaderSize-off:]
				first = chash.HeaderSize
			}
			if (first-chash.HeaderSize)%4 != 0 || len(cb)%4 != 0 {
				w.err = fmt.Errorf("chunk at %d is not cell-aligned", off)
				return w
			}
			runlen.ScanChunk32(cb, uint64(first-chash.HeaderSize)/4, vmask, bounds, &w.c)
			return w
		},
		func(off int64, b []byte, wv any) error {
			w := wv.(*chunkWork)
			if w.err != nil {
				return w.err
			}
			t := time.Now()
			h.Write(b)
			shaBusy += time.Since(t)
			if err := acc.Add(&w.c); err != nil {
				return err
			}
			if done := off + int64(len(b)); done >= nextLog || done == end {
				el := time.Since(t0).Seconds()
				logf("progress: %d / %d bytes (%.2f%%) %.1f s, %.3f GB/s wall, sha busy %.3f GB/s, occupied so far %d, requests %d retries %d",
					done, end, 100*float64(done)/float64(end), el, float64(done)/el/1e9,
					float64(done)/shaBusy.Seconds()/1e9, acc.Occupied(), counters.Requests.Load(), counters.Retries.Load())
				for nextLog <= done {
					nextLog += *progressGiB << 30
				}
			}
			return nil
		})
	if err != nil {
		return err
	}
	sum.Finished = time.Now().UTC().Format(time.RFC3339)
	sum.BytesStreamed = st.Bytes
	sum.Complete = st.Bytes == *size
	sum.SHA256 = hex.EncodeToString(h.Sum(nil))
	sum.SHA256Scope = fmt.Sprintf("bytes [0,%d)", st.Bytes)
	sum.WallSeconds = st.Wall.Seconds()
	sum.WallGBps = float64(st.Bytes) / st.Wall.Seconds() / 1e9
	sum.SHABusySeconds = shaBusy.Seconds()
	sum.SHAGBps = float64(st.Bytes) / shaBusy.Seconds() / 1e9
	sum.ConsumerStallSec = st.ConsumeStall.Seconds()
	sum.FetchBusySeconds = st.FetchBusy.Seconds()
	sum.PerStreamMBps = float64(st.Bytes) / st.FetchBusy.Seconds() / 1e6
	sum.ScanBusySeconds = st.WorkBusy.Seconds()
	sum.ScanGBpsPerCore = float64(st.Bytes) / st.WorkBusy.Seconds() / 1e9
	sum.Requests, sum.Retries = counters.Requests.Load(), counters.Retries.Load()
	a := float64(hdr.Size) / float64(hdr.Capacity)
	sum.KnuthHit = 0.5 * (1 + 1/(1-a))
	sum.KnuthMiss = 0.5 * (1 + 1/((1-a)*(1-a)))
	sum.Cells, sum.Occupied = acc.Next(), acc.Occupied()
	logf("pass done: %d bytes in %.1f s (%.3f GB/s wall; sha busy %.1f s = %.3f GB/s; consumer stalled %.1f s), sha256 %s",
		st.Bytes, sum.WallSeconds, sum.WallGBps, sum.SHABusySeconds, sum.SHAGBps, sum.ConsumerStallSec, sum.SHA256)
	if !sum.Complete {
		sum.LoadFactor = float64(sum.Occupied) / float64(sum.Cells)
		return writeJSON(filepath.Join(*out, "summary.json"), sum)
	}

	res, err := acc.Finish()
	if err != nil {
		return err
	}
	if *brute {
		if fileForBrute == nil {
			return errors.New("-brute needs -file")
		}
		logf("brute: loading occupancy")
		bres, err := bruteFile(fileForBrute, hdr, vmask, bounds)
		if err != nil {
			return err
		}
		if err := runlen.Check(res, bres); err != nil {
			return fmt.Errorf("brute-force cross-check FAILED: %w", err)
		}
		logf("brute: identical (cells %d, occupied %d, runs %d, longest %d, %d boundaries)",
			bres.Cells, bres.Occupied, bres.Runs, bres.Longest, len(bres.Boundaries))
	}
	fillRunStats(&sum, res)
	if err := writeRunTables(*out, res, *maxN); err != nil {
		return err
	}
	if err := writeJSON(filepath.Join(*out, "summary.json"), sum); err != nil {
		return err
	}
	if !sum.CellsEqualCapacity || !sum.OccupiedEqualsSize {
		return fmt.Errorf("coverage check FAILED: cells %d (capacity %d), occupied %d (header size %d)",
			sum.Cells, sum.Capacity, sum.Occupied, sum.HeaderSize)
	}
	logf("checks: cells == capacity == %d; occupied == header size == %d", sum.Cells, sum.Occupied)
	return nil
}

func fillRunStats(s *runsSummary, r *runlen.Result) {
	s.Cells, s.Occupied, s.Runs = r.Cells, r.Occupied, r.Runs
	s.CellsEqualCapacity = r.Cells == s.Capacity
	s.OccupiedEqualsSize = r.Occupied == s.HeaderSize
	s.LoadFactor = float64(r.Occupied) / float64(r.Cells)
	if r.Runs > 0 {
		s.MeanRun = float64(r.Occupied) / float64(r.Runs)
	}
	s.P50, s.P90, s.P99 = r.Quantile(0.5), r.Quantile(0.9), r.Quantile(0.99)
	s.P999, s.P9999, s.P99999, s.P999999 = r.Quantile(0.999), r.Quantile(0.9999), r.Quantile(0.99999), r.Quantile(0.999999)
	s.Longest, s.LongestStart = r.Longest, r.LongestStart
	s.LongestWraps = r.LongestStart+r.Longest > r.Cells
	s.WrapJoined = r.Wrapped
	a := s.LoadFactor
	s.TheoryRuns = float64(r.Cells-r.Occupied) * (1 - math.Exp(-a))
	s.TheoryMeanRun = float64(r.Occupied) / s.TheoryRuns
	s.TheoryRunsGELong = runlen.TheoryRunsAtLeast(r.Cells, r.Occupied, r.Longest)
	s.MissProbesFromRuns = r.MissProbesFromRuns()
}

func writeRunTables(dir string, r *runlen.Result, maxN int) error {
	// Every observed length, exactly.
	if err := writeTSV(filepath.Join(dir, "hist-raw.tsv"), []string{"length", "runs"}, func(w func(...any)) {
		for _, ln := range r.Hist.Lengths() {
			w(ln[0], ln[1])
		}
	}); err != nil {
		return err
	}
	if err := writeTSV(filepath.Join(dir, "hist.tsv"),
		[]string{"lo", "hi", "observed", "theory", "residual", "rel_residual", "z"}, func(w func(...any)) {
			for _, b := range r.Buckets() {
				res := float64(b.Observed) - b.Expected
				rel, z := math.NaN(), math.NaN()
				if b.Expected > 0 {
					rel, z = res/b.Expected, res/math.Sqrt(b.Expected)
				}
				w(b.Lo, b.Hi, b.Observed, g(b.Expected), g(res), g(rel), g(z))
			}
		}); err != nil {
		return err
	}
	// For each boundary, the smallest shard count that has it.
	minN := func(j int) int {
		for n := 2; n <= maxN; n *= 2 {
			if (j+1)%(maxN/n) == 0 {
				return n
			}
		}
		return maxN
	}
	if err := writeTSV(filepath.Join(dir, "boundaries.tsv"),
		[]string{"j", "slot_b", "first_N", "slot_b_minus_1_occupied", "run_past", "tail", "run_start", "run_len"},
		func(w func(...any)) {
			for j, b := range r.Boundaries {
				w(j+1, b.B, minN(j), b.Occupied, b.RunPast, b.Tail, b.RunStart, b.RunLen)
			}
		}); err != nil {
		return err
	}
	return writeTSV(filepath.Join(dir, "tails.tsv"),
		[]string{"N", "tail_cells", "tail_bytes", "at_boundary_slot", "longest_run"}, func(w func(...any)) {
			for n := 2; n <= maxN; n *= 2 {
				t, at, _ := r.TailForN(n)
				w(n, t, 4*t, at, r.Longest)
			}
		})
}

func g(f float64) string {
	if math.IsNaN(f) {
		return "NaN"
	}
	return strconv.FormatFloat(f, 'g', 8, 64)
}

func writeTSV(path string, header []string, rows func(w func(...any))) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	bw := bufio.NewWriter(f)
	for i, h := range header {
		if i > 0 {
			bw.WriteByte('\t')
		}
		bw.WriteString(h)
	}
	bw.WriteByte('\n')
	rows(func(v ...any) {
		for i, x := range v {
			if i > 0 {
				bw.WriteByte('\t')
			}
			fmt.Fprint(bw, x)
		}
		bw.WriteByte('\n')
	})
	if err := bw.Flush(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func writeJSON(path string, v any) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := emit(f, v); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func logf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "%s k2probe: %s\n", time.Now().UTC().Format("2006-01-02T15:04:05Z"), fmt.Sprintf(format, a...))
}

func shaBenchmark(n int64) (int64, float64) {
	buf := make([]byte, 64<<20)
	for i := range buf {
		buf[i] = byte(i * 2654435761 >> 13)
	}
	h := sha256.New()
	t := time.Now()
	var done int64
	for done < n {
		k := min(int64(len(buf)), n-done)
		h.Write(buf[:k])
		done += k
	}
	h.Sum(nil)
	return done, float64(done) / time.Since(t).Seconds() / 1e9
}

// bruteFile reads the whole cell array sequentially into an occupancy vector and runs
// runlen.Brute: no chunks, no parallelism, no shared code with the streaming scan beyond the
// header decode.
func bruteFile(f *os.File, h chash.Header, vmask uint32, bounds []uint64) (*runlen.Result, error) {
	occ := make([]bool, h.Capacity)
	if _, err := f.Seek(chash.HeaderSize, 0); err != nil {
		return nil, err
	}
	br := bufio.NewReaderSize(f, 8<<20)
	var cell [4]byte
	for i := range occ {
		if _, err := io.ReadFull(br, cell[:]); err != nil {
			return nil, fmt.Errorf("brute: cell %d: %w", i, err)
		}
		occ[i] = binary.LittleEndian.Uint32(cell[:])&vmask != 0
	}
	if n, _ := br.Read(cell[:]); n != 0 {
		return nil, errors.New("brute: bytes after the last cell")
	}
	return runlen.Brute(occ, bounds)
}
