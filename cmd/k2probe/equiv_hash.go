package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
)

func init() {
	commands["equiv-hash"] = command{
		summary: "compare internal/chash lookups with upstream's (upstream/chash_dump output)",
		run:     equivHash,
	}
}

// histMax is the last exact probe-count bucket; longer probes share one tail bucket.
const histMax = 32

type hist struct {
	Buckets [histMax + 1]uint64 `json:"buckets"` // [p] = keys with p probes (index 0 unused)
	Tail    uint64              `json:"tail"`    // keys with more than histMax probes
	Max     uint32              `json:"max"`
	Sum     uint64              `json:"sum"`
	N       uint64              `json:"n"`
}

func (h *hist) add(p uint32) {
	if p <= histMax {
		h.Buckets[p]++
	} else {
		h.Tail++
	}
	h.Max = max(h.Max, p)
	h.Sum += uint64(p)
	h.N++
}

func (h *hist) mean() float64 {
	if h.N == 0 {
		return 0
	}
	return float64(h.Sum) / float64(h.N)
}

type equivResult struct {
	Label           string `json:"label"`
	Hash            string `json:"hash"`
	Keys            string `json:"keys"`
	Expect          string `json:"expect"`
	Mode            string `json:"mode"`
	Load            string `json:"load"`
	Capacity        uint64 `json:"capacity"`
	Size            uint64 `json:"size"`
	KeyBits         uint64 `json:"key_bits"`
	ValueBits       uint64 `json:"value_bits"`
	CellBytes       int    `json:"cell_bytes"`
	N               uint64 `json:"n_keys"`
	Compared        uint64 `json:"compared"`
	UpstreamHits    uint64 `json:"upstream_hits"`
	GoHits          uint64 `json:"go_hits"`
	ValueMismatches uint64 `json:"value_mismatches"`
	ProbeMismatches uint64 `json:"probe_mismatches"`
	// GetBatch (classify's batched lookup, 128 keys a batch) against upstream's values.
	BatchValueMismatches uint64  `json:"batch_value_mismatches"`
	BatchGetSeconds      float64 `json:"batch_get_s"`
	LoadSeconds          float64 `json:"load_s"`
	GetSeconds           float64 `json:"get_s"`
	GetNsPerKey          float64 `json:"get_ns_per_key"`
	UpstreamHitHist      hist    `json:"upstream_probe_hist_hits"`
	UpstreamMissHist     hist    `json:"upstream_probe_hist_misses"`
	GoHitHist            hist    `json:"go_probe_hist_hits"`
	GoMissHist           hist    `json:"go_probe_hist_misses"`
}

func equivHash(args []string) error {
	fs := flag.NewFlagSet("equiv-hash", flag.ContinueOnError)
	hashPath := fs.String("hash", "", "hash.k2d")
	keysPath := fs.String("keys", "", "keys: uint64 LE")
	expectPath := fs.String("expect", "", "upstream chash_dump output: per key uint32 LE value, uint32 LE probes")
	modeName := fs.String("mode", "linear", "probe mode: linear (upstream default build) or double")
	load := fs.String("load", "ram", "table load: ram (parallel pread) or mmap")
	stop := fs.Bool("stop", true, "stop at the first mismatch with full detail (otherwise count them all)")
	label := fs.String("label", "", "label for the summary")
	jsonOut := fs.String("json", "", "write the summary as JSON to this file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *hashPath == "" || *keysPath == "" || *expectPath == "" {
		return errors.New("-hash, -keys and -expect are required")
	}
	mode, err := chash.ParseMode(*modeName)
	if err != nil {
		return err
	}
	keys, err := readU64(*keysPath)
	if err != nil {
		return err
	}
	exp, err := readU32(*expectPath)
	if err != nil {
		return err
	}
	if len(exp) != 2*len(keys) {
		return fmt.Errorf("%s has %d records, %s has %d keys", *expectPath, len(exp)/2, *keysPath, len(keys))
	}

	t0 := time.Now()
	var tab *chash.Table
	switch *load {
	case "ram":
		tab, err = chash.Load(*hashPath, chash.Options{Mode: mode})
	case "mmap":
		tab, err = chash.Mmap(*hashPath, chash.Options{Mode: mode})
	default:
		err = fmt.Errorf("unknown -load %q", *load)
	}
	if err != nil {
		return err
	}
	defer tab.Close()
	loadS := time.Since(t0).Seconds()

	// Timed lookup pass, then the comparison.
	vals := make([]uint32, len(keys))
	probes := make([]uint32, len(keys))
	t1 := time.Now()
	for i, k := range keys {
		v, p := tab.Get(k)
		vals[i], probes[i] = v, uint32(p)
	}
	getS := time.Since(t1).Seconds()

	r := equivResult{
		Label: *label, Hash: *hashPath, Keys: *keysPath, Expect: *expectPath,
		Mode: mode.String(), Load: *load,
		Capacity: tab.Header.Capacity, Size: tab.Header.Size,
		KeyBits: tab.Header.KeyBits, ValueBits: tab.Header.ValueBits, CellBytes: tab.Layout.CellBytes,
		N: uint64(len(keys)), LoadSeconds: loadS, GetSeconds: getS,
	}
	if len(keys) > 0 {
		r.GetNsPerKey = getS * 1e9 / float64(len(keys))
	}
	var firstErr error
	for i, k := range keys {
		uv, up := exp[2*i], exp[2*i+1]
		gv, gp := vals[i], probes[i]
		r.Compared++
		if uv != 0 {
			r.UpstreamHits++
			r.UpstreamHitHist.add(up)
		} else {
			r.UpstreamMissHist.add(up)
		}
		if gv != 0 {
			r.GoHits++
			r.GoHitHist.add(gp)
		} else {
			r.GoMissHist.add(gp)
		}
		if uv != gv {
			r.ValueMismatches++
		}
		if up != gp {
			r.ProbeMismatches++
		}
		if (uv != gv || up != gp) && *stop {
			firstErr = fmt.Errorf("mismatch at key %d:\n%s", i, mismatchDetail(tab, k, uv, up))
			break
		}
	}
	var bs chash.BatchScratch
	bv := make([]uint32, 0, 128)
	t2 := time.Now()
	for off := 0; off < len(keys); off += 128 {
		batch := keys[off:min(off+128, len(keys))]
		bv = tab.GetBatch(batch, bv[:0], &bs)
		for i, v := range bv {
			if v != exp[2*(off+i)] {
				r.BatchValueMismatches++
			}
		}
	}
	r.BatchGetSeconds = time.Since(t2).Seconds()
	if r.BatchValueMismatches > 0 && firstErr == nil {
		firstErr = fmt.Errorf("GetBatch: %d value mismatches", r.BatchValueMismatches)
	}
	printEquiv(&r)
	if *jsonOut != "" {
		b, _ := json.MarshalIndent(&r, "", "  ")
		if err := os.WriteFile(*jsonOut, append(b, '\n'), 0o644); err != nil {
			return err
		}
	}
	return firstErr
}

