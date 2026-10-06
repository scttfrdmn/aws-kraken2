package taxo

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

// oraclePairs is how many pseudo-random (a, b) pairs the dump checks on top of the exhaustive
// (x,0), (0,x), (x,x), (x,parent) set.
const oraclePairs = 200000

// dump writes exactly what upstream/taxo_dump.cc writes.
func dump(w io.Writer, t *Taxonomy, pairs uint64) error {
	bw := bufio.NewWriter(w)
	fmt.Fprintf(bw, "header\t%d\t%d\t%d\n", len(t.Nodes), len(t.NameData), len(t.RankData))
	for i, d := range t.Nodes {
		id := uint64(i)
		fmt.Fprintf(bw, "node\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n", i, d.ParentID,
			d.FirstChild, d.ChildCount, d.NameOffset, d.RankOffset, d.ExternalID, d.GodparentID,
			t.Rank(id), t.Name(id))
	}
	fmt.Fprintf(bw, "int\t0\t%d\n", t.InternalID(0))
	for i := 1; i < len(t.Nodes); i++ {
		e := t.Nodes[i].ExternalID
		fmt.Fprintf(bw, "int\t%d\t%d\n", e, t.InternalID(e))
	}
	b2i := func(b bool) int {
		if b {
			return 1
		}
		return 0
	}
	pair := func(a, b uint64) {
		fmt.Fprintf(bw, "pair\t%d\t%d\t%d\t%d\t%d\n", a, b, b2i(t.IsAAncestorOfB(a, b)),
			b2i(t.IsAAncestorOfB(b, a)), t.LowestCommonAncestor(a, b))
	}
	pair(0, 0)
	n := uint64(len(t.Nodes))
	for i := uint64(1); i < n; i++ {
		pair(i, 0)
		pair(0, i)
		pair(i, i)
		pair(i, t.Parent(i))
	}
	state := uint64(0x9E3779B97F4A7C15)
	next := func() uint64 {
		state = state*6364136223846793005 + 1442695040888963407
		return state >> 11
	}
	for k := uint64(0); k < pairs && n > 1; k++ {
		a := 1 + next()%(n-1)
		b := 1 + next()%(n-1)
		pair(a, b)
	}
	return bw.Flush()
}

func TestOracleTaxoDump(t *testing.T) {
	harness := oracletest.Harness(t, "taxo_dump")
	for _, db := range []string{oracletest.Viral, oracletest.Standard8} {
		t.Run(db, func(t *testing.T) {
			dir := oracletest.DB(t, db)
			file := filepath.Join(dir, "taxo.k2d")
			want, err := exec.Command(harness, file, fmt.Sprint(oraclePairs)).Output()
			if err != nil {
				t.Fatalf("harness: %v", err)
			}
			tx, err := Load(file)
			if err != nil {
				t.Fatal(err)
			}
			var got bytes.Buffer
			if err := dump(&got, tx, oraclePairs); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got.Bytes(), want) {
				gl, wl := bytes.Split(got.Bytes(), []byte("\n")), bytes.Split(want, []byte("\n"))
				for i := 0; i < len(gl) && i < len(wl); i++ {
					if !bytes.Equal(gl[i], wl[i]) {
						t.Fatalf("dump differs at line %d:\n go:  %q\n c++: %q", i+1, gl[i], wl[i])
					}
				}
				t.Fatalf("dump length differs: go %d lines, c++ %d lines", len(gl), len(wl))
			}
			t.Logf("%s: %d nodes, %d dump bytes identical", db, len(tx.Nodes), len(want))
		})
	}
}
