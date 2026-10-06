package seqio

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// rec is a comparable rendering of a Record.
func rec(r Record) string {
	q := "<nil>"
	if r.Qual != nil {
		q = string(r.Qual)
	}
	return fmt.Sprintf("%s|id=%q|c=%q|s=%q|q=%q", r.Format, r.ID, r.Comment, r.Seq, q)
}

func readAll(t *testing.T, in string, batch int) ([]string, Fault) {
	t.Helper()
	r := NewReader(strings.NewReader(in))
	var out []string
	var f Fault
	for {
		b := r.LoadRecords(batch)
		if b == nil {
			break
		}
		recs, bf := b.Parse()
		if len(recs) != b.Records() {
			t.Fatalf("Parse gave %d records, load counted %d", len(recs), b.Records())
		}
		f.Count += bf.Count
		if f.First == "" {
			f.First = bf.First
		}
		for _, x := range recs {
			out = append(out, rec(x))
		}
	}
	if r.Err() != nil {
		t.Fatalf("err: %v", r.Err())
	}
	return out, f
}

func TestParseCases(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []string
	}{
		{"fastq", "@r1 c1\nACGT\n+\nIIII\n@r2\nGG\n+r2\nII\n", []string{
			`FASTQ|id="r1"|c="c1"|s="ACGT"|q="IIII"`,
			`FASTQ|id="r2"|c=""|s="GG"|q="II"`}},
		{"multiline fasta", ">a desc here\nAC\nGT\n\nTT\n>b\n>c\nA", []string{
			`FASTA|id="a"|c="desc here"|s="ACGTTT"|q="<nil>"`,
			`FASTA|id="b"|c=""|s=""|q="<nil>"`,
			`FASTA|id="c"|c=""|s="A"|q="<nil>"`}},
		{"crlf", "@r1 x y\r\nACG\r\n+\r\nIII\r\n>f\r\nAA\r\nCC\r\n", []string{
			`FASTQ|id="r1"|c="x y"|s="ACG"|q="III"`,
			`FASTA|id="f"|c=""|s="AACC"|q="<nil>"`}},
		{"header whitespace", "@a\tb c\nA\n+\nI\n@d  e\nA\n+\nI\n@f \nA\n+\nI\n@g x\r\r\nA\n+\nI\n", []string{
			`FASTQ|id="a"|c="b c"|s="A"|q="I"`,
			`FASTQ|id="d"|c=" e"|s="A"|q="I"`,
			`FASTQ|id="f"|c=""|s="A"|q="I"`,
			`FASTQ|id="g"|c="x"|s="A"|q="I"`}},
		{"comments and junk between records", "# comment\n\n;x\n@r\nA\n+\nI\nfoo\n@s\nA\n+\nI\n", []string{
			`FASTQ|id="r"|c=""|s="A"|q="I"`,
			`FASTQ|id="s"|c=""|s="A"|q="I"`}},
		{"quality starting with marker", "@r\nACGT\n+\n@III\n@s\nA\n+\n>\n", []string{
			`FASTQ|id="r"|c=""|s="ACGT"|q="@III"`,
			`FASTQ|id="s"|c=""|s="A"|q=">"`}},
		{"wrapped quality", "@r\nACGT\nAC\n+\nIII\nIII\n@s\nA\n+\nI", []string{
			`FASTQ|id="r"|c=""|s="ACGTAC"|q="IIIIII"`,
			`FASTQ|id="s"|c=""|s="A"|q="I"`}},
		{"empty fastq read is fasta", "@e\n\n+\n\n@f\nA\n+\nI\n", []string{
			`FASTA|id="e"|c=""|s=""|q=""`,
			`FASTQ|id="f"|c=""|s="A"|q="I"`}},
		{"fastq cut before plus", "@a\nAC\n@b\nA\n+\nI\n", []string{
			`FASTA|id="a"|c=""|s="AC"|q="<nil>"`,
			`FASTQ|id="b"|c=""|s="A"|q="I"`}},
		{"long quality is a fault", "@a\nAC\n+\nIII\n@b\nA\n+\nI\n", []string{
			`FASTA|id="a"|c=""|s="AC"|q="III"`,
			`FASTQ|id="b"|c=""|s="A"|q="I"`}},
		{"short quality at eof is a fault", "@a\nACGT\n+\nII", []string{
			`FASTA|id="a"|c=""|s="ACGT"|q="II"`}},
		{"plus with no quality at eof", "@a\n\n+\n", []string{
			`FASTA|id="a"|c=""|s=""|q="<nil>"`}},
		{"bom", "\xef\xbb\xbf>a\nAC\n", []string{`FASTA|id="a"|c=""|s="AC"|q="<nil>"`}},
		{"trailing blank lines", ">a\nAC\n\n\n", []string{`FASTA|id="a"|c=""|s="AC"|q="<nil>"`}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			for _, batch := range []int{1, 2, 1000} {
				got, _ := readAll(t, c.in, batch)
				if strings.Join(got, "\n") != strings.Join(c.want, "\n") {
					t.Fatalf("batch %d:\ngot  %q\nwant %q", batch, got, c.want)
				}
			}
		})
	}
}

