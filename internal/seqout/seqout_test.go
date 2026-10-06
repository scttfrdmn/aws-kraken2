package seqout

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/seqio"
)

func TestAppendRecord(t *testing.T) {
	fq := seqio.Record{ID: []byte("r1/1"), Comment: []byte("c d"), Seq: []byte("ACxT"), Qual: []byte("II#I"), Format: seqio.FormatFASTQ}
	fa := seqio.Record{ID: []byte("f"), Seq: []byte("ACGTACGT"), Format: seqio.FormatFASTA}
	bad := seqio.Record{ID: []byte("b"), Seq: []byte("AC"), Qual: []byte("III"), Format: seqio.FormatFASTA}
	var b Batch
	b.Add(&fq, &fa, true, 10239)
	b.Add(&fa, &bad, false, 0)
	if got, want := string(b.C1), "@r1/1 kraken:taxid|10239 c d\nACxT\n+\nII#I\n"; got != want {
		t.Errorf("C1 %q want %q", got, want)
	}
	if got, want := string(b.C2), ">f kraken:taxid|10239\nACGTACGT\n"; got != want {
		t.Errorf("C2 %q want %q", got, want)
	}
	if got, want := string(b.U1), ">f\nACGTACGT\n"; got != want {
		t.Errorf("U1 %q want %q", got, want)
	}
	if got, want := string(b.U2), ">b\nAC\n"; got != want {
		t.Errorf("U2 %q want %q", got, want)
	}
}

func TestPairedNames(t *testing.T) {
	a, b, err := PairedNames("out/cls#.fq")
	if err != nil || a != "out/cls_1.fq" || b != "out/cls_2.fq" {
		t.Fatalf("%s %s %v", a, b, err)
	}
	if _, _, err := PairedNames("cls.fq"); err == nil || err.Error() != "Paired filename format missing # character: cls.fq" {
		t.Fatalf("missing: %v", err)
	}
	if _, _, err := PairedNames("a#b#c#d"); err == nil || err.Error() != "Paired filename format has >1 # character: a#b#c#d" {
		t.Fatalf("many: %v", err)
	}
}

func TestOpenWrite(t *testing.T) {
	dir := t.TempDir()
	if _, err := Open(filepath.Join(dir, "c.fq"), "", true); err == nil {
		t.Fatal("paired without # accepted")
	}
	w, err := Open(filepath.Join(dir, "c#.fq"), filepath.Join(dir, "u#.fq"), true)
	if err != nil || !w.PrintingSequences() {
		t.Fatal(err)
	}
	r := seqio.Record{ID: []byte("x"), Seq: []byte("A"), Format: seqio.FormatFASTA}
	var b Batch
	b.Add(&r, &r, true, 7)
	if err := w.Write(&b); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]string{"c_1.fq": ">x kraken:taxid|7\nA\n", "c_2.fq": ">x kraken:taxid|7\nA\n", "u_1.fq": "", "u_2.fq": ""} {
		got, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil || string(got) != want {
			t.Errorf("%s: %q %v", name, got, err)
		}
	}
	var none *Writers
	if none.PrintingSequences() {
		t.Fatal("nil writers print")
	}
}

func TestOrdered(t *testing.T) {
	var got []string
	o := NewOrdered(func(s string) error { got = append(got, s); return nil }, 4)
	done := make(chan bool)
	for _, i := range []int{3, 1, 4, 0, 2} {
		go func() { o.Submit(uint64(i), strings.Repeat("x", i)); done <- true }()
	}
	for range 5 {
		<-done
	}
	if err := o.Close(); err != nil || strings.Join(got, ",") != ",x,xx,xxx,xxxx" {
		t.Fatalf("%q %v", got, err)
	}
	boom := errors.New("boom")
	o2 := NewOrdered(func(int) error { return boom }, 1)
	o2.Submit(0, 0)
	o2.Submit(1, 1)
	if err := o2.Close(); err != boom {
		t.Fatal(err)
	}
	o3 := NewOrdered(func(int) error { return nil }, 1)
	o3.Submit(0, 0)
	o3.Submit(2, 2)
	if err := o3.Close(); err == nil || !strings.Contains(err.Error(), "sequence number 1") {
		t.Fatalf("gap: %v", err)
	}
}
