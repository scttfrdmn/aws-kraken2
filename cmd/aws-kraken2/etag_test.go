package main

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/engine"
	"github.com/scttfrdmn/aws-kraken2/internal/objstore"
	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

// multipartETag is S3's ETag of an upload of f in partSize-byte parts.
func multipartETag(t *testing.T, f *os.File, size, partSize int64) string {
	t.Helper()
	var cat []byte
	n := 0
	for off := int64(0); off < size; off += partSize {
		h := md5.New()
		if _, err := io.Copy(h, io.NewSectionReader(f, off, min(partSize, size-off))); err != nil {
			t.Fatal(err)
		}
		cat = h.Sum(cat)
		n++
	}
	s := md5.Sum(cat)
	return fmt.Sprintf("%s-%d", hex.EncodeToString(s[:]), n)
}

// flipAt is an io.ReaderAt that reads r with one bit of byte off flipped.
type flipAt struct {
	r   io.ReaderAt
	off int64
}

func (f flipAt) ReadAt(p []byte, off int64) (int, error) {
	n, err := f.r.ReadAt(p, off)
	if f.off >= off && f.off < off+int64(n) {
		p[f.off-off] ^= 0x80
	}
	return n, err
}

// TestETagVerifyEndToEnd: AK2_ENGINE_VERIFY_ETAG=1 against the viral hash.k2d served as S3
// serves an object (rangeread.FileHandler, k2probe serve-file's handler) with a real multipart
// ETag (8 MiB parts, the aws CLI's default, checked by scripts/lib/etagcheck.py), outputs to a
// fake S3 through the SDK path (k2probe fakes3's handler). Three nodes verify and match the
// plain path's outputs; with one byte of the served object corrupted under the same ETag, two
// nodes both fail before any output exists, and the in-process engine fails too.
func TestETagVerifyEndToEnd(t *testing.T) {
	db := oracletest.DB(t, "k2_viral_20260626")
	r1 := oracletest.Reads(t, "SRR062634_200000_1.fq")
	r2 := oracletest.Reads(t, "SRR062634_200000_2.fq")
	hashPath := filepath.Join(db, "hash.k2d")
	f, err := os.Open(hashPath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	size := st.Size()
	etag := multipartETag(t, f, size, 8<<20)
	if py, err := exec.LookPath("python3"); err == nil {
		out, err := exec.Command(py, "-I", filepath.Join(oracletest.ModuleRoot(), "scripts/lib/etagcheck.py"), hashPath, etag).CombinedOutput()
		if err != nil {
			t.Fatalf("etagcheck.py %s: %v\n%s", etag, err, out)
		}
	}
	good := httptest.NewServer(rangeread.FileHandler(f, size, st.ModTime(), etag))
	defer good.Close()
	// A key bit of a cell in the second half of the table: the cells stay valid, the bytes differ.
	off := int64(32 + (size-32)/4*3/4*4 + 3)
	bad := httptest.NewServer(rangeread.FileHandler(flipAt{f, off}, size, time.Now(), etag))
	defer bad.Close()

	dir := t.TempDir()
	fake := &objstore.FakeS3{Dir: &objstore.Dir{Root: filepath.Join(dir, "s3")}}
	s3srv := httptest.NewServer(fake)
	defer s3srv.Close()
	t.Setenv("AK2_S3_EMULATE", "")
	t.Setenv("AK2_S3_ENDPOINT", s3srv.URL)
	t.Setenv("AK2_ALLOWED_BUCKETS", "bkt")
	t.Setenv("AK2_S3_CLIENT", "sdk")
	none := func(string) (string, bool) { return "", false }
	plain := filepath.Join(dir, "plain")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	args := func(base, rep string) []string {
		return []string{"--db", db, "--threads", "2", "--paired", "--output", base + "/out", "--report", rep,
			"--classified-out", base + "/c#.fq", r1, r2}
	}
	if st := runEnv(args(plain, plain+"/rep"), none); st != 0 {
		t.Fatalf("plain run: exit %d", st)
	}
	cluster := func(name, url string, n int) []int {
		var wg sync.WaitGroup
		status := make([]int, n)
		for rank := 0; rank < n; rank++ {
			env := map[string]string{"AK2_ENGINE_N": strconv.Itoa(n), "AK2_ENGINE_RANK": strconv.Itoa(rank),
				"AK2_ENGINE_RENDEZVOUS": filepath.Join(dir, "rv-"+name), "AK2_ENGINE_TIMEOUT": "2m",
				"AK2_ENGINE_HASH_URL": url, "AK2_ENGINE_HASH_ETAG": etag,
				"AK2_ENGINE_HASH_SIZE": strconv.FormatInt(size, 10), "AK2_ENGINE_VERIFY_ETAG": "1"}
			lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
			rep := filepath.Join(dir, name+"-rep-"+strconv.Itoa(rank))
			wg.Add(1)
			go func() {
				defer wg.Done()
				status[rank] = runEnv(args("s3://bkt/"+name, rep), lookup)
			}()
		}
		wg.Wait()
		return status
	}
	read := func(p string) []byte {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	for rank, st := range cluster("good", good.URL, 3) {
		if st != 0 {
			t.Fatalf("verified 3-node run, rank %d: exit %d", rank, st)
		}
	}
	for _, o := range []string{"out", "c_1.fq", "c_2.fq"} {
		if !bytes.Equal(read(filepath.Join(plain, o)), read(filepath.Join(dir, "s3", "bkt", "good", o))) {
			t.Errorf("verified run: %s differs from the plain run", o)
		}
	}
	if !bytes.Equal(read(plain+"/rep"), read(filepath.Join(dir, "good-rep-0"))) {
		t.Error("verified run: the report differs from the plain run's")
	}

	for rank, st := range cluster("bad", bad.URL, 2) {
		if st != exitFailure {
			t.Errorf("corrupted object, rank %d: exit %d, want %d", rank, st, exitFailure)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "s3", "bkt", "bad")); !os.IsNotExist(err) {
		t.Errorf("corrupted object: outputs exist (%v)", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "bad-rep-0")); !os.IsNotExist(err) {
		t.Errorf("corrupted object: a report exists (%v)", err)
	}
	if p := fake.Dir.Pending(); len(p) != 0 {
		t.Errorf("multipart uploads left open: %v", p)
	}

	// In-process (one process, local hash.k2d): the right ETag passes, a wrong one fails.
	inproc := func(tag string) int {
		env := map[string]string{"AK2_ENGINE_N": "2", "AK2_ENGINE_HASH_ETAG": tag, "AK2_ENGINE_VERIFY_ETAG": "1"}
		lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
		base := filepath.Join(dir, "inproc")
		os.MkdirAll(base, 0o755)
		return runEnv(args(base, base+"/rep"), lookup)
	}
	if st := inproc(etag); st != 0 {
		t.Fatalf("in-process verified run: exit %d", st)
	}
	if !bytes.Equal(read(plain+"/out"), read(filepath.Join(dir, "inproc", "out"))) {
		t.Error("in-process verified run: output differs from the plain run")
	}
	wrong := []byte(etag)
	if wrong[0] = '0'; etag[0] == '0' { // still a well-formed ETag of the same part count
		wrong[0] = '1'
	}
	if st := inproc(string(wrong)); st != exitFailure {
		t.Fatalf("in-process run with a wrong ETag: exit %d, want %d", st, exitFailure)
	}

	// The failure reasons, from the loaders themselves.
	load := func(env map[string]string, rank int) error {
		conf, err := engineFromEnv(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
		if err != nil {
			return err
		}
		var e *engineIndex
		if conf.cluster != nil {
			e, err = loadNode(hashPath, conf, 8, 2, 1)
		} else {
			e, err = loadEngine(hashPath, conf, 8, 2)
		}
		if e != nil {
			e.close()
		}
		return err
	}
	var wg sync.WaitGroup
	errs := make([]error, 2)
	for rank := range 2 {
		env := map[string]string{"AK2_ENGINE_N": "2", "AK2_ENGINE_RANK": strconv.Itoa(rank),
			"AK2_ENGINE_RENDEZVOUS": filepath.Join(dir, "rv-reason"), "AK2_ENGINE_TIMEOUT": "2m",
			"AK2_ENGINE_HASH_URL": bad.URL, "AK2_ENGINE_HASH_ETAG": etag,
			"AK2_ENGINE_HASH_SIZE": strconv.FormatInt(size, 10), "AK2_ENGINE_VERIFY_ETAG": "1"}
		wg.Add(1)
		go func() { defer wg.Done(); errs[rank] = load(env, rank) }()
	}
	wg.Wait()
	for rank, err := range errs {
		if !errors.Is(err, engine.ErrETagMismatch) {
			t.Errorf("corrupted object, rank %d: %v; want ErrETagMismatch", rank, err)
		}
	}
	inEnv := func(tag, part string) map[string]string {
		m := map[string]string{"AK2_ENGINE_N": "2", "AK2_ENGINE_HASH_ETAG": tag, "AK2_ENGINE_VERIFY_ETAG": "1"}
		if part != "" {
			m["AK2_ENGINE_ETAG_PART_BYTES"] = part
		}
		return m
	}
	for _, c := range []struct {
		name, tag, part string
		want            error
	}{
		{"right ETag, given part size", etag, "8388608", nil},
		{"wrong ETag", string(wrong), "", engine.ErrETagMismatch},
		{"wrong given part size", etag, "4194304", engine.ErrETagFormat},
		{"not an md5 ETag (SSE-KMS)", "abc123-78", "", engine.ErrETagFormat},
	} {
		if err := load(inEnv(c.tag, c.part), 0); (c.want == nil) != (err == nil) || (c.want != nil && !errors.Is(err, c.want)) {
			t.Errorf("in-process, %s: %v; want %v", c.name, err, c.want)
		}
	}
	// Verification without the engine is an error, not ignored.
	if st := runEnv(args(filepath.Join(dir, "inproc"), filepath.Join(dir, "inproc", "rep")),
		func(k string) (string, bool) {
			return map[string]string{"AK2_ENGINE_VERIFY_ETAG": "1"}[k], k == "AK2_ENGINE_VERIFY_ETAG"
		}); st != exUsage {
		t.Errorf("AK2_ENGINE_VERIFY_ETAG=1 without AK2_ENGINE_N: exit %d, want %d", st, exUsage)
	}
}