func TestFaultMessage(t *testing.T) {
	_, f := readAll(t, "@a\nAC\n+\nIII\n@b\nACGT\n+\nII", 10)
	if f.Count != 2 || f.First != "sequence reader - record 'a' has 2 bases and 3 quality values" {
		t.Fatalf("fault %+v", f)
	}
	_, f = readAll(t, "@b\nACGT\n+\nII", 10)
	if f.First != "sequence reader - record 'b' ends with 4 bases and 2 quality values" {
		t.Fatalf("fault %+v", f)
	}
}

func TestPrimeErrors(t *testing.T) {
	for in, want := range map[string]string{
		"\x1f\x8b\x08rest":  "sequence reader - input is gzip-compressed; decompress it before classifying",
		"BZh91AY":           "sequence reader - input is bzip2-compressed; decompress it before classifying",
		"hello\n>a\nAC\n":   msgUnrecognized,
		"  >a\nAC\n":        msgUnrecognized,
		"#x\x00y\n>a\nAC\n": msgUnrecognized,
	} {
		r := NewReader(strings.NewReader(in))
		if _, err := r.NextBatch(10); err == nil || err.Error() != want {
			t.Errorf("%q: err %v, want %q", in, err, want)
		}
	}
	r := NewReader(strings.NewReader(""))
	if has, err := r.Prime(); has || err != nil {
		t.Fatalf("empty: %v %v", has, err)
	}
	if _, err := r.NextBatch(1); err != io.EOF {
		t.Fatalf("empty: %v", err)
	}
	r = NewReader(strings.NewReader("\n; c\n@a\nA\n+\nI\n"))
	if _, err := r.Prime(); err != nil || r.Format() != FormatFASTQ {
		t.Fatalf("format %v err %v", r.Format(), err)
	}
}

// randomInput builds synthetic FASTA/FASTQ with the awkward shapes the rules cover.
func randomInput(rng *rand.Rand, n int) string {
	var sb strings.Builder
	bases := "ACGTN"
	quals := "!#5I@>+"
	seq := func(l int, alpha string) string {
		b := make([]byte, l)
		for i := range b {
			b[i] = alpha[rng.Intn(len(alpha))]
		}
		return string(b)
	}
	nl := func() string {
		if rng.Intn(5) == 0 {
			return "\r\n"
		}
		return "\n"
	}
	if rng.Intn(4) == 0 {
		sb.WriteString("# lead" + nl() + nl())
	}
	for i := 0; i < n; i++ {
		l := rng.Intn(40)
		s := seq(l, bases)
		hdr := fmt.Sprintf("r%d", i)
		if rng.Intn(2) == 0 {
			hdr += []string{" ", "\t", "  "}[rng.Intn(3)] + "c" + seq(rng.Intn(5), "xyz /")
		}
		if rng.Intn(3) == 0 {
			sb.WriteString(">" + hdr + nl())
			for len(s) > 0 {
				k := 1 + rng.Intn(15)
				k = min(k, len(s))
				sb.WriteString(s[:k] + nl())
				s = s[k:]
				if rng.Intn(6) == 0 {
					sb.WriteString(nl())
				}
			}
			continue
		}
		sb.WriteString("@" + hdr + nl() + s + nl() + "+" + nl())
		q := seq(l, quals)
		if rng.Intn(15) == 0 {
			q += "I" // malformed
		}
		if rng.Intn(4) == 0 && len(q) > 2 {
			sb.WriteString(q[:2] + nl() + q[2:] + nl())
		} else {
			sb.WriteString(q + nl())
		}
	}
	out := sb.String()
	if rng.Intn(3) == 0 {
		out = strings.TrimRight(out, "\r\n")
	}
	return out
}

// Blocks must not change what is parsed: any target size and any record limit give the
// same records as one whole-input parse.
func TestBlockInvariance(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 300; iter++ {
		in := randomInput(rng, 1+rng.Intn(60))
		want, wf := readAll(t, in, 1<<30)
		for _, target := range []int{1, 3, 17, 64, 1 << 20} {
			r := NewReader(&chunky{s: in, rng: rng})
			var got []string
			for {
				b := r.LoadBlock(target, 1)
				if b == nil {
					break
				}
				recs, _ := b.Parse()
				if len(recs) != b.Records() {
					t.Fatalf("iter %d target %d: parsed %d, counted %d", iter, target, len(recs), b.Records())
				}
				for _, x := range recs {
					got = append(got, rec(x))
				}
			}
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Fatalf("iter %d target %d mismatch\ninput %q\ngot  %q\nwant %q", iter, target, in, got, want)
			}
		}
		for _, k := range []int{1, 2, 7} {
			got, f := readAll(t, in, k)
			if strings.Join(got, "\n") != strings.Join(want, "\n") || f != wf {
				t.Fatalf("iter %d records %d mismatch", iter, k)
			}
		}
	}
}

