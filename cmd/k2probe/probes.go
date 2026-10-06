package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"hash/fnv"
	"io"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/classify"
	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
	"github.com/scttfrdmn/aws-kraken2/internal/mmscan"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
	"github.com/scttfrdmn/aws-kraken2/internal/seqio"
)

func init() {
	commands["probes"] = command{
		summary: "G0c (#8): sample classify's lookups from real reads, resolve each with point GETs, count probes",
		run:     probes,
	}
}

type sampleSpec struct {
	acc   string
	files []string
}

type sampleFlag []sampleSpec

func (s *sampleFlag) String() string { return fmt.Sprint(*s) }
func (s *sampleFlag) Set(v string) error {
	acc, files, ok := strings.Cut(v, "=")
	if !ok || acc == "" || files == "" {
		return fmt.Errorf("want ACC=reads_1.fq[,reads_2.fq], got %q", v)
	}
	f := strings.Split(files, ",")
	if len(f) > 2 {
		return fmt.Errorf("%s: at most two files (a mate pair)", acc)
	}
	*s = append(*s, sampleSpec{acc, f})
	return nil
}

// lookup is one sampled lookup and its resolution.
type lookup struct {
	ordinal  uint64 // index of this lookup in the sample's lookup stream
	read     uint64 // 0-based read (pair) index
	key      uint64 // the minimizer
	home     uint64
	value    uint32
	probes   int
	gets     int
	bytes    int64
	finalIdx uint64
}

// windowSource is a chash.CellSource over point GETs: a miss on its cache fetches a window of
// cells starting at the requested slot (so the first fetch starts at the home slot), clipped at
// the end of the table. Probe's own modulo takes the walk from slot C-1 to slot 0, which then
// misses the cache and fetches a window at 0: the wrap.
type windowSource struct {
	src    rangeread.Source
	layout chash.Layout
	cells  uint64 // window length in cells
	wins   []window
	gets   int
	bytes  int64
}

type window struct {
	start uint64
	data  []byte
}

func (w *windowSource) Cell(idx uint64) (uint64, error) {
	if idx >= w.layout.Capacity {
		return 0, fmt.Errorf("cell %d out of range", idx)
	}
	for _, win := range w.wins {
		if idx >= win.start && idx < win.start+uint64(len(win.data)/4) {
			o := 4 * (idx - win.start)
			return uint64(uint32(win.data[o]) | uint32(win.data[o+1])<<8 | uint32(win.data[o+2])<<16 | uint32(win.data[o+3])<<24), nil
		}
	}
	n := min(w.cells, w.layout.Capacity-idx)
	b := make([]byte, 4*n)
	if err := w.src.ReadRange(context.Background(), int64(chash.HeaderSize+4*idx), b); err != nil {
		return 0, err
	}
	w.gets++
	w.bytes += int64(len(b))
	w.wins = append(w.wins, window{idx, b})
	return w.Cell(idx)
}

