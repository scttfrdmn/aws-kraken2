package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestGetOptions(t *testing.T) {
	var db, threads, conf string
	var quick, paired bool
	specs := []optSpec{
		{"db", optString, func(v string) { db = v }},
		{"threads", optInt, func(v string) { threads = v }},
		{"confidence", optFloat, func(v string) { conf = v }},
		{"quick", optFlag, func(string) { quick = true }},
		{"paired", optFlag, func(string) { paired = true }},
		{"report", optString, func(string) {}},
		{"report-zero-counts", optFlag, func(string) {}},
	}
	var warn bytes.Buffer
	rest := getOptions([]string{
		"a.fq", "--DB", "-x", "-thr=4", "--conf", ".5", "--quick=1", "--pa", "--rep", "r",
		"--bogus", "--threads", "x", "-", "--", "--quick",
	}, specs, &warn)
	if want := []string{"a.fq", "r", "-", "--quick"}; !reflect.DeepEqual(rest, want) {
		t.Errorf("rest = %q, want %q", rest, want)
	}
	if db != "-x" || threads != "4" || conf != ".5" || quick || !paired {
		t.Errorf("db=%q threads=%q conf=%q quick=%v paired=%v", db, threads, conf, quick, paired)
	}
	wantWarn := "Option quick does not take an argument\n" +
		"Option rep is ambiguous (report, report-zero-counts)\n" +
		"Unknown option: bogus\n" +
		"Value \"x\" invalid for option threads (number expected)\n"
	if warn.String() != wantWarn {
		t.Errorf("warnings:\n%s\nwant:\n%s", warn.String(), wantWarn)
	}
}

func TestCAtoi(t *testing.T) {
	for in, want := range map[string]int64{"8": 8, "+3": 3, "-2": -2, " 7x": 7, "x": 0, "": 0} {
		if got := cAtoi(in); got != want {
			t.Errorf("cAtoi(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestFindDB(t *testing.T) {
	dir := t.TempDir()
	db := filepath.Join(dir, "mydb")
	if err := os.Mkdir(db, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"taxo.k2d", "hash.k2d"} {
		if err := os.WriteFile(filepath.Join(db, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("KRAKEN2_DB_PATH", "/nonexistent:"+dir)
	name := "mydb"
	if _, err := findDB(&name); err == nil || err.status != exitDieErrno ||
		err.msg != `database ("`+db+`") does not contain necessary file opts.k2d`+"\n" {
		t.Fatalf("missing opts.k2d: %+v", err)
	}
	if err := os.WriteFile(filepath.Join(db, "opts.k2d"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got, err := findDB(&name); err != nil || got != db {
		t.Fatalf("findDB = %q, %+v", got, err)
	}
	other := "nope"
	if _, err := findDB(&other); err == nil || err.msg != `unable to find nope in $KRAKEN2_DB_PATH ("/nonexistent:`+dir+`")`+"\n" {
		t.Fatalf("unknown db: %+v", err)
	}
}
