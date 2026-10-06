package report

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
	"github.com/scttfrdmn/aws-kraken2/internal/taxo"
)

// The report oracle is upstream itself: run the pinned kraken2 with --output and --report,
// rebuild classify's per-taxon call counters from the --output file, and byte-compare our
// report with upstream's.
//
// Rebuilding the counters: column 3 is the call (external taxid) of a classified read; every
// taxid in column 5's hit list was returned by a hash lookup, so upstream created a counter for
// it (see package doc). Mapping both back through the taxonomy gives exactly call_counters.

type oracleCase struct {
	name   string
	paired bool
	args   []string
}

var oracleCases = []oracleCase{
	{"se", false, nil},
	{"se-zero", false, []string{"--report-zero-counts"}},
	{"se-mpa", false, []string{"--use-mpa-style"}},
	{"se-mpa-zero", false, []string{"--use-mpa-style", "--report-zero-counts"}},
	{"pe", true, nil},
	{"pe-zero", true, []string{"--report-zero-counts"}},
	{"pe-mpa", true, []string{"--use-mpa-style"}},
	{"pe-conf0.1", true, []string{"--confidence", "0.1"}},
	{"pe-conf0.1-zero", true, []string{"--confidence", "0.1", "--report-zero-counts"}},
	{"pe-conf0.1-mpa", true, []string{"--confidence", "0.1", "--use-mpa-style"}},
}

const readsPrefix = ".cache/reads/SRR062634_200000_"

// countsFromOutput rebuilds call counters and the stats from a kraken2 --output file.
func countsFromOutput(t *testing.T, tax *taxo.Taxonomy, path string) (calls map[uint64]uint64, total, unclassified uint64) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	intern := func(field string) uint64 {
		ext, err := strconv.ParseUint(field, 10, 64)
		if err != nil {
			t.Fatalf("bad taxid %q in %s", field, path)
		}
		id := tax.InternalID(ext)
		if id == 0 && ext != 0 {
			t.Fatalf("taxid %d not in taxonomy", ext)
		}
		return id
	}
	calls = map[uint64]uint64{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<30)
	for sc.Scan() {
		line := sc.Text()
		cols := strings.Split(line, "\t")
		if len(cols) < 5 {
			t.Fatalf("short output line %q", line)
		}
		n := len(cols)
		state, call, hits := cols[0], cols[n-3], cols[n-1]
		total++
		for _, tok := range strings.Fields(hits) {
			if tok == "|:|" || tok == "-:-" || strings.HasPrefix(tok, "A:") {
				continue
			}
			tok = strings.TrimPrefix(tok, "*")
			ext, _, ok := strings.Cut(tok, ":")
			if !ok {
				t.Fatalf("bad hit token %q", tok)
			}
			if id := intern(ext); id != 0 {
				calls[id] += 0 // present, even if no read is assigned here
			}
		}
		switch state {
		case "C":
			calls[intern(call)]++
		case "U":
			unclassified++
		default:
			t.Fatalf("bad classification %q", state)
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return calls, total, unclassified
}

func TestOracleReport(t *testing.T) {
	kraken2 := oracletest.Upstream(t, "kraken2")
	r1 := oracletest.Need(t, readsPrefix+"1.fq")
	r2 := oracletest.Need(t, readsPrefix+"2.fq")
	for _, db := range []string{oracletest.Viral, oracletest.Standard8} {
		t.Run(db, func(t *testing.T) {
			dir := oracletest.DB(t, db)
			if db == oracletest.Standard8 && testing.Short() {
				t.Skip("-short: skipping Standard-8")
			}
			tax, err := taxo.Load(filepath.Join(dir, "taxo.k2d"))
			if err != nil {
				t.Fatal(err)
			}
			tax.BuildExternalMap()
			// Each resolution control must fire in at least one case, or the case set could
			// not tell a port with the wrong tie order or without zero-read counters from a
			// correct one.
			var stableDetected, zeroDetected, ran int
			t.Cleanup(func() {
				if t.Failed() || ran != len(oracleCases) {
					return
				}
				if stableDetected == 0 {
					t.Errorf("%s: no case detects a stable-sort port (tie order unresolved)", db)
				}
				if zeroDetected == 0 {
					t.Errorf("%s: no case detects dropped zero-read counters", db)
				}
			})
			for _, c := range oracleCases {
				t.Run(c.name, func(t *testing.T) {
					tmp := t.TempDir()
					out, rep := filepath.Join(tmp, "out"), filepath.Join(tmp, "report")
					args := []string{"--db", dir, "--threads", "4", "--output", out, "--report", rep}
					args = append(args, c.args...)
					if c.paired {
						args = append(args, "--paired", r1, r2)
					} else {
						args = append(args, r1)
					}
					cmd := exec.Command(kraken2, args...)
					var stderr bytes.Buffer
					cmd.Stderr = &stderr
					if err := cmd.Run(); err != nil {
						t.Fatalf("upstream kraken2: %v\n%s", err, stderr.String())
					}
					want, err := os.ReadFile(rep)
					if err != nil {
						t.Fatal(err)
					}
					calls, total, uncl := countsFromOutput(t, tax, out)
					opt := Options{ZeroCounts: contains(c.args, "--report-zero-counts")}
					render := func(calls map[uint64]uint64) []byte {
						var b bytes.Buffer
						var err error
						if contains(c.args, "--use-mpa-style") {
							err = MpaStyle(&b, tax, calls, opt)
						} else {
							err = KrakenStyle(&b, tax, calls, total, uncl, opt)
						}
						if err != nil {
							t.Fatal(err)
						}
						return b.Bytes()
					}
					if got := render(calls); !bytes.Equal(got, want) {
						t.Fatalf("report differs from upstream: %s", firstDiff(got, want))
					}
					// Resolution checks (Law 4): could this comparison see the two subtle
					// inputs, the tie order of siblings and the zero-read counters? true = a
					// port getting that wrong would fail this case.
					sortChildren = func(a []uint64, less func(x, y uint64) bool) {
						sort.SliceStable(a, func(i, j int) bool { return less(a[i], a[j]) })
					}
					stable := render(calls)
					sortChildren = stdSort
					nz := map[uint64]uint64{}
					for id, n := range calls {
						if n != 0 {
							nz[id] = n
						}
					}
					sd, zd := !bytes.Equal(stable, want), !bytes.Equal(render(nz), want)
					ran++
					if sd {
						stableDetected++
					}
					if zd {
						zeroDetected++
					}
					t.Logf("%s/%s: controls: stable-sort detected=%v drop-zero-counters detected=%v",
						db, c.name, sd, zd)
					t.Logf("%s/%s: %d seqs, %d unclassified, %d taxa in counters, report %d lines / %d bytes identical",
						db, c.name, total, uncl, len(calls), bytes.Count(want, []byte("\n")), len(want))
				})
			}
		})
	}
}

func contains(s []string, x string) bool {
	for _, v := range s {
		if v == x {
			return true
		}
	}
	return false
}

func firstDiff(got, want []byte) string {
	g, w := bytes.Split(got, []byte("\n")), bytes.Split(want, []byte("\n"))
	for i := 0; i < len(g) && i < len(w); i++ {
		if !bytes.Equal(g[i], w[i]) {
			return fmt.Sprintf("line %d\n go:       %q\n upstream: %q", i+1, g[i], w[i])
		}
	}
	return fmt.Sprintf("go %d lines, upstream %d lines", len(g), len(w))
}
