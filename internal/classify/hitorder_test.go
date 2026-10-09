package classify

import (
	"bufio"
	"compress/gzip"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestHitCountsGolden replays each op history in testdata/umap/ (one map's lifetime, as one
// classify.cc thread's hit_counts) through newHitCounts() and requires, at every P, the taxa in
// the order upstream's container iterated them (docs/hitorder.md). The bucket count the golden
// lines also carry is not part of the HitCounts interface and is not compared.
//
// It fails while newHitCounts is the first-insertion-order placeholder (TODO(#44 clean-room)).
func TestHitCountsGolden(t *testing.T) {
	ops, _ := filepath.Glob(filepath.Join("testdata", "umap", "ops-*.txt.gz"))
	if len(ops) == 0 {
		t.Fatal("no golden op histories in testdata/umap (make hitorder-golden)")
	}
	for _, op := range ops {
		want := gzLines(t, strings.TrimSuffix(op, ".txt.gz")+".out.gz")
		m := newHitCounts()
		pi := 0
		for ln, c := range gzLines(t, op) {
			f := strings.Fields(c)
			switch f[0] {
			case "C":
				m.Clear()
			case "I", "L":
				k, err := strconv.ParseUint(f[1], 10, 64)
				if err != nil {
					t.Fatalf("%s:%d: %q", op, ln+1, c)
				}
				if f[0] == "I" {
					m.Increment(k)
				} else {
					m.Lookup(k)
				}
			case "P":
				var b strings.Builder
				m.Range(func(taxon, _ uint64) bool { fmt.Fprintf(&b, " %d", taxon); return true })
				w := strings.Fields(want[pi])
				if got, exp := strings.TrimSpace(b.String()), strings.Join(w[2:], " "); got != exp {
					t.Fatalf("%s: print %d (op line %d): order\n got  %s\n want %s", filepath.Base(op), pi, ln+1, got, exp)
				}
				pi++
			default:
				t.Fatalf("%s:%d: unknown op %q", op, ln+1, c)
			}
		}
		if pi != len(want) {
			t.Fatalf("%s: %d prints, golden has %d", op, pi, len(want))
		}
	}
}

func gzLines(t *testing.T, path string) []string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	z, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	sc := bufio.NewScanner(z)
	sc.Buffer(make([]byte, 1<<20), 1<<24)
	for sc.Scan() {
		out = append(out, sc.Text())
	}
	return out
}
