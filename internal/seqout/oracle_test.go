package seqout

// Oracle equivalence for seqio + seqout, independent of the classifier port: the class and
// taxid of each read come from upstream's --output, the reads from seqio, the bytes from
// seqout, and the result is compared with upstream's --classified-out / --unclassified-out.
// scripts/equiv-seqout.sh produces the upstream side and runs this; without it the test skips.

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/seqio"
)

type oracleCase struct {
	name, gzipFlag, krakenOut, cls, uncls string
	paired                                bool
	minQ                                  int
	inputs                                []string
}

// cases.tsv: name paired(0/1) gzip_flag(0/1) minq kraken_out cls_pattern uncls_pattern input1 [input2]
func loadCases(t *testing.T, dir string) []oracleCase {
	data, err := os.ReadFile(filepath.Join(dir, "cases.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	var cs []oracleCase
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		f := strings.Split(line, "\t")
		if len(f) < 8 || strings.HasPrefix(line, "#") {
			continue
		}
		q, _ := strconv.Atoi(f[3])
		cs = append(cs, oracleCase{name: f[0], paired: f[1] == "1", gzipFlag: f[2], minQ: q,
			krakenOut: f[4], cls: f[5], uncls: f[6], inputs: f[7:]})
	}
	return cs
}

func TestOracleSeqout(t *testing.T) {
	dir := os.Getenv("K2_SEQOUT_ORACLE")
	if dir == "" {
		t.Skip("K2_SEQOUT_ORACLE not set (scripts/equiv-seqout.sh sets it)")
	}
	var summary bytes.Buffer
	summary.WriteString("case\trecords\tclassified\tid_len_mismatches\tfile\tbytes\tsha256_upstream\tsha256_go\tidentical\n")
	for _, c := range loadCases(t, dir) {
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

func runOracleCase(t *testing.T, c oracleCase, summary *bytes.Buffer) {
	out := t.TempDir()
	comp, err := seqio.ResolveCompression(c.gzipFlag == "1", false, c.inputs[0])
	if err != nil {
		t.Fatal(err)
	}
	var readers []*seqio.Reader
	for _, in := range c.inputs {
		r, err := seqio.Open(in, comp)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		readers = append(readers, r)
	}
	var pr *seqio.PairedReader
	if c.paired {
		pr = seqio.NewPairedReader(readers[0], readers[1])
	}
	var has bool
	if pr != nil {
		has, err = pr.Prime()
	} else {
		has, err = readers[0].Prime()
	}
	if err != nil || !has {
		t.Fatalf("prime: %v %v", has, err)
	}
	clsGo := filepath.Join(out, filepath.Base(c.cls))
	unclsGo := filepath.Join(out, filepath.Base(c.uncls))
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
	var seq uint64
	var wg sync.WaitGroup
	for {
		var m1, m2 []seqio.Record
		if pr != nil {
			m1, m2, err = pr.NextBatch(4096)
		} else {
			m1, err = readers[0].NextBatch(4096)
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("read: %v", err)
		}
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

	pairs := [][2]string{{c.cls, clsGo}, {c.uncls, unclsGo}}
	if c.paired {
		pairs = nil
		for _, p := range [][2]string{{c.cls, clsGo}, {c.uncls, unclsGo}} {
			a1, a2, _ := PairedNames(p[0])
			b1, b2, _ := PairedNames(p[1])
			pairs = append(pairs, [2]string{a1, b1}, [2]string{a2, b2})
		}
	}
	for _, p := range pairs {
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
		fmt.Fprintf(summary, "%s\t%d\t%d\t%d\t%s\t%d\t%s\t%s\t%v\n", c.name, records, classified, mismatches,
			filepath.Base(p[0]), len(up), hex.EncodeToString(hu[:]), hex.EncodeToString(hg[:]), same)
	}
	t.Logf("%s: %d records, %d classified, %d id/len mismatches", c.name, records, classified, mismatches)
}
