package seqio

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// shim writes an executable sh script named name into dir.
func shim(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// pathOnly puts dir alone on PATH, as the only place a decompressor can come from.
func pathOnly(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PATH", dir)
}

func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var b bytes.Buffer
	DecompressLog = &b
	t.Cleanup(func() { DecompressLog = os.Stderr })
	return &b
}

func readAllIDs(t *testing.T, r *Reader) string {
	t.Helper()
	var got []Record
	for {
		b, err := r.NextBatch(2)
		if err == io.EOF {
			return ids(got)
		} else if err != nil {
			t.Fatal(err)
		}
		got = append(got, b...)
	}
}

func TestParseDecompressor(t *testing.T) {
	for in, want := range map[string]Decompressor{"": DecompressInProcess, "pipe": DecompressPipe} {
		if d, err := ParseDecompressor(in); err != nil || d != want {
			t.Errorf("%q: %v %v", in, d, err)
		}
	}
	for _, bad := range []string{"PIPE", "inprocess", "gzip", " pipe"} {
		if _, err := ParseDecompressor(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}

// TestOpenPipe: the wrapper's `gzip -dc FILE` / `bzip2 -dc FILE`, the program from PATH, its
// output read to the end, its exit status ignored and its stderr the run's.
func TestOpenPipe(t *testing.T) {
	bin := t.TempDir()
	argv := filepath.Join(t.TempDir(), "argv")
	for _, prog := range []string{"gzip", "bzip2"} {
		// Exits 2 after writing (as gzip does on trailing garbage) or 1 (as on truncation).
		shim(t, bin, prog, `printf '%s\n' "$0" "$@" > `+argv+`
printf '@a\nACGT\n+\nIIII\n@b\nACGT\n+\nIIII\n'
echo "`+prog+`: some complaint" >&2
exit `+map[string]string{"gzip": "2", "bzip2": "1"}[prog]+"\n")
	}
	pathOnly(t, bin)
	in := filepath.Join(t.TempDir(), "in put.gz") // a space: the wrapper quotemeta's the name
	if err := os.WriteFile(in, []byte("not read by the shim"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, c := range []Compression{CompressionGzip, CompressionBzip2} {
		log := captureLog(t)
		r, err := OpenWith(in, c, DecompressPipe)
		if err != nil {
			t.Fatal(err)
		}
		if got := readAllIDs(t, r); got != "a,b" {
			t.Errorf("%s: ids %q", c, got)
		}
		if err := r.Close(); err != nil {
			t.Errorf("%s: close: %v", c, err)
		}
		a, _ := os.ReadFile(argv)
		if want := filepath.Join(bin, c.String()) + "\n-dc\n" + in + "\n"; string(a) != want {
			t.Errorf("%s: argv %q, want %q", c, a, want)
		}
		if want := c.String() + ": some complaint\n"; log.String() != want {
			t.Errorf("%s: stderr %q, want %q", c, log.String(), want)
		}
	}
	// No compression: the file itself, no child.
	plain := filepath.Join(t.TempDir(), "p.fq")
	os.WriteFile(plain, []byte("@p\nAC\n+\nII\n"), 0o644)
	r, err := OpenPipe(plain, CompressionNone)
	if err != nil {
		t.Fatal(err)
	}
	if got := readAllIDs(t, r); got != "p" {
		t.Errorf("plain: %q", got)
	}
	r.Close()
}

// TestOpenPipeMissingTool: no gzip on PATH is an error for the caller to report (the wrapper's
// shell says "not found" and classify sees an empty stream).
func TestOpenPipeMissingTool(t *testing.T) {
	pathOnly(t, t.TempDir())
	if _, err := OpenPipe("/nonexistent.gz", CompressionGzip); err == nil {
		t.Fatal("no gzip on PATH, no error")
	}
}

// TestOpenPipeEmpty: a child that writes nothing (gzip -dc on a missing or plain file) is an
// empty stream, not an error.
func TestOpenPipeEmpty(t *testing.T) {
	bin := t.TempDir()
	shim(t, bin, "gzip", `echo "gzip: $2: No such file or directory" >&2; exit 1`+"\n")
	pathOnly(t, bin)
	log := captureLog(t)
	r, err := OpenPipe("/nonexistent.gz", CompressionGzip)
	if err != nil {
		t.Fatal(err)
	}
	has, err := r.Prime()
	if has || err != nil {
		t.Fatalf("prime: %v %v", has, err)
	}
	r.Close()
	if !strings.Contains(log.String(), "No such file") {
		t.Errorf("stderr %q", log.String())
	}
}

// TestOpenPipeEarlyClose: closing before the end stops a child that is still writing (SIGPIPE,
// as the wrapper's children get when classify exits) and reaps it.
func TestOpenPipeEarlyClose(t *testing.T) {
	bin := t.TempDir()
	shim(t, bin, "gzip", `exec /usr/bin/yes '@r'`+"\n")
	pathOnly(t, bin)
	r, err := OpenPipe("/x.gz", CompressionGzip)
	if err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4096)
	if _, err := io.ReadFull(r.src, buf); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { r.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("Close did not return: the child kept running")
	}
}

// TestOpenPipeStdin: the child shares the run's standard input, so `gzip -dc -` reads it.
func TestOpenPipeStdin(t *testing.T) {
	bin := t.TempDir()
	shim(t, bin, "gzip", `[ "$2" = - ] && exec /bin/cat`+"\n")
	pathOnly(t, bin)
	f := filepath.Join(t.TempDir(), "stdin")
	os.WriteFile(f, []byte("@s\nAC\n+\nII\n"), 0o644)
	in, err := os.Open(f)
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	old := os.Stdin
	os.Stdin = in
	defer func() { os.Stdin = old }()
	r, err := OpenPipe("-", CompressionGzip)
	if err != nil {
		t.Fatal(err)
	}
	if got := readAllIDs(t, r); got != "s" {
		t.Errorf("stdin: %q", got)
	}
	r.Close()
}