func mismatchDetail(tab *chash.Table, key uint64, uv, up uint32) string {
	hc := chash.MurmurHash3(key)
	l := tab.Layout
	gv, gp, gidx := tab.Find(key)
	s := fmt.Sprintf("  key       %#016x\n  hc        %#016x\n  home      %d\n  compacted %#x (key_bits %d)\n",
		key, hc, hc%l.Capacity, hc>>(64-l.KeyBits), l.KeyBits)
	s += fmt.Sprintf("  upstream  value %d probes %d\n  go        value %d probes %d final idx %d (mode %v)\n",
		uv, up, gv, gp, gidx, tab.Mode)
	s += "  go probe path (idx: hashed_key value):\n"
	idx := hc % l.Capacity
	step := uint64(1)
	if tab.Mode == chash.Double {
		step = (hc >> 8) | 1
	}
	for n := 0; n < int(max(up, uint32(gp)))+2 && n < 64; n++ {
		raw, _ := tab.Cell(idx)
		k, v := l.Decode(raw)
		s += fmt.Sprintf("    %d: %#x %d\n", idx, k, v)
		idx = (idx + step) % l.Capacity
	}
	return s
}

func printEquiv(r *equivResult) {
	fmt.Printf("equiv-hash %s: mode=%s load=%s capacity=%d size=%d key_bits=%d value_bits=%d cell_bytes=%d\n",
		r.Label, r.Mode, r.Load, r.Capacity, r.Size, r.KeyBits, r.ValueBits, r.CellBytes)
	fmt.Printf("  keys %d compared %d | upstream hits %d, go hits %d | value mismatches %d, probe mismatches %d\n",
		r.N, r.Compared, r.UpstreamHits, r.GoHits, r.ValueMismatches, r.ProbeMismatches)
	fmt.Printf("  GetBatch value mismatches %d (%.3f s)\n", r.BatchValueMismatches, r.BatchGetSeconds)
	// Hits found past the home cell depend on the probe sequence; a mode the table was not built
	// with finds only false positives there.
	fmt.Printf("  hits at the home cell: upstream %d, go %d | past it: upstream %d, go %d\n",
		r.UpstreamHitHist.Buckets[1], r.GoHitHist.Buckets[1],
		r.UpstreamHits-r.UpstreamHitHist.Buckets[1], r.GoHits-r.GoHitHist.Buckets[1])
	fmt.Printf("  go load %.3fs, get %.3fs (%.1f ns/key, 1 thread)\n", r.LoadSeconds, r.GetSeconds, r.GetNsPerKey)
	for _, h := range []struct {
		name string
		h    *hist
	}{{"upstream hits", &r.UpstreamHitHist}, {"upstream misses", &r.UpstreamMissHist},
		{"go hits", &r.GoHitHist}, {"go misses", &r.GoMissHist}} {
		fmt.Printf("  probes %-15s n=%d mean=%.3f max=%d:", h.name, h.h.N, h.h.mean(), h.h.Max)
		last := 0
		for p := histMax; p >= 1; p-- {
			if h.h.Buckets[p] != 0 {
				last = p
				break
			}
		}
		for p := 1; p <= last; p++ {
			fmt.Printf(" %d:%d", p, h.h.Buckets[p])
		}
		if h.h.Tail != 0 {
			fmt.Printf(" >%d:%d", histMax, h.h.Tail)
		}
		fmt.Println()
	}
}

func readU64(path string) ([]uint64, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b)%8 != 0 {
		return nil, fmt.Errorf("%s: %d bytes is not a whole number of uint64", path, len(b))
	}
	out := make([]uint64, len(b)/8)
	for i := range out {
		out[i] = binary.LittleEndian.Uint64(b[8*i:])
	}
	return out, nil
}

func readU32(path string) ([]uint32, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(b)%8 != 0 {
		return nil, fmt.Errorf("%s: %d bytes is not a whole number of (uint32, uint32) records", path, len(b))
	}
	out := make([]uint32, len(b)/4)
	for i := range out {
		out[i] = binary.LittleEndian.Uint32(b[4*i:])
	}
	return out, nil
}
