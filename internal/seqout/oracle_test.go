package seqout

// Oracle equivalence for seqio + seqout, independent of the classifier port: the class and
// taxid of each read come from upstream's --output, the reads from seqio's production path
// (LoadBlock / LoadBlocks at DefaultBlockBytes, then Parse / PairBlocks), the bytes from
// seqout, and the result is compared with upstream's --classified-out / --unclassified-out.
// The run's end state (clean, malformed records, unequal mates, empty input) must give
// upstream's exit status and message. scripts/equiv-seqout.sh produces the upstream side and
// runs this; without it the test skips.

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/seqio"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

type oracleCase struct {
	name, comp, krakenOut, cls, uncls, stderr string
	paired                                    bool
	minQ, upstreamExit                        int
	inputs                                    []string
}

// cases.tsv: name paired comp(none|gz|bz2) minq upstream_exit kraken_out cls uncls stderr inputs...
func loadCases(t *testing.T, dir string) []oracleCase {
	data, err := os.ReadFile(filepath.Join(dir, "cases.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	var cs []oracleCase
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 10 {
			t.Fatalf("bad cases.tsv line %q", line)
		}
		q, _ := strconv.Atoi(f[3])
		ex, _ := strconv.Atoi(f[4])
		cs = append(cs, oracleCase{name: f[0], paired: f[1] == "1", comp: f[2], minQ: q, upstreamExit: ex,
			krakenOut: f[5], cls: f[6], uncls: f[7], stderr: f[8], inputs: f[9:]})
	}
	return cs
}

func TestOracleSeqout(t *testing.T) {
	dir := os.Getenv("K2_SEQOUT_ORACLE")
	if dir == "" {
		// The latest make equiv-seqout work directory, if there is one.
		dir = filepath.Join(oracletest.Root(), ".cache", "equiv-seqout", "latest")
	}
	if _, err := os.Stat(filepath.Join(dir, "cases.tsv")); err != nil {
		oracletest.Skip(t, "no seqout oracle at %s (make equiv-seqout)", dir)
	}
	cases := loadCases(t, dir)
	if len(cases) == 0 {
		t.Fatal("no oracle cases")
	}
	want := os.Getenv("K2_SEQOUT_EXPECTED_CASES")
	if b, err := os.ReadFile(filepath.Join(dir, "expected_cases")); want == "" && err == nil {
		want = strings.TrimSpace(string(b))
	}
	if want != "" && want != strconv.Itoa(len(cases)) {
		t.Fatalf("%d oracle cases, expected %s", len(cases), want)
	}
	seqio.DecompressLog = io.Discard // upstream's gzip -dc complaints go to its stderr only
	var summary bytes.Buffer
	summary.WriteString("case\trecords\tclassified\tid_len_mismatches\texit_upstream\texit_go\tfile\tbytes\tsha256_upstream\tsha256_go\tidentical\n")
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runOracleCase(t, c, &summary) })
	}
	if out := os.Getenv("K2_SEQOUT_SUMMARY"); out != "" {
		if err := os.WriteFile(out, summary.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

type krakenLine struct {
	classified bool
	id, length string
	taxid      uint64
}

func trimPairInfo(id []byte) []byte {
	if n := len(id); n > 2 && id[n-2] == '/' && (id[n-1] == '1' || id[n-1] == '2') {
		return id[:n-2]
	}
	return id
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func outputPairs(c oracleCase, clsGo, unclsGo string) [][2]string {
	if !c.paired {
		return [][2]string{{c.cls, clsGo}, {c.uncls, unclsGo}}
	}
	var pairs [][2]string
	for _, p := range [][2]string{{c.cls, clsGo}, {c.uncls, unclsGo}} {
		a1, a2, _ := PairedNames(p[0])
		b1, b2, _ := PairedNames(p[1])
		pairs = append(pairs, [2]string{a1, b1}, [2]string{a2, b2})
	}
	return pairs
}

func runOracleCase(t *testing.T, c oracleCase, summary *bytes.Buffer) {
	out := t.TempDir()
	comp, err := seqio.ResolveCompression(c.comp == "gz", c.comp == "bz2", c.inputs[0])
	if err != nil {
		t.Fatal(err)
	}
	// AK2_DECOMPRESS=pipe: read through seqio.OpenPipe (make equiv-seqout under pipe mode).
	dec, err := seqio.ParseDecompressor(os.Getenv("AK2_DECOMPRESS"))
	if err != nil {
		t.Fatal(err)
	}
	var readers []*seqio.Reader
	for _, in := range c.inputs {
		r, err := seqio.OpenWith(in, comp, dec)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		readers = append(readers, r)
	}
	var pr *seqio.PairedReader
	var has bool
	if c.paired {
		pr = seqio.NewPairedReader(readers[0], readers[1])
		has, err = pr.Prime()
	} else {
		has, err = readers[0].Prime()
	}
	if err != nil {
		t.Fatalf("prime: %v", err)
	}
	clsGo := filepath.Join(out, filepath.Base(c.cls))
	unclsGo := filepath.Join(out, filepath.Base(c.uncls))
	upstreamStderr, _ := os.ReadFile(c.stderr)

	if !has {
		// Upstream opens no output at all for an empty first input; neither do we.
		for _, p := range append(outputPairs(c, clsGo, unclsGo), [2]string{c.krakenOut, ""}) {
			if exists(p[0]) {
				t.Errorf("upstream created %s for empty input", filepath.Base(p[0]))
			}
		}
		if c.upstreamExit != 0 {
			t.Errorf("empty input: upstream exit %d, ours 0", c.upstreamExit)
		}
		fmt.Fprintf(summary, "%s\t0\t0\t0\t%d\t0\t(no output files, both)\t0\t-\t-\ttrue\n", c.name, c.upstreamExit)
		return
	}

	w, err := Open(clsGo, unclsGo, c.paired)
	if err != nil {
		t.Fatal(err)
	}
	ord := NewOrdered(func(b *Batch) error { return w.Write(b) }, 16)

	kf, err := os.Open(c.krakenOut)
	if err != nil {
		t.Fatal(err)
	}
	defer kf.Close()
	ks := bufio.NewScanner(kf)
	ks.Buffer(make([]byte, 1<<20), 1<<26)
	nextLine := func() (krakenLine, bool) {
		if !ks.Scan() {
			return krakenLine{}, false
		}
		f := strings.SplitN(ks.Text(), "\t", 5)
		if len(f) < 4 {
			t.Fatalf("bad --output line %q", ks.Text())
		}
		tx, err := strconv.ParseUint(f[2], 10, 64)
		if err != nil {
			t.Fatalf("taxid %q: %v", f[2], err)
		}
		return krakenLine{classified: f[0] == "C", id: f[1], length: f[3], taxid: tx}, true
	}

	var records, classified, mismatches int
	var fault seqio.Fault
	var seq uint64
	var wg sync.WaitGroup
	for {
		// The production path: the sequential cut, then the parse (here on this goroutine).
		var m1, m2 []seqio.Record
		var f seqio.Fault
		if pr != nil {
			b1, b2, ok := pr.LoadBlocks(seqio.DefaultBlockBytes)
			if !ok {
				break
			}
			m1, m2, f = seqio.PairBlocks(b1, b2)
		} else {
			b := readers[0].LoadBlock(seqio.DefaultBlockBytes, 1)
			if b == nil {
				break
			}
			m1, f = b.Parse()
		}
		if f.Count > 0 && fault.First == "" {
			fault.First = f.First
		}
		fault.Count += f.Count
		lines := make([]krakenLine, len(m1))
		for i := range m1 {
			kl, ok := nextLine()
			if !ok {
				t.Fatalf("--output ended at record %d", records)
			}
			lines[i] = kl
			id, length := m1[i].ID, strconv.Itoa(len(m1[i].Seq))
			if pr != nil {
				id = trimPairInfo(id)
				length += "|" + strconv.Itoa(len(m2[i].Seq))
			}
			if string(id) != kl.id || length != kl.length {
				if mismatches < 5 {
					t.Errorf("record %d: id %q len %s, upstream %q %s", records, id, length, kl.id, kl.length)
				}
				mismatches++
			}
			records++
			if kl.classified {
				classified++
			}
		}
		// Format on another goroutine, out of order with other batches; Ordered restores it.
		wg.Add(1)
		go func(s uint64, m1, m2 []seqio.Record, lines []krakenLine) {
			defer wg.Done()
			b := &Batch{}
			for i := range m1 {
				var mate *seqio.Record
				seqio.MaskLowQuality(&m1[i], c.minQ)
				if m2 != nil {
					mate = &m2[i]
					seqio.MaskLowQuality(mate, c.minQ)
				}
				b.Add(&m1[i], mate, lines[i].classified, lines[i].taxid)
			}
			ord.Submit(s, b)
		}(seq, m1, m2, lines)
		seq++
	}
	if _, more := nextLine(); more {
		t.Errorf("--output has lines beyond record %d", records)
	}
	wg.Wait()
	if err := ord.Close(); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}

	// End state: upstream exits 65 (EX_DATAERR) for malformed records or unequal mates.
	var endErr error
	if pr != nil {
		endErr = pr.Err()
	} else if endErr = readers[0].Err(); endErr == nil {
		endErr = io.EOF
	}
	goExit := 0
	switch {
	case errors.Is(endErr, seqio.ErrMateCountMismatch):
		goExit = 65
		if !bytes.Contains(upstreamStderr, []byte(seqio.ErrMateCountMismatch.Error())) {
			t.Errorf("upstream stderr lacks the mate-count message")
		}
	case endErr != io.EOF:
		t.Fatalf("read error: %v", endErr)
	}
	if fault.Count > 0 {
		goExit = 65
		msg := fault.First
		if fault.Count > 1 {
			msg += fmt.Sprintf(", and %d further malformed records", fault.Count-1)
		}
		if !bytes.Contains(upstreamStderr, []byte(msg)) {
			t.Errorf("upstream stderr lacks %q", msg)
		}
	}
	if goExit != c.upstreamExit {
		t.Errorf("exit: ours %d, upstream %d", goExit, c.upstreamExit)
	}

	for _, p := range outputPairs(c, clsGo, unclsGo) {
		up, err1 := os.ReadFile(p[0])
		got, err2 := os.ReadFile(p[1])
		if err1 != nil || err2 != nil {
			t.Fatalf("read outputs: %v %v", err1, err2)
		}
		same := bytes.Equal(up, got)
		if !same {
			t.Errorf("%s differs from upstream (%d vs %d bytes)", filepath.Base(p[0]), len(got), len(up))
		}
		hu, hg := sha256.Sum256(up), sha256.Sum256(got)
		fmt.Fprintf(summary, "%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%s\t%s\t%v\n", c.name, records, classified, mismatches,
			c.upstreamExit, goExit, filepath.Base(p[0]), len(up), hex.EncodeToString(hu[:]), hex.EncodeToString(hg[:]), same)
	}
	t.Logf("%s: %d records, %d classified, %d id/len mismatches, %d malformed, exit %d", c.name, records, classified, mismatches, fault.Count, goExit)
}
