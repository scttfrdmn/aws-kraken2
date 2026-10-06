package report

import (
	"bytes"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/taxo"
)

// synthTaxo is a synthetic tree (unit tests only), internal IDs in BFS order:
//
//	1 root (no rank)
//	├── 2 Bacteria (superkingdom)
//	│   └── 4 clade (no rank)
//	│       └── 6 Genus (genus)
//	│           └── 7 Species (species)
//	│               └── 8 strain (no rank)
//	└── 3 Other (no rank)
//	    └── 5 sub (no rank)
func synthTaxo() *taxo.Taxonomy {
	names := "\x00root\x00Bacteria\x00Other\x00clade\x00sub\x00Genus\x00Species\x00strain\x00"
	ranks := "genus\x00no rank\x00species\x00superkingdom\x00"
	off := func(s, sub string) uint64 { return uint64(strings.Index(s, "\x00"+sub+"\x00") + 1) }
	nr, g, sp, sk := off(ranks, "no rank"), uint64(0), off(ranks, "species"), off(ranks, "superkingdom")
	node := func(parent, first, n uint64, name string, rank, ext uint64) taxo.Node {
		return taxo.Node{ParentID: parent, FirstChild: first, ChildCount: n,
			NameOffset: off(names, name), RankOffset: rank, ExternalID: ext}
	}
	return &taxo.Taxonomy{
		Nodes: []taxo.Node{
			{},
			node(0, 2, 2, "root", nr, 1),
			node(1, 4, 1, "Bacteria", sk, 2),
			node(1, 5, 1, "Other", nr, 28384),
			node(2, 6, 1, "clade", nr, 10),
			node(3, 6, 0, "sub", nr, 11),
			node(4, 7, 1, "Genus", g, 20),
			node(6, 8, 1, "Species", sp, 30),
			node(7, 9, 0, "strain", nr, 31),
		},
		NameData: []byte(names),
		RankData: []byte(ranks),
	}
}

func TestKrakenStyleSynthetic(t *testing.T) {
	calls := map[uint64]uint64{8: 3, 7: 1, 5: 2, 2: 0}
	var b bytes.Buffer
	if err := KrakenStyle(&b, synthTaxo(), calls, 10, 4, Options{}); err != nil {
		t.Fatal(err)
	}
	want := " 40.00\t4\t4\tU\t0\tunclassified\n" +
		" 60.00\t6\t0\tR\t1\troot\n" +
		" 40.00\t4\t0\tD\t2\t  Bacteria\n" +
		" 40.00\t4\t0\tD1\t10\t    clade\n" +
		" 40.00\t4\t0\tG\t20\t      Genus\n" +
		" 40.00\t4\t1\tS\t30\t        Species\n" +
		" 30.00\t3\t3\tS1\t31\t          strain\n" +
		" 20.00\t2\t0\tR1\t28384\t  Other\n" +
		" 20.00\t2\t2\tR2\t11\t    sub\n"
	if b.String() != want {
		t.Fatalf("got\n%s\nwant\n%s", b.String(), want)
	}

	// No unclassified reads and no zero counts: no U line, zero-clade subtrees pruned.
	b.Reset()
	if err := KrakenStyle(&b, synthTaxo(), map[uint64]uint64{5: 2}, 2, 0, Options{}); err != nil {
		t.Fatal(err)
	}
	want = "100.00\t2\t0\tR\t1\troot\n" +
		"100.00\t2\t0\tR1\t28384\t  Other\n" +
		"100.00\t2\t2\tR2\t11\t    sub\n"
	if b.String() != want {
		t.Fatalf("got\n%s\nwant\n%s", b.String(), want)
	}

	// Zero counts: every node, U line even with 0 unclassified; present-but-zero taxon 2
	// sorts before absent taxon 3.
	b.Reset()
	if err := KrakenStyle(&b, synthTaxo(), map[uint64]uint64{2: 0}, 1, 0, Options{ZeroCounts: true}); err != nil {
		t.Fatal(err)
	}
	want = "  0.00\t0\t0\tU\t0\tunclassified\n" +
		"  0.00\t0\t0\tR\t1\troot\n" +
		"  0.00\t0\t0\tD\t2\t  Bacteria\n" +
		"  0.00\t0\t0\tD1\t10\t    clade\n" +
		"  0.00\t0\t0\tG\t20\t      Genus\n" +
		"  0.00\t0\t0\tS\t30\t        Species\n" +
		"  0.00\t0\t0\tS1\t31\t          strain\n" +
		"  0.00\t0\t0\tR1\t28384\t  Other\n" +
		"  0.00\t0\t0\tR2\t11\t    sub\n"
	if b.String() != want {
		t.Fatalf("got\n%s\nwant\n%s", b.String(), want)
	}
	// ... and with taxon 3 present instead, Other comes first.
	b.Reset()
	if err := KrakenStyle(&b, synthTaxo(), map[uint64]uint64{5: 0}, 1, 0, Options{ZeroCounts: true}); err != nil {
		t.Fatal(err)
	}
	if lines := strings.Split(b.String(), "\n"); !strings.HasSuffix(lines[2], "  Other") {
		t.Fatalf("present-zero sibling not first:\n%s", b.String())
	}
}

func TestMpaStyleSynthetic(t *testing.T) {
	calls := map[uint64]uint64{8: 3, 7: 1, 5: 2}
	var b bytes.Buffer
	if err := MpaStyle(&b, synthTaxo(), calls, Options{}); err != nil {
		t.Fatal(err)
	}
	want := "d__Bacteria\t4\n" +
		"d__Bacteria|g__Genus\t4\n" +
		"d__Bacteria|g__Genus|s__Species\t4\n"
	if b.String() != want {
		t.Fatalf("got\n%s\nwant\n%s", b.String(), want)
	}
}

// TestPct pins printf("%6.2f") results produced by C (Homebrew GCC 16, macOS libc) for
// rounding edge cases: exact binary ties round to even, near-ties follow the binary value.
func TestPct(t *testing.T) {
	cases := []struct {
		v    float64
		want string
	}{
		{0, "  0.00"},
		{0.125, "  0.12"},
		{0.375, "  0.38"},
		{0.625, "  0.62"},
		{12.125, " 12.12"},
		{0.0050000000000000001, "  0.01"},
		{0.014999999999999999, "  0.01"},
		{0.025000000000000001, "  0.03"},
		{99.995000000000005, "100.00"},
		{99.99499999999999, " 99.99"},
		{1.0000000000000001e-09, "  0.00"},
		{100, "100.00"},
		{1234.5, "1234.50"},
		{2.6749999999999998, "  2.67"},
		{1.0049999999999999, "  1.00"},
		{0.0049999999999999004, "  0.00"},
	}
	for _, c := range cases {
		if got := string(appendPct(nil, c.v)); got != c.want {
			t.Errorf("%%6.2f of %.17g: got %q want %q", c.v, got, c.want)
		}
	}
	var zero uint64
	nan := 100.0 * float64(int64(zero)) / float64(zero)
	if got := string(appendPct(nil, nan)); got != "   nan" && got != "  -nan" {
		t.Errorf("0/0: got %q", got)
	}
}
