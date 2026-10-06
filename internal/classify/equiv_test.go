package classify

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// The equivalence test replays upstream's own event streams (upstream/classify_trace.cc)
// through this package and byte-diffs the --output against upstream kraken2's. Its inputs come
// from scripts/classify-oracle.sh; the test skips when they are absent.

func oracleDir(t *testing.T) string {
	d := os.Getenv("K2_CLASSIFY_ORACLE")
	if d == "" {
		d = filepath.Join("..", "..", ".cache", "classify")
	}
	if _, err := os.Stat(filepath.Join(d, "MANIFEST")); err != nil {
		t.Skipf("no classify oracle at %s (run scripts/classify-oracle.sh)", d)
	}
	return d
}

type traceEvent struct {
	min uint64
	amb bool
	val uint32
}

type traceRead struct {
	id         []byte
	len1, len2 uint32
	mates      [2][]traceEvent
}

type traceReader struct {
	r       *bufio.Reader
	minHash uint64
	dna     bool
	paired  bool
	buf     [13]byte
}

func openTrace(path string) (*traceReader, io.Closer, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	tr := &traceReader{r: bufio.NewReaderSize(f, 1<<20)}
	var hdr [18]byte
	if _, err := io.ReadFull(tr.r, hdr[:]); err != nil || string(hdr[:8]) != "K2TRACE1" {
		f.Close()
		return nil, nil, fmt.Errorf("bad trace header in %s", path)
	}
	tr.minHash = binary.LittleEndian.Uint64(hdr[8:])
	tr.dna = hdr[16] != 0
	tr.paired = hdr[17] != 0
	return tr, f, nil
}

func (tr *traceReader) u32() (uint32, error) {
	if _, err := io.ReadFull(tr.r, tr.buf[:4]); err != nil {
		return 0, err
	}
	return binary.LittleEndian.Uint32(tr.buf[:4]), nil
}

// next fills rd, reusing its slices; io.EOF at the end.
func (tr *traceReader) next(rd *traceRead) error {
	n, err := tr.u32()
	if err != nil {
		return err
	}
	rd.id = append(rd.id[:0], make([]byte, n)...)
	if _, err := io.ReadFull(tr.r, rd.id); err != nil {
		return err
	}
	mates := 1
	if tr.paired {
		mates = 2
	}
	for m := 0; m < mates; m++ {
		l, err := tr.u32()
		if err != nil {
			return err
		}
		if m == 0 {
			rd.len1 = l
		} else {
			rd.len2 = l
		}
		cnt, err := tr.u32()
		if err != nil {
			return err
		}
		ev := rd.mates[m][:0]
		for i := uint32(0); i < cnt; i++ {
			if _, err := io.ReadFull(tr.r, tr.buf[:]); err != nil {
				return err
			}
			ev = append(ev, traceEvent{
				min: binary.LittleEndian.Uint64(tr.buf[:8]),
				amb: tr.buf[8] != 0,
				val: binary.LittleEndian.Uint32(tr.buf[9:]),
			})
		}
		rd.mates[m] = ev
	}
	return nil
}

type mapResolver map[uint64]uint32

func (m mapResolver) Get(k uint64) uint32 { return m[k] }

type equivCase struct {
	name string
	opts Options
}

func equivCases() []equivCase {
	d := Options{MinimumHitGroups: 2} // the kraken2 wrapper's defaults
	with := func(f func(*Options)) Options { o := d; f(&o); return o }
	return []equivCase{
		{"default", d},
		{"conf0.1", with(func(o *Options) { o.Confidence = 0.1 })},
		{"conf0.5", with(func(o *Options) { o.Confidence = 0.5 })},
		{"mhg1", with(func(o *Options) { o.MinimumHitGroups = 1 })},
		{"mhg3", with(func(o *Options) { o.MinimumHitGroups = 3 })},
		{"quick", with(func(o *Options) { o.Quick = true })},
		{"quick-mhg1", with(func(o *Options) { o.Quick = true; o.MinimumHitGroups = 1 })},
		{"quick-conf0.5", with(func(o *Options) { o.Quick = true; o.Confidence = 0.5 })},
		{"names", with(func(o *Options) { o.UseNames = true })},
		{"names-conf0.5", with(func(o *Options) { o.UseNames = true; o.Confidence = 0.5 })},
		{"flagunique", with(func(o *Options) { o.FlagUniqueMinimizers = true })},
	}
}

