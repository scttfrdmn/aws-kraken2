package mmscan_test

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/mmscan"
	"github.com/scttfrdmn/aws-kraken2/internal/mmscan/mmdump"
)

// Golden streams in testdata/ come from upstream's MinimizerScanner (upstream/mm_dump.cc)
// over synthetic sequences only. Regenerate with
//
//	scripts/harness-build.sh mm_dump
//	go test ./internal/mmscan -run TestGolden -update -mm-dump=$PWD/.oracle/harness/mm_dump
var (
	update = flag.Bool("update", false, "regenerate testdata/*.mmdump.gz with the upstream harness")
	mmDump = flag.String("mm-dump", "", "path to the built upstream/mm_dump harness (with -update)")
)

const viralSSM = 0x3ffffffff3333333 // spaced_seed_mask of the k2_viral_20260626 opts.k2d

type goldenCase struct {
	name     string
	k, l     uint64
	ssm, tm  uint64
	dna      bool
	revcom   int32
	fileBase string
}

var goldenCases = []goldenCase{
	{"k35l31-viral", 35, 31, viralSSM, mmscan.DefaultToggleMask, true, 1, ""},
	{"k35l31-revcom0", 35, 31, viralSSM, mmscan.DefaultToggleMask, true, 0, ""},
	{"k31l31-shortcircuit", 31, 31, viralSSM, mmscan.DefaultToggleMask, true, 1, ""},
	{"k10l5-lex", 10, 5, 0, 0, true, 1, ""},
	{"k20l11-revcom0-nossm", 20, 11, 0, mmscan.DefaultToggleMask, true, 0, ""},
	{"protein-k15l12", 15, 12, 0, mmscan.DefaultToggleMask, false, 1, ""},
	{"protein-k12l12", 12, 12, 0, mmscan.DefaultToggleMask, false, 1, ""},
}

// optsK2D encodes upstream's IndexOptions struct as opts.k2d stores it (64 bytes).
func optsK2D(c goldenCase) []byte {
	b := make([]byte, 64)
	le := binary.LittleEndian
	le.PutUint64(b[0:], c.k)
	le.PutUint64(b[8:], c.l)
	le.PutUint64(b[16:], c.ssm)
	le.PutUint64(b[24:], c.tm)
	if c.dna {
		b[32] = 1
	}
	le.PutUint32(b[48:], uint32(c.revcom))
	return b
}

// syntheticFASTA builds deterministic test sequences: clean DNA, DNA with N runs and
// IUPAC codes, mixed case, CRLF lines, very short sequences around l and k, and
// protein-alphabet sequences.
func syntheticFASTA() []byte {
	r := rand.New(rand.NewPCG(5, 2026))
	var buf bytes.Buffer
	const dna = "ACGT"
	const amb = "NNNNRYKMSWBDHVX.-n"
	const prot = "ACDEFGHIKLMNPQRSTVWY*UOBZJXacdefghiklmnpqrstvwy"
	for i := 0; i < 240; i++ {
		var n int
		switch i % 6 {
		case 0:
			n = r.IntN(45) // around l and k
		case 1:
			n = 100 + r.IntN(60)
		default:
			n = r.IntN(400)
		}
		seq := make([]byte, n)
		for j := range seq {
			switch {
			case i%5 == 4:
				seq[j] = prot[r.IntN(len(prot))]
			case i%3 == 0 && r.IntN(40) == 0:
				seq[j] = amb[r.IntN(len(amb))]
			case i%7 == 2 && r.IntN(300) == 0:
				for ; j < len(seq) && r.IntN(12) != 0; j++ { // an N run
					seq[j] = 'N'
				}
				j--
			default:
				seq[j] = dna[r.IntN(4)]
			}
			if j >= 0 && j < len(seq) && i%4 == 1 && r.IntN(3) == 0 {
				seq[j] |= 0x20 // lowercase
			}
		}
		// Sequence lines must not begin with a FASTA/FASTQ record marker.
		for len(seq) > 0 && (seq[0] == '>' || seq[0] == '@' || seq[0] == '+') {
			seq[0] = 'A'
		}
		eol := "\n"
		if i%9 == 3 {
			eol = "\r\n"
		}
		fmt.Fprintf(&buf, ">syn%d comment %d%s", i, n, eol)
		// wrap some sequences across lines
		w := len(seq) + 1
		if i%2 == 0 {
			w = 60
		}
		for o := 0; o < len(seq); o += w {
			e := min(o+w, len(seq))
			line := seq[o:e]
			if len(line) > 0 && (line[0] == '>' || line[0] == '@' || line[0] == '+') {
				line[0] = 'C'
			}
			buf.Write(line)
			buf.WriteString(eol)
		}
	}
	return buf.Bytes()
}

func goldenPath(c goldenCase) string {
	return filepath.Join("testdata", c.name+".mmdump.gz")
}

