package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

// TestCohortCheck: AK2_COHORT_CHECK validates a manifest without loading anything. A manifest in
// E1's c10 form (every sample in several batches, named <batch>-<sample>) checks; the same with
// the sample's own name repeated across batches is refused (the E1 run 20261008-005107 failed
// on that after its first three invocations).
func TestCohortCheck(t *testing.T) {
	db := oracletest.DB(t, "k2_viral_20260626")
	r1, r2 := oracletest.Reads(t, "SRR062634_200000_1.fq"), oracletest.Reads(t, "SRR062634_200000_2.fq")
	dir := t.TempDir()
	write := func(tag string, name func(b int) string) string {
		var m strings.Builder
		for b := 0; b < 3; b++ {
			bs := strconv.Itoa(b)
			m.WriteString(strings.Join([]string{bs, "2", "parallel", "sdk", name(b), "--threads", "8",
				"--output", "s3://bkt/c10/" + bs + "/output", "--report", "s3://bkt/c10/" + bs + "/report", r1, r2}, "\t") + "\n")
		}
		p := filepath.Join(dir, tag+".tsv")
		if err := os.WriteFile(p, []byte(m.String()), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	env := func(m string) func(string) (string, bool) {
		e := map[string]string{"AK2_ENGINE_N": "8", "AK2_COHORT": m, "AK2_COHORT_CHECK": "1"}
		return func(k string) (string, bool) { v, ok := e[k]; return v, ok }
	}
	common := []string{"--db", db, "--threads", "16", "--paired"}
	good := write("good", func(b int) string { return strconv.Itoa(b) + "-SRR062634" })
	if st := runCohort(good, common, env(good)); st != 0 {
		t.Fatalf("E1-form manifest: exit %d", st)
	}
	bad := write("bad", func(int) string { return "SRR062634" })
	if st := runCohort(bad, common, env(bad)); st == 0 {
		t.Fatal("a sample name repeated across batches was accepted")
	}
}
