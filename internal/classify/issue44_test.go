package classify

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Regression for #44 (Law 1): on RODA v205, 16 reads of three HMP2 samples were called
// differently from upstream. Each hits one of the taxonomy's trailing nodes with external ID 0
// and parent 0, so a score tie's LowestCommonAncestor is 0, LCA(0, x) = x, and ResolveTree's
// call depends on the iteration order of upstream's per-thread std::unordered_map hit_counts.
//
// The case rebuilds each read's events from upstream's own --output hit list (one lookup per
// k-mer of each "taxid:count" run, the internal IDs from RODA v205's taxonomy, the 5-count
// external-ID-0 run as the orphan, "|:|" as the mate border), classifies them through the
// package's public API, and requires upstream's line byte for byte. Of the 16 reads, the 3 with
// two 5-count zero runs (which run is the orphan, and whether the two are one orphan or two,
// cannot be told from the hit list) are left to the RODA end-to-end recheck (make run
// SPEC=runs/g3-diag44-r8gd.16xlarge.json). The orphan's internal ID here is 2158313, one of the
// 246; which one each read hit is not in the hit list.
//
// It fails on purpose until the clean-room HitCounts (hitorder.go, TODO(#44 clean-room))
// lands: with first-hit order, as at 0a5105c, every case gives our old line instead.

type mapTree map[uint64][2]uint64 // internal -> (parent, external)

func (m mapTree) IsAAncestorOfB(a, b uint64) bool {
	if a == 0 || b == 0 {
		return false
	}
	for b > a {
		b = m[b][0]
	}
	return b == a
}

func (m mapTree) LowestCommonAncestor(a, b uint64) uint64 {
	if a == 0 || b == 0 {
		if a != 0 {
			return a
		}
		return b
	}
	for a != b {
		if a > b {
			a = m[a][0]
		} else {
			b = m[b][0]
		}
	}
	return a
}

func (m mapTree) Parent(id uint64) uint64     { return m[id][0] }
func (m mapTree) ExternalID(id uint64) uint64 { return m[id][1] }
func (m mapTree) Name(id uint64) string       { return "" }

func loadRodaLineages(t *testing.T) (mapTree, map[uint64]uint64) {
	f, err := os.Open(filepath.Join("testdata", "roda_v205_lineages.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	tree := mapTree{}
	ext := map[uint64]uint64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := sc.Text()
		if strings.HasPrefix(l, "#") || strings.HasPrefix(l, "internal") {
			continue
		}
		p := strings.Split(l, "\t")
		i, _ := strconv.ParseUint(p[0], 10, 64)
		par, _ := strconv.ParseUint(p[1], 10, 64)
		e, _ := strconv.ParseUint(p[2], 10, 64)
		tree[i] = [2]uint64{par, e}
		if e != 0 {
			ext[e] = i
		}
	}
	return tree, ext
}

const issue44Orphan = 2158313

func TestIssue44OrphanTies(t *testing.T) {
	tree, ext := loadRodaLineages(t)
	c, err := New(tree, IndexInfo{DNA: true}, Options{Paired: true, MinimumHitGroups: 2}, nil)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(filepath.Join("testdata", "issue44_reads.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	n := 0
	for sc.Scan() {
		var r struct {
			ID           string `json:"id"`
			UpstreamLine string `json:"upstream_line"`
			Before       string `json:"our_line_before_fix"`
		}
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			t.Fatal(err)
		}
		f := strings.Split(r.UpstreamLine, "\t")
		lens := strings.Split(f[3], "|")
		l1, _ := strconv.ParseUint(lens[0], 10, 32)
		l2, _ := strconv.ParseUint(lens[1], 10, 32)
		toks := c.NewTokens()
		toks.Reset()
		var m uint64 = 1
		for _, run := range strings.Fields(f[4]) {
			if run == "|:|" {
				toks.MateBorder()
				continue
			}
			p := strings.Split(run, ":")
			cnt, _ := strconv.Atoi(p[1])
			e, _ := strconv.ParseUint(p[0], 10, 64)
			var v uint64
			switch {
			case e != 0:
				v = ext[e]
				if v == 0 {
					t.Fatalf("%s: external %d not in the lineage table", r.ID, e)
				}
			case cnt == 5:
				v = issue44Orphan
			}
			for k := 0; k < cnt; k++ {
				toks.Add(m, false) // distinct minimizers: every k-mer is a lookup
				toks.Vals = append(toks.Vals, uint32(v))
				m++
			}
		}
		w := &Worker{}
		c.Classify(toks, []byte(r.ID), uint32(l1), uint32(l2), w)
		got := strings.TrimRight(string(w.Out), "\n")
		if got != r.UpstreamLine {
			t.Errorf("%s:\n got      %q\n upstream %q\n (before the fix: %q)", r.ID, got, r.UpstreamLine, r.Before)
		}
		n++
	}
	if n != 13 {
		t.Fatalf("%d cases, want 13", n)
	}
}
