package seqio

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

// Recycling every block after use changes nothing a later load returns (issue #39).
func TestRecycleBlocks(t *testing.T) {
	var in bytes.Buffer
	for i := 0; i < 5000; i++ {
		n := 1 + i%170
		fmt.Fprintf(&in, "@r%d c\n%s\n+\n%s\n", i, strings.Repeat("ACGT"[i%4:i%4+1], n), strings.Repeat("I", n))
	}
	read := func(recycle bool) []string {
		r := NewReader(bytes.NewReader(in.Bytes()))
		var got []string
		for {
			b := r.LoadBlock(4096, 1)
			if b == nil {
				break
			}
			recs, _ := b.Parse()
			for _, rec := range recs {
				got = append(got, string(rec.ID)+" "+string(rec.Seq)+" "+string(rec.Qual))
			}
			if recycle {
				Recycle(b)
			}
		}
		return got
	}
	a, b := read(false), read(true)
	if len(a) != 5000 || len(a) != len(b) {
		t.Fatalf("records: %d without recycling, %d with", len(a), len(b))
	}
	for i := range a {
		if a[i] != b[i] {
			t.Fatalf("record %d: %q vs %q", i, a[i], b[i])
		}
	}
}
