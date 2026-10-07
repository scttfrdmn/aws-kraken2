package objstore

import (
	"bytes"
	"context"
	"math/rand/v2"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestSDKAgainstFake: the SDK store's multipart writes, through aws-sdk-go-v2 against the fake
// S3 server, give the same object as the bytes written (several parts, an empty object, Get,
// a missing key), and the guard refuses an undeclared bucket.
func TestSDKAgainstFake(t *testing.T) {
	ctx := context.Background()
	fake := &FakeS3{Dir: &Dir{Root: t.TempDir()}}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	st := Guard{Store: &SDK{Endpoint: srv.URL}, Allowed: map[string]bool{"bkt": true}}
	r := rand.New(rand.NewPCG(4, 5))
	want := make([]byte, 3*DefaultPartSize+777)
	for i := range want {
		want[i] = byte(r.Uint32())
	}
	w, err := NewWriter(ctx, st, "s3://bkt/run/out.txt", DefaultPartSize, 8)
	if err != nil {
		t.Fatal(err)
	}
	for off := 0; off < len(want); {
		n := min(len(want)-off, 1+int(r.Uint64N(2<<20)))
		if _, err := w.Write(want[off : off+n]); err != nil {
			t.Fatal(err)
		}
		off += n
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	got, err := st.Get(ctx, "bkt", "run/out.txt")
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("object: %d bytes, %v; want %d", len(got), err, len(want))
	}
	if fake.Parts.Load() != 4 {
		t.Fatalf("%d parts uploaded, want 4", fake.Parts.Load())
	}
	e, _ := NewWriter(ctx, st, "s3://bkt/run/empty", DefaultPartSize, 8)
	if err := e.Close(); err != nil {
		t.Fatal(err)
	}
	if got, err := st.Get(ctx, "bkt", "run/empty"); err != nil || len(got) != 0 {
		t.Fatalf("empty object: %q %v", got, err)
	}
	if _, err := st.Get(ctx, "bkt", "nope"); err != ErrNotFound {
		t.Fatalf("missing key: %v", err)
	}
	if err := st.Put(ctx, "other", "k", nil); err == nil || !strings.Contains(err.Error(), "AK2_ALLOWED_BUCKETS") {
		t.Fatalf("undeclared bucket: %v", err)
	}
	// With no allow-list at all, the SDK store refuses everything.
	t.Setenv("AK2_ALLOWED_BUCKETS", "")
	t.Setenv("AK2_S3_EMULATE", "")
	t.Setenv("AK2_S3_ENDPOINT", srv.URL)
	open, err := Open("sdk")
	if err != nil {
		t.Fatal(err)
	}
	if err := open.Put(ctx, "bkt", "k", nil); err == nil {
		t.Fatal("SDK store without an allow-list accepted a bucket")
	}
	if len(fake.Dir.Pending()) != 0 {
		t.Fatalf("uploads left open: %v", fake.Dir.Pending())
	}
}