// chunky returns short reads, as a pipe would.
type chunky struct {
	s   string
	rng *rand.Rand
}

func (c *chunky) Read(p []byte) (int, error) {
	if len(c.s) == 0 {
		return 0, io.EOF
	}
	n := min(len(p), 1+c.rng.Intn(9), len(c.s))
	copy(p, c.s[:n])
	c.s = c.s[n:]
	return n, nil
}

func ids(rs []Record) string {
	var s []string
	for _, r := range rs {
		s = append(s, string(r.ID))
	}
	return strings.Join(s, ",")
}

func fq(ids ...string) string {
	var sb strings.Builder
	for _, id := range ids {
		sb.WriteString("@" + id + "\nAC\n+\nII\n")
	}
	return sb.String()
}

func readPairs(p *PairedReader, batch int) (string, string, error) {
	var a, b []Record
	for {
		m1, m2, err := p.NextBatch(batch)
		if err != nil {
			return ids(a), ids(b), err
		}
		a, b = append(a, m1...), append(b, m2...)
	}
}

func TestPaired(t *testing.T) {
	for _, batch := range []int{1, 2, 100} {
		p := NewPairedReader(NewReader(strings.NewReader(fq("a/1", "b/1"))), NewReader(strings.NewReader(fq("a/2", "b/2"))))
		if a, b, err := readPairs(p, batch); a != "a/1,b/1" || b != "a/2,b/2" || err != io.EOF {
			t.Fatalf("equal: %s %s %v", a, b, err)
		}
		p = NewPairedReader(NewReader(strings.NewReader(fq("a", "b", "c"))), NewReader(strings.NewReader(fq("a", "b"))))
		if a, b, err := readPairs(p, batch); a != "a,b" || b != "a,b" || !errors.Is(err, ErrMateCountMismatch) {
			t.Fatalf("second short: %s %s %v", a, b, err)
		}
		p = NewPairedReader(NewReader(strings.NewReader(fq("a", "b"))), NewReader(strings.NewReader(fq("a", "b", "c"))))
		if a, b, err := readPairs(p, batch); a != "a,b" || b != "a,b" || !errors.Is(err, ErrMateCountMismatch) {
			t.Fatalf("first short: %s %s %v", a, b, err)
		}
		// Trailing blank lines on either side are not records.
		p = NewPairedReader(NewReader(strings.NewReader(fq("a")+"\n\n")), NewReader(strings.NewReader(fq("a")+"\n# x\n")))
		if a, _, err := readPairs(p, batch); a != "a" || err != io.EOF {
			t.Fatalf("trailing blanks: %s %v", a, err)
		}
		p = NewInterleavedReader(NewReader(strings.NewReader(fq("a/1", "a/2", "b/1", "b/2", "c/1"))))
		if a, b, err := readPairs(p, batch); a != "a/1,b/1" || b != "a/2,b/2" || err != io.EOF {
			t.Fatalf("interleaved: %s %s %v", a, b, err)
		}
	}
	// The block API pairs the same way.
	p := NewPairedReader(NewReader(strings.NewReader(fq("a", "b", "c"))), NewReader(strings.NewReader(fq("a", "b"))))
	var n int
	for {
		b1, b2, ok := p.LoadBlocks(5)
		if !ok {
			break
		}
		m1, m2, _ := PairBlocks(b1, b2)
		if len(m1) != len(m2) {
			t.Fatal("unequal mates")
		}
		n += len(m1)
	}
	if n != 2 || !errors.Is(p.Err(), ErrMateCountMismatch) {
		t.Fatalf("blocks: %d %v", n, p.Err())
	}
}

func TestMatesAgree(t *testing.T) {
	for _, c := range []struct {
		a, b string
		want bool
	}{{"x", "x", true}, {"x", "y", false}, {"x/1", "x/2", true}, {"x/1", "y/2", false}, {"x/1", "x", false}, {"xy/1", "x/2", false}} {
		if got := MatesAgree(&Record{ID: []byte(c.a)}, &Record{ID: []byte(c.b)}); got != c.want {
			t.Errorf("%s %s: %v", c.a, c.b, got)
		}
	}
}

