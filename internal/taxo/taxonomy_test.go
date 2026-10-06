package taxo

import (
	"encoding/binary"
	"testing"
)

// synth builds a taxo.k2d image (synthetic, unit-test only):
//
//	1 root
//	├── 2 A (genus)
//	│   ├── 4 A1 (species)
//	│   └── 5 A2 (species)
//	└── 3 B (genus)
//	    └── 6 B1 (species)
func synth() []byte {
	names := []byte("\x00root\x00A\x00B\x00A1\x00A2\x00B1\x00")
	ranks := []byte("genus\x00no rank\x00species\x00")
	type n = [7]uint64
	nodes := []n{
		{0, 0, 0, 0, 0, 0, 0},
		{0, 2, 2, 1, 6, 1, 0},
		{1, 4, 2, 6, 0, 100, 0},
		{1, 6, 1, 8, 0, 200, 0},
		{2, 7, 0, 10, 14, 101, 0},
		{2, 7, 0, 13, 14, 102, 0},
		{3, 7, 0, 16, 14, 201, 0},
	}
	var b []byte
	b = append(b, FileMagic...)
	b = binary.LittleEndian.AppendUint64(b, uint64(len(nodes)))
	b = binary.LittleEndian.AppendUint64(b, uint64(len(names)))
	b = binary.LittleEndian.AppendUint64(b, uint64(len(ranks)))
	for _, nd := range nodes {
		for _, f := range nd {
			b = binary.LittleEndian.AppendUint64(b, f)
		}
	}
	b = append(b, names...)
	return append(b, ranks...)
}

func TestParseSynthetic(t *testing.T) {
	tx, err := Parse(synth())
	if err != nil {
		t.Fatal(err)
	}
	if tx.NodeCount() != 7 || tx.Name(4) != "A1" || tx.Rank(4) != "species" ||
		tx.Rank(1) != "no rank" || tx.Name(0) != "" || tx.ExternalID(6) != 201 || tx.Parent(6) != 3 {
		t.Fatalf("bad decode: %+v", tx.Nodes)
	}
	if tx.InternalID(102) != 5 || tx.InternalID(0) != 0 || tx.InternalID(999) != 0 {
		t.Fatal("bad external map")
	}
	lca := []struct{ a, b, want uint64 }{
		{0, 0, 0}, {4, 0, 4}, {0, 4, 4}, {4, 5, 2}, {4, 6, 1}, {4, 2, 2}, {1, 6, 1}, {6, 6, 6},
	}
	for _, c := range lca {
		if got := tx.LowestCommonAncestor(c.a, c.b); got != c.want {
			t.Errorf("LCA(%d,%d)=%d want %d", c.a, c.b, got, c.want)
		}
	}
	anc := []struct {
		a, b uint64
		want bool
	}{
		{0, 0, false}, {0, 4, false}, {4, 0, false}, {1, 4, true}, {2, 4, true}, {4, 4, true},
		{4, 2, false}, {3, 4, false}, {2, 6, false},
	}
	for _, c := range anc {
		if got := tx.IsAAncestorOfB(c.a, c.b); got != c.want {
			t.Errorf("IsAAncestorOfB(%d,%d)=%v want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestParseErrors(t *testing.T) {
	good := synth()
	bad := append([]byte("K2TAXDAX"), good[8:]...)
	if _, err := Parse(bad); err == nil {
		t.Error("bad magic accepted")
	}
	for _, n := range []int{0, 7, 20, len(good) - 1} {
		if _, err := Parse(good[:n]); err == nil {
			t.Errorf("truncated to %d accepted", n)
		}
	}
	if _, err := Parse(append(good, 1, 2, 3)); err != nil {
		t.Errorf("trailing bytes rejected: %v", err)
	}
	huge := append([]byte(nil), good...)
	binary.LittleEndian.PutUint64(huge[8:], 1<<62)
	if _, err := Parse(huge); err == nil {
		t.Error("huge node count accepted")
	}
}
