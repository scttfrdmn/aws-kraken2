package rangeread

import (
	"bytes"
	"context"
	"crypto/sha256"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func serve(t *testing.T, data []byte, etag string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"`+etag+`"`)
		http.ServeContent(w, r, "obj", time.Time{}, bytes.NewReader(data))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func randData(n int) []byte {
	rng := rand.New(rand.NewPCG(1, 1))
	data := make([]byte, n)
	for i := range data {
		data[i] = byte(rng.Uint32())
	}
	return data
}

func check(t *testing.T, src Source, data []byte, start int64, chunk int64) {
	t.Helper()
	h := sha256.New()
	got := start
	st, err := Stream(context.Background(), src, start, int64(len(data)), Options{Chunk: chunk, Workers: 5, Window: 7},
		func(off int64, b []byte) any { return sha256.Sum256(b) },
		func(off int64, b []byte, w any) error {
			if off != got {
				t.Fatalf("chunk at %d, want %d", off, got)
			}
			if w.([32]byte) != sha256.Sum256(data[off:off+int64(len(b))]) {
				t.Fatalf("work saw wrong bytes at %d", off)
			}
			h.Write(b)
			got += int64(len(b))
			return nil
		})
	if err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256(data[start:])
	if got != int64(len(data)) || st.Bytes != got-start || !bytes.Equal(h.Sum(nil), want[:]) {
		t.Fatalf("chunk %d: streamed to %d (%d bytes), sha mismatch or count off", chunk, got, st.Bytes)
	}
}

func TestStreamHTTPInOrder(t *testing.T) {
	data := randData(1<<20 + 13)
	srv := serve(t, data, "abc-2")
	src := &HTTPSource{URL: srv.URL, ETag: "abc-2", Size: int64(len(data)), Client: NewHTTPClient(8)}
	for _, chunk := range []int64{7919, 1 << 16, 1 << 20, 1 << 21} {
		check(t, src, data, 0, chunk)
	}
	check(t, src, data, 1000, 4096)
}

func TestStreamFile(t *testing.T) {
	data := randData(300_001)
	p := filepath.Join(t.TempDir(), "obj")
	if err := os.WriteFile(p, data, 0o644); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, chunk := range []int64{1, 333, 1 << 20} {
		if chunk == 1 {
			check(t, &FileSource{F: f}, data[:5000], 0, chunk)
			continue
		}
		check(t, &FileSource{F: f}, data, 0, chunk)
	}
}

func TestETagMismatchIsFatal(t *testing.T) {
	data := make([]byte, 1000)
	srv := serve(t, data, "new")
	src := &HTTPSource{URL: srv.URL, ETag: "old", Size: 1000, Client: NewHTTPClient(2)}
	_, err := Stream(context.Background(), src, 0, 1000, Options{Chunk: 100, Workers: 2},
		nil, func(int64, []byte, any) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "412") {
		t.Fatalf("want a 412 failure, got %v", err)
	}
	if src.Retries.Load() != 0 {
		t.Fatalf("412 was retried: %d retries", src.Retries.Load())
	}
}