// replayTrace classifies every read of a trace and returns the --output bytes and the worker.
func replayTrace(t *testing.T, tree Tree, path string, opts Options) ([]byte, *Worker, uint64) {
	tr, closer, err := openTrace(path)
	if err != nil {
		t.Fatal(err)
	}
	defer closer.Close()
	opts.Paired = tr.paired
	c, err := New(tree, IndexInfo{DNA: tr.dna, MinimumAcceptableHashValue: tr.minHash}, opts, nil)
	if err != nil {
		t.Fatal(err)
	}
	tok := c.NewTokens()
	res := mapResolver{}
	w := &Worker{}
	var rd traceRead
	var reads uint64
	for {
		err := tr.next(&rd)
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		reads++
		clear(res)
		tok.Reset()
		for m := 0; m < 1+btoi(tr.paired); m++ {
			if m == 1 {
				tok.MateBorder()
			}
			for _, e := range rd.mates[m] {
				tok.Add(e.min, e.amb)
				if !e.amb {
					res[e.min] = e.val
				}
			}
		}
		tok.Resolve(res)
		c.Classify(tok, rd.id, rd.len1, rd.len2, w)
	}
	return w.Out, w, reads
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

// firstDiff describes the first differing line of two outputs.
func firstDiff(got, want []byte) string {
	gl := bytes.SplitAfter(got, []byte("\n"))
	wl := bytes.SplitAfter(want, []byte("\n"))
	diffs, first := 0, -1
	for i := 0; i < len(gl) || i < len(wl); i++ {
		var g, w []byte
		if i < len(gl) {
			g = gl[i]
		}
		if i < len(wl) {
			w = wl[i]
		}
		if !bytes.Equal(g, w) {
			diffs++
			if first < 0 {
				first = i
			}
		}
	}
	if first < 0 {
		return "identical lines"
	}
	var g, w []byte
	if first < len(gl) {
		g = gl[first]
	}
	if first < len(wl) {
		w = wl[first]
	}
	return fmt.Sprintf("%d differing lines; first at line %d:\n got %q\nwant %q", diffs, first+1, g, w)
}

func TestEquivUpstreamOutput(t *testing.T) {
	dir := oracleDir(t)
	tree, err := loadTestTree(filepath.Join(dir, "taxo.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"se", "pe"} {
		for _, ec := range equivCases() {
			t.Run(mode+"/"+ec.name, func(t *testing.T) {
				want, err := os.ReadFile(filepath.Join(dir, mode, ec.name+".out"))
				if err != nil {
					t.Skip(err)
				}
				got, w, reads := replayTrace(t, tree, filepath.Join(dir, mode+".trace"), ec.opts)
				if !bytes.Equal(got, want) {
					t.Fatalf("--output differs from upstream (%d reads): %s", reads, firstDiff(got, want))
				}
				t.Logf("byte-identical: %d reads, %d classified, %d bytes", reads, w.Classified, len(got))
			})
		}
	}
}

// TestEquivUpstreamReportCounts checks the per-taxon call counts against the "reads assigned
// directly" column of upstream's --report for the default options.
func TestEquivUpstreamReportCounts(t *testing.T) {
	dir := oracleDir(t)
	tree, err := loadTestTree(filepath.Join(dir, "taxo.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"se", "pe"} {
		t.Run(mode, func(t *testing.T) {
			rep, err := os.ReadFile(filepath.Join(dir, mode, "default.report"))
			if err != nil {
				t.Skip(err)
			}
			_, w, reads := replayTrace(t, tree, filepath.Join(dir, mode+".trace"),
				Options{MinimumHitGroups: 2, CountTaxa: true})
			want := map[uint64]uint64{}
			for _, line := range strings.Split(strings.TrimRight(string(rep), "\n"), "\n") {
				fs := strings.Split(line, "\t")
				direct, _ := strconv.ParseUint(fs[2], 10, 64)
				ext, _ := strconv.ParseUint(fs[4], 10, 64)
				if direct > 0 && ext != 0 {
					want[ext] = direct
				}
			}
			got := map[uint64]uint64{}
			for id, tc := range w.Counts {
				if tc.Reads > 0 {
					got[tree.ExternalID(id)] = tc.Reads
				}
			}
			if len(got) != len(want) {
				t.Fatalf("called taxa: got %d, upstream report %d", len(got), len(want))
			}
			for ext, n := range want {
				if got[ext] != n {
					t.Errorf("taxid %d: got %d reads, upstream report %d", ext, got[ext], n)
				}
			}
			t.Logf("%d reads, %d classified, %d called taxa, %d taxa with hits; counts match",
				reads, w.Classified, len(got), len(w.Counts))
		})
	}
}
