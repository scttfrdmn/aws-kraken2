package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
	"github.com/scttfrdmn/aws-kraken2/internal/seqio"
)

// TestDecompressEnv: AK2_DECOMPRESS is read with the other settings; pipe selects
// seqio.OpenPipe, unset the in-process path, anything else is a usage error.
func TestDecompressEnv(t *testing.T) {
	db := t.TempDir()
	for _, f := range dbFiles() {
		if err := os.WriteFile(filepath.Join(db, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	args := []string{"--db", db, "x.fq.gz"}
	env := func(v string, set bool) func(string) (string, bool) {
		return func(k string) (string, bool) {
			if k == "AK2_DECOMPRESS" {
				return v, set
			}
			return "", false
		}
	}
	if c, st := buildArgs(args, env("", false)); c == nil || c.decomp != seqio.DecompressInProcess {
		t.Fatalf("unset: %v %d", c, st)
	}
	if c, st := buildArgs(args, env("pipe", true)); c == nil || c.decomp != seqio.DecompressPipe {
		t.Fatalf("pipe: %v %d", c, st)
	}
	if c, st := buildArgs(args, env("rapidgzip", true)); c != nil || st != exUsage {
		t.Fatalf("bad value: %v %d, want exit %d", c, st, exUsage)
	}
}

// TestDecompressPipeRun: a whole run on real reads under AK2_DECOMPRESS=pipe goes through the
// gzip on PATH (a shim that records its argv and runs the real gzip) and writes the same
// --output and --report as the in-process path. Each mate has its own child.
func TestDecompressPipeRun(t *testing.T) {
	db := oracletest.DB(t, "k2_viral_20260626")
	r1, r2 := oracletest.Reads(t, "SRR062634_200000_1.fq.gz"), oracletest.Reads(t, "SRR062634_200000_2.fq.gz")
	gzBin, err := exec.LookPath("gzip")
	if err != nil {
		t.Skip("no gzip on PATH")
	}
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	os.Mkdir(bin, 0o755)
	calls := filepath.Join(dir, "calls")
	sh := "#!/bin/sh\necho \"$*\" >> '" + calls + "'\nexec '" + gzBin + "' \"$@\"\n"
	if err := os.WriteFile(filepath.Join(bin, "gzip"), []byte(sh), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	run1 := func(tag, mode string) (string, string) {
		out, rep := filepath.Join(dir, tag+".out"), filepath.Join(dir, tag+".rep")
		env := func(k string) (string, bool) {
			if k == "AK2_DECOMPRESS" && mode != "" {
				return mode, true
			}
			return "", false
		}
		if st := runEnv([]string{"--db", db, "--threads", "4", "--paired", "--output", out, "--report", rep, r1, r2}, env); st != 0 {
			t.Fatalf("%s: exit %d", tag, st)
		}
		return out, rep
	}
	o1, p1 := run1("inprocess", "")
	if _, err := os.Stat(calls); err == nil {
		t.Fatal("the in-process run called gzip")
	}
	o2, p2 := run1("pipe", "pipe")
	got := strings.Split(strings.TrimSpace(string(mustRead(t, calls))), "\n")
	sort.Strings(got) // the two children run concurrently
	if want := []string{"-dc " + r1, "-dc " + r2}; strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("gzip calls %q, want %q", got, want)
	}
	for _, p := range [][2]string{{o1, o2}, {p1, p2}} {
		a, _ := os.ReadFile(p[0])
		b, _ := os.ReadFile(p[1])
		if len(a) == 0 || !bytes.Equal(a, b) {
			t.Errorf("%s and %s differ (%d, %d bytes)", filepath.Base(p[0]), filepath.Base(p[1]), len(a), len(b))
		}
	}
	if n := strings.Count(string(mustRead(t, o2)), "\n"); n != 200000 {
		t.Errorf("pipe run: %d output lines", n)
	}
}

func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