func probes(args []string) error {
	fs := flag.NewFlagSet("probes", flag.ContinueOnError)
	file := fs.String("file", "", "local hash.k2d")
	url := fs.String("url", "", "anonymous HTTPS URL of hash.k2d")
	etag := fs.String("etag", "", "with -url: the object's ETag (If-Match on every GET)")
	size := fs.Int64("size", 0, "with -url: the object's size")
	optsPath := fs.String("opts", "", "the database's opts.k2d (required)")
	runsSummary := fs.String("runs-summary", "", "optional: `k2probe runs` summary.json for the same object; its miss_probes_from_runs (the mean miss length the measured runs imply) becomes a second miss expectation")
	var samples sampleFlag
	fs.Var(&samples, "sample", "ACC=reads_1.fq[,reads_2.fq] (repeatable; plain FASTQ/FASTA)")
	n := fs.Int("n", 10000, "lookups to sample per workload")
	seed := fs.Uint64("seed", 1, "sampling seed (each sample also mixes in its accession)")
	windowKiB := fs.Int("window-kib", 64, "bytes per point GET, KiB")
	workers := fs.Int("workers", 32, "concurrent lookups")
	out := fs.String("out", "", "output directory (required)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *out == "" || *optsPath == "" || len(samples) == 0 || (*file == "") == (*url == "") || *windowKiB%4 != 0 {
		return errors.New("usage: k2probe probes (-file F | -url U -etag E -size N) -opts OPTS -sample ACC=r1[,r2] ... -out DIR")
	}
	if err := os.MkdirAll(*out, 0o755); err != nil {
		return err
	}
	ob, err := os.ReadFile(*optsPath)
	if err != nil {
		return err
	}
	o, err := kdb.ParseOptions(ob)
	if err != nil {
		return err
	}
	// One source, shared by every worker (FileSource and HTTPSource are safe for concurrent use),
	// so its Counters see every GET and every retry of the run.
	var src rangeread.Source
	var counters *rangeread.Counters
	if *file != "" {
		f, err := os.Open(*file)
		if err != nil {
			return err
		}
		defer f.Close()
		s := &rangeread.FileSource{F: f}
		src, counters = s, &s.Counters
	} else {
		s := &rangeread.HTTPSource{URL: *url, ETag: *etag, Size: *size, Client: rangeread.NewHTTPClient(*workers)}
		src, counters = s, &s.Counters
	}
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
		return errors.New("only 32-bit cells are supported")
	}
	if *size > 0 && uint64(*size) != lay.FileSize() {
		return fmt.Errorf("object is %d bytes, header implies %d", *size, lay.FileSize())
	}
	alpha := float64(hdr.Size) / float64(hdr.Capacity)
	knuthHit := 0.5 * (1 + 1/(1-alpha))
	knuthMiss := 0.5 * (1 + 1/((1-alpha)*(1-alpha)))
	logf("probes: table capacity %d size %d alpha %.6f; k=%d l=%d min_hash=%d; expected probes hit %.4f miss %.4f",
		hdr.Capacity, hdr.Size, alpha, o.K, o.L, o.MinimumAcceptableHashValue, knuthHit, knuthMiss)

	summary := map[string]any{
		"object": firstNonEmpty(*url, *file), "etag": *etag, "capacity": hdr.Capacity, "header_size": hdr.Size,
		"key_bits": hdr.KeyBits, "load_factor": alpha, "k": o.K, "l": o.L,
		"minimum_acceptable_hash_value":     o.MinimumAcceptableHashValue,
		"knuth_hit_probes_uniform_key_null": knuthHit, "knuth_miss_probes": knuthMiss,
		"knuth_formulas": "hit 1/2(1+1/(1-a)): the uniform-key null (a stored key chosen uniformly); real lookups are content-weighted, so it is not an expectation for them. miss 1/2(1+1/(1-a)^2) (Knuth TAOCP vol. 3, 6.4, Algorithm L); misses are also compared with miss_probes_from_runs, the mean miss length the measured runs imply",
		"n_per_sample":   *n, "seed": *seed, "window_bytes": *windowKiB << 10, "workers": *workers,
		"go_version": runtime.Version(),
	}
	// The measured-runs miss expectation, if given: only from a pass over the same object (ETag).
	missRuns := math.NaN()
	if *runsSummary != "" {
		var rs struct {
			ETag     string  `json:"etag"`
			Complete bool    `json:"complete"`
			Miss     float64 `json:"miss_probes_from_runs"`
		}
		b, err := os.ReadFile(*runsSummary)
		if err != nil {
			return err
		}
		if err := json.Unmarshal(b, &rs); err != nil {
			return fmt.Errorf("%s: %w", *runsSummary, err)
		}
		if !rs.Complete || rs.Miss <= 0 || rs.ETag != *etag {
			return fmt.Errorf("%s: not a complete pass over ETag %q (complete %v, etag %q)", *runsSummary, *etag, rs.Complete, rs.ETag)
		}
		missRuns = rs.Miss
		summary["miss_probes_from_runs"] = missRuns
		summary["miss_probes_from_runs_source"] = *runsSummary
	}
	var sumRows, histRows [][]any
	start := time.Now()
	for _, sp := range samples {
		t0 := time.Now()
		sample, pop, reads, err := sampleLookups(sp, o, *n, *seed)
		if err != nil {
			return fmt.Errorf("%s: %w", sp.acc, err)
		}
		logf("%s: %d reads, %d lookups in the population; sampled %d (%.1f s)", sp.acc, reads, pop, len(sample), time.Since(t0).Seconds())
		t1 := time.Now()
		if err := resolve(sample, lay, src, *windowKiB<<8, *workers); err != nil {
			return fmt.Errorf("%s: %w", sp.acc, err)
		}
		el := time.Since(t1).Seconds()
		var gets int
		for _, l := range sample {
			gets += l.gets
		}
		logf("%s: resolved %d lookups with %d GETs in %.1f s", sp.acc, len(sample), gets, el)
		summary[sp.acc+"_reads"] = reads
		summary[sp.acc+"_lookup_population"] = pop
		summary[sp.acc+"_sampled"] = len(sample)
		summary[sp.acc+"_gets"] = gets
		summary[sp.acc+"_resolve_seconds"] = el
		if err := writeLookups(filepath.Join(*out, "lookups-"+sp.acc+".tsv"), sample); err != nil {
			return err
		}
		for _, class := range []string{"hit", "miss", "all"} {
			var ps []int
			for _, l := range sample {
				if class == "all" || (class == "hit") == (l.value != 0) {
					ps = append(ps, l.probes)
				}
			}
			knuth, measured := math.NaN(), math.NaN()
			switch class {
			case "hit":
				knuth = knuthHit // the uniform-key null: real lookups are content-weighted
			case "miss":
				knuth, measured = knuthMiss, missRuns
			}
			r := probeStats(ps)
			frac := float64(len(ps)) / float64(len(sample))
			sumRows = append(sumRows, []any{sp.acc, class, len(ps), g(frac), g(r.mean), g(knuth), g(r.mean - knuth),
				g(measured), g(r.mean - measured), r.p50, r.p90, r.p99, r.max})
			summary[sp.acc+"_"+class+"_fraction"] = frac
			summary[sp.acc+"_"+class+"_mean_probes"] = r.mean
			summary[sp.acc+"_"+class+"_max_probes"] = r.max
			if class != "all" {
				for _, kv := range r.hist {
					histRows = append(histRows, []any{sp.acc, class, kv[0], kv[1]})
				}
			}
		}
	}
	// Every ranged GET this run made (header, windows, extensions), retries included.
	summary["get_requests"] = counters.Requests.Load()
	summary["get_retries"] = counters.Retries.Load()
	summary["wall_seconds"] = time.Since(start).Seconds()
	if err := writeTSV(filepath.Join(*out, "probe-summary.tsv"),
		[]string{"sample", "class", "lookups", "fraction", "mean_probes", "knuth", "mean_minus_knuth",
			"measured_runs", "mean_minus_measured_runs", "p50", "p90", "p99", "max"},
		func(w func(...any)) {
			for _, r := range sumRows {
				w(r...)
			}
		}); err != nil {
		return err
	}
	if err := writeTSV(filepath.Join(*out, "probe-hist.tsv"), []string{"sample", "class", "probes", "lookups"},
		func(w func(...any)) {
			for _, r := range histRows {
				w(r...)
			}
		}); err != nil {
		return err
	}
	return writeJSON(filepath.Join(*out, "summary.json"), summary)
}