func regenerate(t *testing.T, c goldenCase, fasta string) {
	dir := t.TempDir()
	opts := filepath.Join(dir, "opts.k2d")
	if err := os.WriteFile(opts, optsK2D(c), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(*mmDump, "-r", opts, fasta)
	cmd.Stderr = os.Stderr
	raw, err := cmd.Output()
	if err != nil {
		t.Fatalf("%s: %v", *mmDump, err)
	}
	var gz bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&gz, gzip.BestCompression)
	zw.Write(raw)
	zw.Close()
	if err := os.MkdirAll("testdata", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(goldenPath(c), gz.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestGolden(t *testing.T) {
	fasta := ""
	if *update {
		if *mmDump == "" {
			t.Fatal("-update needs -mm-dump")
		}
		fasta = filepath.Join(t.TempDir(), "synthetic.fa")
		if err := os.WriteFile(fasta, syntheticFASTA(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range goldenCases {
		t.Run(c.name, func(t *testing.T) {
			if *update {
				regenerate(t, c, fasta)
			}
			f, err := os.Open(goldenPath(c))
			if errors.Is(err, os.ErrNotExist) {
				t.Fatalf("golden stream %s absent (regenerate with -update -mm-dump)", goldenPath(c))
			}
			if err != nil {
				t.Fatal(err)
			}
			defer f.Close()
			zr, err := gzip.NewReader(f)
			if err != nil {
				t.Fatal(err)
			}
			d, err := mmdump.NewReader(zr)
			if err != nil {
				t.Fatal(err)
			}
			h := d.Header
			if h.K != c.k || h.L != c.l || h.SpacedSeedMask != c.ssm || h.ToggleMask != c.tm ||
				h.DNA != c.dna || h.RevcomVersion != c.revcom || !h.RangeMode {
				t.Fatalf("golden header %+v does not match case %+v", h, c)
			}
			s, err := h.NewScanner()
			if err != nil {
				t.Fatal(err)
			}
			var recs, mms, ambig int
			for {
				rec, err := d.Next()
				if err == io.EOF {
					break
				}
				if err != nil {
					t.Fatal(err)
				}
				if m := mmdump.Check(s, rec); m != nil {
					t.Fatalf("record %d %s len %d [%d,%d): %s\nseq %s", recs, rec.Header, len(rec.Seq),
						rec.Start, int64(rec.Finish), m, rec.Seq)
				}
				recs++
				mms += len(rec.Minimizers)
				for _, a := range rec.Ambiguous {
					if a {
						ambig++
					}
				}
			}
			if uint64(recs) != d.Records || uint64(mms) != d.Minimizers {
				t.Fatalf("counts %d/%d vs end marker %d/%d", recs, mms, d.Records, d.Minimizers)
			}
			if mms == 0 || ambig == 0 {
				t.Fatalf("golden stream too weak: %d minimizers, %d ambiguous", mms, ambig)
			}
			t.Logf("%d scans, %d minimizers (%d ambiguous) identical to upstream", recs, mms, ambig)
		})
	}
}

// Independent reference: on clean DNA, the scanner's stream with consecutive repeats
// removed equals the per-k-mer minimizer (brute force) with consecutive repeats removed.
func TestBruteForceCleanDNA(t *testing.T) {
	r := rand.New(rand.NewPCG(1, 2))
	for _, c := range []struct {
		k, l     int
		ssm, tm  uint64
		revcom   int
	}{
		{35, 31, viralSSM, mmscan.DefaultToggleMask, 1},
		{35, 31, viralSSM, mmscan.DefaultToggleMask, 0},
		{12, 7, 0, 0, 1},
		{21, 21, 0, mmscan.DefaultToggleMask, 1},
		{40, 15, 0, mmscan.DefaultToggleMask, 1},
	} {
		s, err := mmscan.New(c.k, c.l, c.ssm, c.tm, true, c.revcom)
		if err != nil {
			t.Fatal(err)
		}
		for trial := 0; trial < 200; trial++ {
			seq := make([]byte, c.k+r.IntN(300))
			for i := range seq {
				seq[i] = "ACGTacgt"[r.IntN(8)]
			}
			want := dedup(bruteForce(seq, c.k, c.l, c.ssm, c.tm, c.revcom))
			var got []uint64
			s.Load(seq)
			for {
				mm, amb, ok := s.Next()
				if !ok {
					break
				}
				if amb {
					t.Fatalf("ambiguous minimizer on clean sequence %s", seq)
				}
				got = append(got, mm)
			}
			got = dedup(got)
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Fatalf("k=%d l=%d revcom=%d seq %s\n got %x\nwant %x", c.k, c.l, c.revcom, seq, got, want)
			}
		}
	}
}

func bruteForce(seq []byte, k, l int, ssm, tm uint64, revcom int) []uint64 {
	code := func(b byte) uint64 { return map[byte]uint64{'A': 0, 'C': 1, 'G': 2, 'T': 3}[b&^0x20] }
	mask := uint64(1)<<(2*l) - 1
	tm &= mask
	lmerVal := func(p int) uint64 {
		var v, rc uint64
		for i := 0; i < l; i++ {
			v = v<<2 | code(seq[p+i])
		}
		if revcom == 0 {
			// pre-2.0.8: complement of the full 64-bit reversal, keeping the low 2l bits.
			var rev uint64
			x := v
			for i := 0; i < 32; i++ {
				rev = rev<<2 | x&3
				x >>= 2
			}
			rc = ^rev & mask
		} else {
			for i := l - 1; i >= 0; i-- {
				rc = rc<<2 | (3 - code(seq[p+i]))
			}
		}
		if rc < v {
			v = rc
		}
		if ssm != 0 {
			v &= ssm
		}
		return v
	}
	var out []uint64
	for p := 0; p+k <= len(seq); p++ {
		best := ^uint64(0)
		var bestV uint64
		for q := p; q+l <= p+k; q++ {
			v := lmerVal(q)
			if v^tm < best {
				best, bestV = v^tm, v
			}
		}
		out = append(out, bestV)
	}
	return out
}

func dedup(v []uint64) []uint64 {
	var out []uint64
	for i, x := range v {
		if i == 0 || x != v[i-1] {
			out = append(out, x)
		}
	}
	return out
}

func TestNewLimits(t *testing.T) {
	if _, err := mmscan.New(35, 32, 0, 0, true, 1); err == nil {
		t.Error("l=32 accepted for DNA")
	}
	if _, err := mmscan.New(35, 31, 0, 0, true, 1); err != nil {
		t.Error(err)
	}
	if _, err := mmscan.New(20, 16, 0, 0, false, 1); err == nil {
		t.Error("l=16 accepted for protein")
	}
	if _, err := mmscan.New(10, 11, 0, 0, true, 1); err == nil {
		t.Error("k<l accepted")
	}
}

func TestEmptyAndShort(t *testing.T) {
	s, _ := mmscan.New(35, 31, viralSSM, mmscan.DefaultToggleMask, true, 1)
	for _, seq := range []string{"", "A", "ACGTACGTACGTACGTACGTACGTACGTACG"} {
		s.Load([]byte(seq))
		n := 0
		for {
			if _, _, ok := s.Next(); !ok {
				break
			}
			n++
		}
		if n != 0 {
			t.Errorf("%q: %d minimizers, want 0", seq, n)
		}
	}
}

func TestZeroAllocs(t *testing.T) {
	s, _ := mmscan.New(35, 31, viralSSM, mmscan.DefaultToggleMask, true, 1)
	seq := randomRead(rand.New(rand.NewPCG(3, 4)), 150)
	allocs := testing.AllocsPerRun(100, func() {
		s.Load(seq)
		for {
			if _, _, ok := s.Next(); !ok {
				break
			}
		}
	})
	if allocs != 0 {
		t.Fatalf("%v allocations per scan, want 0", allocs)
	}
}

func randomRead(r *rand.Rand, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = "ACGT"[r.IntN(4)]
		if r.IntN(500) == 0 {
			b[i] = 'N'
		}
	}
	return b
}

// BenchmarkScan100bp scans synthetic 100 bp reads with the Viral DB's options and reports
// ns per minimizer.
func BenchmarkScan100bp(b *testing.B) {
	r := rand.New(rand.NewPCG(7, 8))
	reads := make([][]byte, 1024)
	for i := range reads {
		reads[i] = randomRead(r, 100)
	}
	s, _ := mmscan.New(35, 31, viralSSM, mmscan.DefaultToggleMask, true, 1)
	b.ReportAllocs()
	b.SetBytes(100)
	var n int64
	var sink uint64
	for i := 0; b.Loop(); i++ {
		s.Load(reads[i&1023])
		for {
			mm, _, ok := s.Next()
			if !ok {
				break
			}
			sink ^= mm
			n++
		}
	}
	b.ReportMetric(float64(b.Elapsed().Nanoseconds())/float64(n), "ns/minimizer")
	_ = sink
}

// Documents upstream's ambiguity off-by-one (see the package comment), which the golden
// and real-read streams confirm: of the k k-mers covering an N, only k-1 are flagged.
func TestAmbiguityOffByOne(t *testing.T) {
	s, _ := mmscan.New(35, 31, viralSSM, mmscan.DefaultToggleMask, true, 1)
	r := rand.New(rand.NewPCG(9, 9))
	for _, p := range []int{0, 50} {
		seq := make([]byte, 100)
		for i := range seq {
			seq[i] = "ACGT"[r.IntN(4)]
		}
		seq[p] = 'N'
		s.Load(seq)
		n, amb := 0, 0
		for {
			_, a, ok := s.Next()
			if !ok {
				break
			}
			n++
			if a {
				amb++
			}
		}
		want := 34 // k-mers starting at p-34 .. p-1
		if p == 0 {
			want = 0
		}
		if n != 66 || amb != want {
			t.Errorf("N at %d: %d minimizers, %d ambiguous; want 66, %d", p, n, amb, want)
		}
	}
}
