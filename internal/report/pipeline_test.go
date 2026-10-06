package report

import (
	"bytes"
	"maps"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/classify"
)

// TestCountsToReport is the end-to-end path from classify's per-worker counters to the report
// input: Worker.Counts, merged with classify.MergeCounts, through classify.Calls. Every taxon a
// lookup hit must reach the report, including those no read was called at (0 reads), because
// their presence decides the order of tied siblings. Synthetic taxonomy (unit test only).
func TestCountsToReport(t *testing.T) {
	tax := synthTaxo()
	opts := classify.Options{MinimumHitGroups: 2, CountTaxa: true}
	c, err := classify.New(tax, classify.IndexInfo{DNA: true}, opts, nil)
	if err != nil {
		t.Fatal(err)
	}
	// r1 classifies: two hit groups at strain (8), one at sub (5).
	// Each element is (minimizer, stored internal taxid); distinct minimizers are distinct groups.
	type ev struct {
		min uint64
		tax uint32
	}
	read := func(w *classify.Worker, id string, evs ...ev) uint64 {
		tk := c.NewTokens()
		for _, e := range evs {
			tk.Add(e.min, false)
		}
		tk.Vals = tk.Vals[:0]
		for _, e := range evs {
			tk.Vals = append(tk.Vals, e.tax)
		}
		return c.Classify(tk, []byte(id), 50, 0, w)
	}
	var w1, w2 classify.Worker
	if call := read(&w1, "r1", ev{1, 8}, ev{2, 8}, ev{3, 5}); call != 8 {
		t.Fatalf("r1 call %d, want 8", call)
	}
	// One hit group at Other (3): below --minimum-hit-groups 2, so unclassified, but taxon 3
	// was hit and must be present with 0 reads.
	if call := read(&w2, "r2", ev{4, 3}, ev{5, 0}); call != 0 {
		t.Fatalf("r2 call %d, want 0", call)
	}
	// Hit at Bacteria (2) in a classified read whose call is elsewhere.
	if call := read(&w2, "r3", ev{6, 7}, ev{7, 7}, ev{8, 2}); call != 7 {
		t.Fatalf("r3 call %d, want 7", call)
	}

	merged := map[uint64]*classify.TaxonCount{}
	classify.MergeCounts(merged, w1.Counts)
	classify.MergeCounts(merged, w2.Counts)
	calls := classify.Calls(merged)
	want := map[uint64]uint64{8: 1, 5: 0, 3: 0, 7: 1, 2: 0}
	if !maps.Equal(calls, want) {
		t.Fatalf("calls = %v, want %v", calls, want)
	}

	total, uncl := uint64(3), uint64(3)-w1.Classified-w2.Classified
	var got, ref bytes.Buffer
	if err := KrakenStyle(&got, tax, calls, total, uncl, Options{ZeroCounts: false}); err != nil {
		t.Fatal(err)
	}
	if err := KrakenStyle(&ref, tax, want, total, uncl, Options{}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Bytes(), ref.Bytes()) {
		t.Fatalf("report from counters differs:\n%s\nwant\n%s", got.Bytes(), ref.Bytes())
	}
}