func firstNonEmpty(a ...string) string {
	for _, s := range a {
		if s != "" {
			return s
		}
	}
	return ""
}

// sampleLookups scans every read (pair) as classify does and draws n lookups uniformly from the
// stream of minimizers classify would look up (reservoir sampling, Algorithm R). The lookup
// stream is classify.Tokens' Keys: non-ambiguous minimizers that differ from the previous one in
// the same mate (and pass minimum_acceptable_hash_value, 0 here), mate by mate, read by read.
func sampleLookups(sp sampleSpec, o kdb.Options, n int, seed uint64) ([]*lookup, uint64, uint64, error) {
	sc, err := mmscan.New(int(o.K), int(o.L), o.SpacedSeedMask, o.ToggleMask, o.DNADB, int(o.RevcomVersion))
	if err != nil {
		return nil, 0, 0, err
	}
	tk := classify.NewTokens(classify.IndexInfo{DNA: o.DNADB, MinimumAcceptableHashValue: o.MinimumAcceptableHashValue}, nil)
	hf := fnv.New64a()
	hf.Write([]byte(sp.acc))
	rng := rand.New(rand.NewPCG(seed, hf.Sum64()))
	var res []*lookup
	var pop, reads uint64
	take := func() {
		for _, k := range tk.Keys {
			if len(res) < n {
				res = append(res, &lookup{ordinal: pop, read: reads, key: k})
			} else if j := rng.Uint64N(pop + 1); j < uint64(n) {
				res[j] = &lookup{ordinal: pop, read: reads, key: k}
			}
			pop++
		}
	}
	r1, err := seqio.Open(sp.files[0], seqio.CompressionNone)
	if err != nil {
		return nil, 0, 0, err
	}
	defer r1.Close()
	if len(sp.files) == 1 {
		for {
			recs, err := r1.NextBatch(4096)
			if err == io.EOF {
				break
			}
			if err != nil {
				return nil, 0, 0, err
			}
			for i := range recs {
				tk.Reset()
				tk.Scan(sc, recs[i].Seq)
				take()
				reads++
			}
		}
	} else {
		r2, err := seqio.Open(sp.files[1], seqio.CompressionNone)
		if err != nil {
			return nil, 0, 0, err
		}
		defer r2.Close()
		pr := seqio.NewPairedReader(r1, r2)
		for {
			m1, m2, err := pr.NextBatch(4096)
			if err == io.EOF {
				break
			}
			if err != nil {
				return nil, 0, 0, err
			}
			for i := range m1 {
				tk.Reset()
				tk.Scan(sc, m1[i].Seq)
				tk.MateBorder()
				tk.Scan(sc, m2[i].Seq)
				take()
				reads++
			}
		}
	}
	if nf, first := r1.Faults(); nf > 0 {
		return nil, 0, 0, fmt.Errorf("%d malformed records (first: %s)", nf, first)
	}
	sort.Slice(res, func(i, j int) bool { return res[i].ordinal < res[j].ordinal })
	return res, pop, reads, nil
}

