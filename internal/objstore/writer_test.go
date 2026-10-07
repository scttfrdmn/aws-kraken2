package objstore

import (
	"context"
	"testing"
)

// countingStore counts CreateMultipart and Abort calls.
type countingStore struct {
	*Dir
	creates, aborts int
}

func (c *countingStore) CreateMultipart(ctx context.Context, b, k string) (string, error) {
	c.creates++
	return c.Dir.CreateMultipart(ctx, b, k)
}

func (c *countingStore) Abort(ctx context.Context, b, k, id string) error {
	c.aborts++
	return c.Dir.Abort(ctx, b, k, id)
}

// TestWriterLazyAndAbort: an empty object is one PutObject and never a multipart upload (so it
// needs no Abort, which the instance role lacks); Abort after parts leaves no object and no
// open upload.
func TestWriterLazyAndAbort(t *testing.T) {
	ctx := context.Background()
	st := &countingStore{Dir: &Dir{Root: t.TempDir()}}
	w, err := NewWriter(ctx, st, "s3://b/empty", DefaultPartSize, 2)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if got, err := st.Get(ctx, "b", "empty"); err != nil || len(got) != 0 {
		t.Fatalf("empty object: %q %v", got, err)
	}
	if st.creates != 0 || st.aborts != 0 {
		t.Fatalf("empty object: %d creates, %d aborts", st.creates, st.aborts)
	}
	w, _ = NewWriter(ctx, st, "s3://b/partial", DefaultPartSize, 2)
	if _, err := w.Write(make([]byte, DefaultPartSize+100)); err != nil {
		t.Fatal(err)
	}
	if err := w.Abort(); err != nil {
		t.Fatal(err)
	}
	if _, err := st.Get(ctx, "b", "partial"); err != ErrNotFound {
		t.Fatalf("aborted object exists: %v", err)
	}
	if st.creates != 1 || st.aborts != 1 || len(st.Pending()) != 0 {
		t.Fatalf("abort: %d creates, %d aborts, pending %v", st.creates, st.aborts, st.Pending())
	}
}
