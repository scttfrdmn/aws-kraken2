package main

import (
	"bytes"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/objstore"
	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

// cohortSample is one sample of the cohort tests: its options and inputs, and which of its
// outputs it asks for.
type cohortSample struct {
	name   string
	opts   []string
	inputs []string
	paired bool
	seqout bool
}

func cohortSamples(t *testing.T) []cohortSample {
	r := func(n string) string { return oracletest.Reads(t, n) }
	return []cohortSample{
		{"s1-pe", []string{"--paired"}, []string{r("SRR062634_200000_1.fq"), r("SRR062634_200000_2.fq")}, true, true},
		{"s2-se-conf", []string{"--confidence", "0.1"}, []string{r("ERR478965_200000_1.fq")}, false, false},
		{"s3-pe-gz-names", []string{"--paired", "--use-names"}, []string{r("SRR28305653_200000_1.fq.gz"), r("SRR28305653_200000_2.fq.gz")}, true, true},
		{"s2-pe-zero", []string{"--paired", "--report-zero-counts"}, []string{r("ERR478965_200000_1.fq"), r("ERR478965_200000_2.fq")}, true, false},
		{"s1-se-quick-mpa", []string{"--quick", "--use-mpa-style"}, []string{r("SRR062634_200000_1.fq")}, false, false},
	}
}

// outArgs is a sample's output arguments under base (a directory or s3:// prefix).
func (s cohortSample) outArgs(base string) []string {
	a := []string{"--output", base + "/output", "--report", base + "/report"}
	if s.seqout {
		if s.paired {
			a = append(a, "--classified-out", base+"/cls#.fq", "--unclassified-out", base+"/uncls#.fq")
		} else {
			a = append(a, "--classified-out", base+"/cls.fq", "--unclassified-out", base+"/uncls.fq")
		}
	}
	return a
}

func (s cohortSample) files() []string {
	f := []string{"output", "report"}
	if s.seqout {
		if s.paired {
			f = append(f, "cls_1.fq", "cls_2.fq", "uncls_1.fq", "uncls_2.fq")
		} else {
			f = append(f, "cls.fq", "uncls.fq")
		}
	}
	return f
}

// TestCohortInProcess: a cohort run by 3 nodes in one process (loopback TCP, a directory
// rendezvous). Batch 0 is sample-parallel with 2 samples in flight per node and local outputs,
// batch 1 is block-striped, batch 2 is sample-parallel with s3:// outputs through the SDK path
// (aws-sdk-go-v2 against a fake S3 server). Every sample's every output is compared with the
// plain path's run of the same arguments. CI runs it under -race.
func TestCohortInProcess(t *testing.T) {
	db := oracletest.DB(t, "k2_viral_20260626")
	samples := cohortSamples(t)
	dir := t.TempDir()
	fake := &objstore.FakeS3{Dir: &objstore.Dir{Root: filepath.Join(dir, "s3")}}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	t.Setenv("AK2_S3_EMULATE", "")
	t.Setenv("AK2_S3_ENDPOINT", srv.URL)
	t.Setenv("AK2_ALLOWED_BUCKETS", "bkt")
	none := func(string) (string, bool) { return "", false }
	common := []string{"--db", db, "--threads", "2"}
	// The reference: each sample alone, through the plain path.
	for _, s := range samples {
		base := filepath.Join(dir, "plain", s.name)
		os.MkdirAll(base, 0o755)
		argv := append(append(append(append([]string{}, common...), s.opts...), s.outArgs(base)...), s.inputs...)
		if st := runEnv(argv, none); st != 0 {
			t.Fatalf("plain %s: exit %d", s.name, st)
		}
	}
	// The cohort: batch 0 = samples 0..4 parallel (inflight 2), batch 1 = samples 0, 2 striped,
	// batch 2 = samples 1, 3 parallel with s3:// outputs (sdk).
	var m strings.Builder
	where := map[string]string{} // cohort sample name -> its outputs' base
	line := func(batch, inflight int, mode, client, name string, s cohortSample, base string) {
		os.MkdirAll(base, 0o755)
		where[name] = base
		fields := []string{strconv.Itoa(batch), strconv.Itoa(inflight), mode, client, name}
		fields = append(append(append(fields, s.opts...), s.outArgs(base)...), s.inputs...)
		m.WriteString(strings.Join(fields, "\t") + "\n")
	}
	for _, s := range samples {
		line(0, 2, "parallel", "-", "b0-"+s.name, s, filepath.Join(dir, "cohort", "b0-"+s.name))
	}
	for _, i := range []int{0, 2} {
		line(1, 1, "striped", "-", "b1-"+samples[i].name, samples[i], filepath.Join(dir, "cohort", "b1-"+samples[i].name))
	}
	for _, i := range []int{1, 3} {
		name := "b2-" + samples[i].name
		line(2, 1, "parallel", "sdk", name, samples[i], "s3://bkt/cohort/"+name)
		where[name] = filepath.Join(dir, "s3", "bkt", "cohort", name)
	}
	manifest := filepath.Join(dir, "cohort.tsv")
	if err := os.WriteFile(manifest, []byte(m.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	const n = 3
	rv := filepath.Join(dir, "rv")
	var wg sync.WaitGroup
	status := make([]int, n)
	for rank := 0; rank < n; rank++ {
		env := map[string]string{"AK2_ENGINE_N": "3", "AK2_ENGINE_RANK": strconv.Itoa(rank), "AK2_COHORT": manifest,
			"AK2_ENGINE_RENDEZVOUS": rv, "AK2_ENGINE_TIMEOUT": "2m", "AK2_ENGINE_WINDOW": "2"}
		lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
		wg.Add(1)
		go func() {
			defer wg.Done()
			status[rank] = runCohort(manifest, common, lookup)
		}()
	}
	wg.Wait()
	for rank, st := range status {
		if st != 0 {
			t.Fatalf("rank %d: exit %d", rank, st)
		}
	}
	checked := 0
	for name, base := range where {
		i := strings.Index(name, "-")
		sname := name[i+1:]
		var s cohortSample
		for _, x := range samples {
			if x.name == sname {
				s = x
			}
		}
		for _, f := range s.files() {
			want, err := os.ReadFile(filepath.Join(dir, "plain", s.name, f))
			if err != nil {
				t.Fatal(err)
			}
			got, err := os.ReadFile(filepath.Join(base, f))
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			if !bytes.Equal(got, want) {
				t.Errorf("%s %s differs from the plain run", name, f)
			}
			checked++
		}
		// No other file: the file sets match.
		es, _ := os.ReadDir(base)
		if len(es) != len(s.files()) {
			t.Errorf("%s: %d files, want %d", name, len(es), len(s.files()))
		}
	}
	if checked < 25 || fake.Parts.Load() == 0 {
		t.Fatalf("checked %d files, %d parts through the SDK", checked, fake.Parts.Load())
	}
	if p := fake.Dir.Pending(); len(p) != 0 {
		t.Fatalf("uploads left open: %v", p)
	}
}