func resolve(ls []*lookup, lay chash.Layout, src rangeread.Source, windowCells, workers int) error {
	jobs := make(chan *lookup)
	errs := make(chan error, workers)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for l := range jobs {
				ws := &windowSource{src: src, layout: lay, cells: uint64(windowCells)}
				hc := chash.MurmurHash3(l.key)
				l.home = hc % lay.Capacity
				v, p, idx, err := chash.Probe(lay, chash.Linear, hc, ws)
				if err != nil {
					errs <- err
					for range jobs {
					}
					return
				}
				l.value, l.probes, l.finalIdx, l.gets, l.bytes = v, p, idx, ws.gets, ws.bytes
			}
		}()
	}
	for _, l := range ls {
		jobs <- l
	}
	close(jobs)
	wg.Wait()
	close(errs)
	return <-errs
}

func writeLookups(path string, ls []*lookup) error {
	return writeTSV(path, []string{"ordinal", "read", "minimizer", "home_slot", "value", "hit", "probes", "final_slot", "gets", "bytes"},
		func(w func(...any)) {
			for _, l := range ls {
				w(l.ordinal, l.read, fmt.Sprintf("%016x", l.key), l.home, l.value, l.value != 0, l.probes, l.finalIdx, l.gets, l.bytes)
			}
		})
}

type pstats struct {
	mean          float64
	p50, p90, p99 int
	max           int
	hist          [][2]int
}

func probeStats(ps []int) pstats {
	var r pstats
	if len(ps) == 0 {
		r.mean = math.NaN()
		return r
	}
	s := append([]int(nil), ps...)
	sort.Ints(s)
	var tot int
	cnt := map[int]int{}
	for _, p := range s {
		tot += p
		cnt[p]++
	}
	r.mean = float64(tot) / float64(len(s))
	q := func(f float64) int { return s[int(math.Ceil(f*float64(len(s))))-1] }
	r.p50, r.p90, r.p99, r.max = q(0.5), q(0.9), q(0.99), s[len(s)-1]
	for p, c := range cnt {
		r.hist = append(r.hist, [2]int{p, c})
	}
	sort.Slice(r.hist, func(i, j int) bool { return r.hist[i][0] < r.hist[j][0] })
	return r
}