func TestMaskLowQuality(t *testing.T) {
	r := Record{Seq: []byte("ACGTA"), Qual: []byte("!+5I\x90")}
	MaskLowQuality(&r, 10)
	if string(r.Seq) != "xCGTA" { // 0x90 is unsigned (Linux aarch64): high quality, kept
		t.Fatalf("got %s", r.Seq)
	}
	r = Record{Seq: []byte("AC"), Qual: []byte{0xff, 0x80}}
	MaskLowQuality(&r, 93)
	if string(r.Seq) != "AC" {
		t.Fatalf("high bytes masked: %s", r.Seq)
	}
	r = Record{Seq: []byte("ACGT"), Qual: []byte("!!")} // malformed: masks the covered part
	MaskLowQuality(&r, 1)
	if string(r.Seq) != "xxGT" {
		t.Fatalf("got %s", r.Seq)
	}
	r = Record{Seq: []byte("AC")}
	MaskLowQuality(&r, 40)
	if string(r.Seq) != "AC" {
		t.Fatal("fasta masked")
	}
}

func TestOpenCompression(t *testing.T) {
	dir := t.TempDir()
	text := fq("a", "b", "c")
	plain := filepath.Join(dir, "r.fq")
	os.WriteFile(plain, []byte(text), 0o644)
	gz := filepath.Join(dir, "r.fq.gz")
	var buf bytes.Buffer
	for _, part := range []string{fq("a", "b"), fq("c")} { // two gzip members
		w := gzip.NewWriter(&buf)
		w.Write([]byte(part))
		w.Close()
	}
	os.WriteFile(gz, buf.Bytes(), 0o644)

	for _, c := range []struct {
		path      string
		gz, bz    bool
		want      Compression
		wantError bool
	}{{plain, false, false, CompressionNone, false}, {gz, false, false, CompressionGzip, false},
		{plain, true, false, CompressionGzip, false}, {plain, true, true, CompressionNone, true}} {
		got, err := ResolveCompression(c.gz, c.bz, c.path)
		if (err != nil) != c.wantError || got != c.want {
			t.Errorf("%s gz=%v bz=%v: %v %v", c.path, c.gz, c.bz, got, err)
		}
	}
	for path, comp := range map[string]Compression{plain: CompressionNone, gz: CompressionGzip} {
		r, err := Open(path, comp)
		if err != nil {
			t.Fatal(err)
		}
		var got []Record
		for {
			b, err := r.NextBatch(1)
			if err == io.EOF {
				break
			} else if err != nil {
				t.Fatal(err)
			}
			got = append(got, b...)
		}
		r.Close()
		if ids(got) != "a,b,c" {
			t.Fatalf("%s: %s", path, ids(got))
		}
	}
	// As with the wrapper's gzip -dc, a decompression error ends the input cleanly after the
	// bytes decoded so far, and is only logged.
	var logged bytes.Buffer
	DecompressLog = &logged
	defer func() { DecompressLog = os.Stderr }()
	readIDs := func(path string, c Compression) string {
		r, err := Open(path, c)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		var got []Record
		for {
			b, err := r.NextBatch(2)
			if err == io.EOF {
				return ids(got)
			} else if err != nil {
				t.Fatalf("%s: %v", path, err)
			}
			got = append(got, b...)
		}
	}
	if got := readIDs(plain, CompressionGzip); got != "" || logged.Len() == 0 {
		t.Fatalf("plain as gzip: %q, log %q", got, logged.String())
	}
	for name, tail := range map[string][]byte{"zeros": make([]byte, 1000), "garbage": []byte("not gzip\n")} {
		logged.Reset()
		p := filepath.Join(dir, name+".gz")
		os.WriteFile(p, append(append([]byte(nil), buf.Bytes()...), tail...), 0o644)
		if got := readIDs(p, CompressionGzip); got != "a,b,c" || logged.Len() == 0 {
			t.Fatalf("trailing %s: %q, log %q", name, got, logged.String())
		}
	}
	var big bytes.Buffer
	w := gzip.NewWriter(&big)
	for i := 0; i < 5000; i++ {
		fmt.Fprintf(w, "@r%d\nACGTACGTAC\n+\nIIIIIIIIII\n", i)
	}
	w.Close()
	trunc := filepath.Join(dir, "trunc.gz")
	os.WriteFile(trunc, big.Bytes()[:big.Len()/2], 0o644)
	logged.Reset()
	if got := readIDs(trunc, CompressionGzip); !strings.HasPrefix(got, "r0,r1,") || strings.Contains(got, "r4999") || logged.Len() == 0 {
		t.Fatalf("truncated: %d ids, log %q", strings.Count(got, ","), logged.String())
	}
	r, _ := Open(gz, CompressionNone)
	if _, err := r.NextBatch(1); err == nil || !strings.Contains(err.Error(), "gzip-compressed") {
		t.Fatalf("gzip as plain: %v", err)
	}
	r.Close()
}
