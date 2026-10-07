package objstore

import (
	"bytes"
	"context"
	"math/rand/v2"
	"testing"
)

func TestWriterParts(t *testing.T) {
	ctx := context.Background()
	r := rand.New(rand.NewPCG(1, 2))
	for _, total := range []int{0, 1, MinPartSize - 1, DefaultPartSize, DefaultPartSize + 1, 3*DefaultPartSize + 12345} {
		d := &Dir{Root: t.TempDir()}
		w, err := NewWriter(ctx, d, "s3://bkt/out/x.txt", DefaultPartSize, 3)
		if err != nil {
			t.Fatal(err)
		}
		want := make([]byte, total)
		for i := range want {
			want[i] = byte(r.Uint32())
		}
		for off := 0; off < total; { // writes of uneven sizes, as blocks arrive
			n := min(total-off, 1+int(r.Uint64N(3<<20)))
			if _, err := w.Write(want[off : off+n]); err != nil {
				t.Fatal(err)
			}
			off += n
		}
		if err := w.Close(); err != nil {
			t.Fatalf("total %d: %v", total, err)
		}
		got, err := d.Get(ctx, "bkt", "out/x.txt")
		if err != nil || !bytes.Equal(got, want) {
			t.Fatalf("total %d: got %d bytes (%v), want %d", total, len(got), err, total)
		}
		parts := w.Parts()
		for i, p := range parts {
			if p.Number != i+1 {
				t.Fatalf("total %d: part %d numbered %d", total, i, p.Number)
			}
			if i < len(parts)-1 && p.Size != DefaultPartSize {
				t.Fatalf("total %d: non-final part %d is %d bytes", total, p.Number, p.Size)
			}
		}
		if wantParts := (total + DefaultPartSize - 1) / DefaultPartSize; len(parts) != wantParts {
			t.Fatalf("total %d: %d parts, want %d", total, len(parts), wantParts)
		}
		if p := d.Pending(); len(p) != 0 {
			t.Fatalf("uploads left open: %v", p)
		}
	}
}

func TestDirRules(t *testing.T) {
	ctx := context.Background()
	d := &Dir{Root: t.TempDir()}
	id, _ := d.CreateMultipart(ctx, "b", "k")
	e1, _ := d.UploadPart(ctx, "b", "k", id, 1, []byte("small"))
	e2, _ := d.UploadPart(ctx, "b", "k", id, 2, []byte("last"))
	if err := d.Complete(ctx, "b", "k", id, []Part{{1, e1, 5}, {2, e2, 4}}); err == nil {
		t.Fatal("a small non-final part was accepted")
	}
	if err := d.Complete(ctx, "b", "k", id, []Part{{2, e2, 4}, {1, e1, 5}}); err == nil {
		t.Fatal("descending parts accepted")
	}
	if _, err := d.UploadPart(ctx, "b", "k", id, 10001, nil); err == nil {
		t.Fatal("part 10001 accepted")
	}
	if _, err := d.path("b", "../../x"); err == nil {
		t.Fatal("escaping key accepted")
	}
	if _, err := d.Get(ctx, "b", "nope"); err != ErrNotFound {
		t.Fatalf("missing object: %v", err)
	}
}

func TestParseURL(t *testing.T) {
	b, k, err := ParseURL("s3://bkt/a/b/c")
	if err != nil || b != "bkt" || k != "a/b/c" {
		t.Fatalf("%q %q %v", b, k, err)
	}
	for _, bad := range []string{"bkt/a", "s3://bkt", "s3:///k", "s3://bkt/"} {
		if _, _, err := ParseURL(bad); err == nil {
			t.Fatalf("%q accepted", bad)
		}
	}
}
