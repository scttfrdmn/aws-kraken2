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
// Each case replays one of the 16 reads exactly as classify.cc consumes it: upstream's own
// minimizer events with ambiguity flags (upstream/mm_dump) and upstream's own value for each
// lookup (upstream/chash_dump -m on RODA v205's hash.k2d), recorded by the #44 diagnostic
// (results/g3/20261009-015708-210e1b5, k2probe diag-reads; testdata/issue44_events.jsonl), through
// the package's public API,
// with RODA v205's lineages for the taxa hit (testdata/roda_v205_lineages.tsv; the orphan the
// reads hit is internal 2158558). It requires upstream's --output line byte for byte. Before the
// fix (first-hit order, as at 0a5105c) every case gave our old line, also recorded.

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

func loadRodaLineages(t *testing.T) (mapTree, map[uint64]uint64) { //nolint:unparam
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

func TestIssue44OrphanTies(t *testing.T) {
	tree, _ := loadRodaLineages(t)
	c, err := New(tree, IndexInfo{DNA: true}, Options{Paired: true, MinimumHitGroups: 2}, nil)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(filepath.Join("testdata", "issue44_events.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<22)
	n := 0
	for sc.Scan() {
		var r struct {
			ID           string `json:"id"`
			UpstreamLine string `json:"upstream_line"`
			Before       string `json:"our_line_before_fix"`
			Mates        []struct {
				Len    uint32   `json:"len"`
				Events []string `json:"events"`
				Values []uint32 `json:"values"`
			} `json:"mates"`
		}
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			t.Fatal(err)
		}
		if len(r.Mates) != 2 {
			t.Fatalf("%s: %d mates", r.ID, len(r.Mates))
		}
		// Upstream's own events (upstream/mm_dump) and values (upstream/chash_dump -m on RODA's
		// hash.k2d), mate 1, the border, mate 2: what classify.cc's replay consumes.
		toks := c.NewTokens()
		toks.Reset()
		val := map[uint64]uint32{}
		for mi, m := range r.Mates {
			if mi == 1 {
				toks.MateBorder()
			}
			for j, e := range m.Events {
				amb := strings.HasSuffix(e, ":A")
				k, err := strconv.ParseUint(strings.TrimSuffix(e, ":A"), 16, 64)
				if err != nil {
					t.Fatalf("%s: event %q", r.ID, e)
				}
				toks.Add(k, amb)
				if !amb {
					val[k] = m.Values[j]
				}
			}
		}
		for _, k := range toks.Keys {
			if v := val[k]; v != 0 {
				if _, ok := tree[uint64(v)]; !ok {
					t.Fatalf("%s: value %d not in the lineage table", r.ID, v)
				}
			}
			toks.Vals = append(toks.Vals, val[k])
		}
		w := &Worker{}
		c.Classify(toks, []byte(r.ID), r.Mates[0].Len, r.Mates[1].Len, w)
		got := strings.TrimRight(string(w.Out), "\n")
		if got != r.UpstreamLine {
			t.Errorf("%s:\n got      %q\n upstream %q\n (before the fix: %q)", r.ID, got, r.UpstreamLine, r.Before)
		}
		if r.Before == r.UpstreamLine {
			t.Errorf("%s: the case does not distinguish the fix (its pre-fix line equals upstream's)", r.ID)
		}
		n++
	}
	if n != 16 {
		t.Fatalf("%d cases, want 16", n)
	}
}
