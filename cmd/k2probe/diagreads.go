package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/classify"
	"github.com/scttfrdmn/aws-kraken2/internal/mmscan"
	"github.com/scttfrdmn/aws-kraken2/internal/mmscan/mmdump"
	"github.com/scttfrdmn/aws-kraken2/internal/taxo"
)

func init() {
	commands["diag-reads"] = command{
		summary: "per-read Law-1 diagnosis: scanner, lookups (with probe counts), hit list and ResolveTree, ours vs upstream (#44)",
		run:     diagReads,
	}
}

// diagReads takes a few paired reads whose --output lines differ between upstream and us and
// separates the stages: upstream's minimizer stream (upstream/mm_dump) against internal/mmscan;
// every lookup's value and probe count from upstream's CompactHashTable (upstream/chash_dump -m,
// on the same hash.k2d) against internal/chash; and the classification replayed through
// internal/classify twice, once from upstream's events and values and once from ours, with
// ResolveTree's arithmetic. One JSON object per read on stdout.
func diagReads(args []string) error {
	fs := flag.NewFlagSet("diag-reads", flag.ExitOnError)
	db := fs.String("db", "", "database directory (opts.k2d, hash.k2d, taxo.k2d)")
	mmd := fs.String("mmdump", "", "upstream/mm_dump harness")
	chd := fs.String("chashdump", "", "upstream/chash_dump harness")
	upLines := fs.String("up", "", "upstream's --output lines for these reads, in read order")
	ourLines := fs.String("ours", "", "our --output lines for these reads, in read order")
	conf := fs.Float64("confidence", 0, "--confidence of the runs")
	mhg := fs.Int("minimum-hit-groups", 2, "--minimum-hit-groups of the runs")
	fs.Parse(args)
	if fs.NArg() != 2 || *db == "" || *mmd == "" || *chd == "" {
		return fmt.Errorf("usage: k2probe diag-reads -db DIR -mmdump BIN -chashdump BIN -up FILE -ours FILE reads_1 reads_2")
	}
	r1, r2 := fs.Arg(0), fs.Arg(1)
	opts, err := readOptions(filepath.Join(*db, "opts.k2d"))
	if err != nil {
		return err
	}
	// 1. Upstream's minimizer streams.
	cmd := exec.Command(*mmd, filepath.Join(*db, "opts.k2d"), r1, r2)
	cmd.Stderr = io.Discard
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("mm_dump: %w", err)
	}
	d, err := mmdump.NewReader(bytes.NewReader(out))
	if err != nil {
		return err
	}
	var mates [2][]mmdump.Record
	for {
		rec, err := d.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		c := *rec
		c.Header = append([]byte(nil), rec.Header...)
		c.Seq = append([]byte(nil), rec.Seq...)
		c.Minimizers = append([]uint64(nil), rec.Minimizers...)
		c.Ambiguous = append([]bool(nil), rec.Ambiguous...)
		mates[c.FileIdx] = append(mates[c.FileIdx], c)
	}
	if len(mates[0]) != len(mates[1]) {
		return fmt.Errorf("mm_dump: %d and %d records in the two mates", len(mates[0]), len(mates[1]))
	}
	// 2. Upstream's values and probe counts for every non-ambiguous minimizer.
	var keys []uint64
	seen := map[uint64]bool{}
	for m := 0; m < 2; m++ {
		for _, rec := range mates[m] {
			for i, k := range rec.Minimizers {
				if !rec.Ambiguous[i] && !seen[k] {
					seen[k] = true
					keys = append(keys, k)
				}
			}
		}
	}
	var kb bytes.Buffer
	for _, k := range keys {
		binary.Write(&kb, binary.LittleEndian, k)
	}
	ch := exec.Command(*chd, "-m", filepath.Join(*db, "hash.k2d"))
	ch.Stdin = &kb
	ch.Stderr = io.Discard
	cout, err := ch.Output()
	if err != nil {
		return fmt.Errorf("chash_dump: %w", err)
	}
	if len(cout) != 8*len(keys) {
		return fmt.Errorf("chash_dump: %d bytes for %d keys", len(cout), len(keys))
	}
	type look struct {
		Value  uint32 `json:"value"`
		Probes uint32 `json:"probes"`
	}
	upv := map[uint64]look{}
	for i, k := range keys {
		upv[k] = look{binary.LittleEndian.Uint32(cout[8*i:]), binary.LittleEndian.Uint32(cout[8*i+4:])}
	}
	// 3. Ours.
	tab, err := chash.Mmap(filepath.Join(*db, "hash.k2d"), chash.Options{Mode: chash.Linear})
	if err != nil {
		return err
	}
	defer tab.Close()
	tax, err := taxo.Load(filepath.Join(*db, "taxo.k2d"))
	if err != nil {
		return err
	}
	sc, err := mmscan.New(int(opts.K), int(opts.L), opts.SpacedSeedMask, opts.ToggleMask, opts.DNADB, int(opts.RevcomVersion))
	if err != nil {
		return err
	}
	readLines := func(p string) []string {
		if p == "" {
			return nil
		}
		b, _ := os.ReadFile(p)
		var ls []string
		for _, l := range bytes.Split(bytes.TrimRight(b, "\n"), []byte("\n")) {
			ls = append(ls, string(l))
		}
		return ls
	}
	ups, ours := readLines(*upLines), readLines(*ourLines)
	cl, err := classify.New(tax, classify.IndexInfo{DNA: opts.DNADB, MinimumAcceptableHashValue: opts.MinimumAcceptableHashValue},
		classify.Options{Paired: true, Confidence: *conf, MinimumHitGroups: *mhg}, nil)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	bw := bufio.NewWriter(os.Stdout)
	defer bw.Flush()
	type mateDiag struct {
		Len            int      `json:"len"`
		Events         int      `json:"events"`
		ScannerEqual   bool     `json:"scanner_equal"`
		FirstScanDiff  int      `json:"first_scanner_diff"`
		UpEvents       []string `json:"upstream_events"`
		UpValues       []uint32 `json:"upstream_values_internal"`
		OurEventsAtDif []string `json:"our_events_from_first_diff,omitempty"`
	}
	type lookDiff struct {
		Key       string `json:"key"`
		UpValue   uint32 `json:"upstream_value"`
		UpProbes  uint32 `json:"upstream_probes"`
		OurValue  uint32 `json:"our_value"`
		OurProbes int    `json:"our_probes"`
		OurIdx    uint64 `json:"our_cell"`
		Home      uint64 `json:"home_cell"`
	}
	type traceEv struct {
		Event    string `json:"event"`
		Taxid    uint64 `json:"taxid_external"`
		Internal uint64 `json:"taxid_internal"`
		Value    uint64 `json:"value"`
	}
	type readDiag struct {
		ID              string     `json:"id"`
		UpstreamLine    string     `json:"upstream_line"`
		OurLine         string     `json:"our_line"`
		ReplayUpEvents  string     `json:"replay_from_upstream_events_and_values"`
		ReplayOurEvents string     `json:"replay_from_our_events_and_values"`
		Mates           []mateDiag `json:"mates"`
		Lookups         int        `json:"lookups"`
		LookupDiffs     []lookDiff `json:"lookup_diffs"`
		TraceUp         []traceEv  `json:"resolve_tree_from_upstream_events"`
		TraceOurs       []traceEv  `json:"resolve_tree_from_our_events"`
		Stage           string     `json:"diverging_stage"`
	}
	evs := func(mins []uint64, amb []bool) []string {
		s := make([]string, len(mins))
		for i := range mins {
			if amb[i] {
				s[i] = fmt.Sprintf("%016x:A", mins[i])
			} else {
				s[i] = fmt.Sprintf("%016x", mins[i])
			}
		}
		return s
	}
	for i := range mates[0] {
		rd := readDiag{}
		id := mates[0][i].Header
		if j := bytes.IndexAny(id, " \t"); j >= 0 {
			id = id[:j]
		}
		rd.ID = string(id)
		if i < len(ups) {
			rd.UpstreamLine = ups[i]
		}
		if i < len(ours) {
			rd.OurLine = ours[i]
		}
		var ourMates [2][]uint64
		var ourAmb [2][]bool
		for m := 0; m < 2; m++ {
			rec := mates[m][i]
			sc.Load(rec.Seq)
			for {
				k, a, ok := sc.Next()
				if !ok {
					break
				}
				ourMates[m] = append(ourMates[m], k)
				ourAmb[m] = append(ourAmb[m], a)
			}
			md := mateDiag{Len: len(rec.Seq), Events: len(rec.Minimizers), ScannerEqual: true, FirstScanDiff: -1,
				UpEvents: evs(rec.Minimizers, rec.Ambiguous)}
			// Upstream's value for each event (internal taxid; 0 for an ambiguous event or a miss).
			for j, k := range rec.Minimizers {
				var v uint32
				if !rec.Ambiguous[j] {
					v = upv[k].Value
				}
				md.UpValues = append(md.UpValues, v)
			}
			n := len(rec.Minimizers)
			if len(ourMates[m]) != n {
				md.ScannerEqual = false
			}
			for j := 0; j < n && j < len(ourMates[m]); j++ {
				if ourMates[m][j] != rec.Minimizers[j] || ourAmb[m][j] != rec.Ambiguous[j] {
					md.ScannerEqual, md.FirstScanDiff = false, j
					break
				}
			}
			if !md.ScannerEqual {
				if md.FirstScanDiff < 0 {
					md.FirstScanDiff = min(n, len(ourMates[m]))
				}
				md.OurEventsAtDif = evs(ourMates[m][md.FirstScanDiff:], ourAmb[m][md.FirstScanDiff:])
			}
			rd.Mates = append(rd.Mates, md)
		}
		// Lookups, over upstream's own events.
		for m := 0; m < 2; m++ {
			rec := mates[m][i]
			for j, k := range rec.Minimizers {
				if rec.Ambiguous[j] {
					continue
				}
				rd.Lookups++
				v, p, idx := tab.Find(k)
				u := upv[k]
				if v != u.Value || uint32(p) != u.Probes {
					rd.LookupDiffs = append(rd.LookupDiffs, lookDiff{fmt.Sprintf("%016x", k), u.Value, u.Probes, v, p, idx,
						chash.MurmurHash3(k) % tab.Layout.Capacity})
				}
			}
		}
		// Replays.
		replay := func(m0, m1 []uint64, a0, a1 []bool, get func(uint64) uint32) (string, []traceEv) {
			var tr []traceEv
			cl.Trace = func(e string, t, v uint64) { tr = append(tr, traceEv{e, tax.ExternalID(t), t, v}) }
			defer func() { cl.Trace = nil }()
			t := cl.NewTokens()
			t.Reset()
			for j := range m0 {
				t.Add(m0[j], a0[j])
			}
			t.MateBorder()
			for j := range m1 {
				t.Add(m1[j], a1[j])
			}
			t.Vals = t.Vals[:0]
			for _, k := range t.Keys {
				t.Vals = append(t.Vals, get(k))
			}
			w := &classify.Worker{}
			cl.Classify(t, mates[0][i].Header[:len(id)], uint32(len(mates[0][i].Seq)), uint32(len(mates[1][i].Seq)), w)
			return string(bytes.TrimRight(w.Out, "\n")), tr
		}
		rd.ReplayUpEvents, rd.TraceUp = replay(mates[0][i].Minimizers, mates[1][i].Minimizers, mates[0][i].Ambiguous,
			mates[1][i].Ambiguous, func(k uint64) uint32 { return upv[k].Value })
		rd.ReplayOurEvents, rd.TraceOurs = replay(ourMates[0], ourMates[1], ourAmb[0], ourAmb[1],
			func(k uint64) uint32 { v, _, _ := tab.Find(k); return v })
		scanOK := rd.Mates[0].ScannerEqual && rd.Mates[1].ScannerEqual
		switch {
		case !scanOK:
			rd.Stage = "scanner"
		case len(rd.LookupDiffs) > 0:
			rd.Stage = "hash/probe"
		case rd.ReplayUpEvents != rd.UpstreamLine:
			rd.Stage = "classify/taxonomy/format (upstream's own events and values replay differently)"
		case rd.ReplayOurEvents != rd.OurLine:
			rd.Stage = "reading or pipeline (our replay equals upstream; our run's line differs)"
		default:
			rd.Stage = "none found"
		}
		if err := enc.Encode(rd); err != nil {
			return err
		}
	}
	return nil
}
