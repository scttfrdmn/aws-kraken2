package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"

	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
	"github.com/scttfrdmn/aws-kraken2/internal/mmscan/mmdump"
)

func init() {
	commands["equiv-scan"] = command{
		summary: "compare internal/mmscan with upstream's MinimizerScanner (upstream/mm_dump output)",
		run:     equivScan,
	}
}

// equivScan runs the upstream/mm_dump harness over FILE... and rescans every record with
// internal/mmscan, stopping at the first difference. It also checks that the harness's
// view of opts.k2d matches the Go reader's, and that the Go-side FASTA/FASTQ reader sees
// the same identifiers and bases as upstream's FastReader.
func equivScan(args []string) error {
	fs := flag.NewFlagSet("equiv-scan", flag.ExitOnError)
	harness := fs.String("harness", "", "path to the built mm_dump harness (scripts/harness-build.sh mm_dump; required)")
	ok := fs.Int("k", -1, "override k (synthetic probes only)")
	ol := fs.Int("l", -1, "override l")
	os_ := fs.String("s", "", "override spaced_seed_mask")
	ot := fs.String("t", "", "override toggle_mask")
	orv := fs.Int("R", -1, "override revcom_version")
	prot := fs.Bool("P", false, "scan as protein (dna_db=false)")
	ranges := fs.Bool("r", false, "also compare LoadSequence(seq, start, finish) sub-intervals")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: k2probe equiv-scan [flags] opts.k2d FILE...")
		fs.PrintDefaults()
	}
	fs.Parse(args)
	if fs.NArg() < 2 || *harness == "" {
		fs.Usage()
		os.Exit(2)
	}
	optsPath, files := fs.Arg(0), fs.Args()[1:]

	want, err := readOptions(optsPath)
	if err != nil {
		return err
	}
	hargs := []string{}
	if *ok >= 0 {
		want.K = uint64(*ok)
		hargs = append(hargs, "-k", strconv.Itoa(*ok))
	}
	if *ol >= 0 {
		want.L = uint64(*ol)
		hargs = append(hargs, "-l", strconv.Itoa(*ol))
	}
	if *os_ != "" {
		if want.SpacedSeedMask, err = strconv.ParseUint(*os_, 0, 64); err != nil {
			return err
		}
		hargs = append(hargs, "-s", *os_)
	}
	if *ot != "" {
		if want.ToggleMask, err = strconv.ParseUint(*ot, 0, 64); err != nil {
			return err
		}
		hargs = append(hargs, "-t", *ot)
	}
	if *orv >= 0 {
		want.RevcomVersion = int32(*orv)
		hargs = append(hargs, "-R", strconv.Itoa(*orv))
	}
	if *prot {
		want.DNADB = false
		hargs = append(hargs, "-P")
	}
	if *ranges {
		hargs = append(hargs, "-r")
	}
	hargs = append(hargs, optsPath)
	hargs = append(hargs, files...)

	cmd := exec.Command(*harness, hargs...)
	cmd.Stderr = os.Stderr
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	cmpErr := compareStream(out, want, files, *ranges)
	if cmpErr != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return cmpErr
	}
	return cmd.Wait()
}

// readOptions reads opts.k2d through internal/kdb.
func readOptions(path string) (kdb.Options, error) {
	f, err := os.Open(path)
	if err != nil {
		return kdb.Options{}, err
	}
	defer f.Close()
	return kdb.ReadOptions(f)
}

// sameOptions compares the fields the harness reports with the Go reader's (kdb.Options also
// holds slices, so it is not comparable with ==).
func sameOptions(h mmdump.Header, o kdb.Options) bool {
	return h.K == o.K && h.L == o.L && h.SpacedSeedMask == o.SpacedSeedMask &&
		h.ToggleMask == o.ToggleMask && h.DNA == o.DNADB &&
		h.MinimumAcceptableHashValue == o.MinimumAcceptableHashValue &&
		h.RevcomVersion == o.RevcomVersion && h.DBVersion == o.DBVersion && h.DBType == o.DBType &&
		int(h.OptsFileSize) == o.FileSize
}

func compareStream(out io.Reader, want kdb.Options, files []string, ranges bool) error {
	d, err := mmdump.NewReader(out)
	if err != nil {
		return err
	}
	h := d.Header
	if !sameOptions(h, want) {
		return fmt.Errorf("opts mismatch: upstream %+v, Go %+v", h, want)
	}
	fmt.Printf("opts k=%d l=%d spaced_seed_mask=%#016x toggle_mask=%#016x dna_db=%v "+
		"minimum_acceptable_hash_value=%#x revcom_version=%d db_version=%d db_type=%d opts_filesize=%d\n",
		h.K, h.L, h.SpacedSeedMask, h.ToggleMask, h.DNA, h.MinimumAcceptableHashValue,
		h.RevcomVersion, h.DBVersion, h.DBType, h.OptsFileSize)

	s, err := h.NewScanner()
	if err != nil {
		return err
	}
	type tally struct {
		reads, scans, minimizers, ambigMinimizers, readsWithAmbigMinimizer int64
		readsWithNonACGT, nonACGTBases, rangeScans, rangeMinimizers        int64
	}
	per := make([]tally, len(files))
	var fx *fastxReader
	var fxFile *os.File
	defer func() {
		if fxFile != nil {
			fxFile.Close()
		}
	}()
	curFile := -1
	full := true // in range mode records alternate full, range
	for {
		rec, err := d.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		fi := int(rec.FileIdx)
		if fi >= len(files) || fi < curFile {
			return fmt.Errorf("record file index %d out of order", fi)
		}
		if full {
			for curFile < fi {
				if fx != nil {
					if more, err := fx.next(); err != nil || more {
						return fmt.Errorf("%s: Go reader has records upstream did not report (err %v)", files[curFile], err)
					}
				}
				curFile++
				if fxFile != nil {
					fxFile.Close()
				}
				if fxFile, err = os.Open(files[curFile]); err != nil {
					return err
				}
				fx = newFastxReader(fxFile)
			}
			more, err := fx.next()
			if err != nil {
				return fmt.Errorf("%s: %v", files[fi], err)
			}
			if !more || !bytes.Equal(fx.id, rec.Header) || !bytes.Equal(fx.seq, rec.Seq) {
				return fmt.Errorf("%s record %d (%s): Go reader disagrees with upstream FastReader (Go id %q, %d bases)",
					files[fi], per[fi].reads, rec.Header, fx.id, len(fx.seq))
			}
		}
		t := &per[fi]
		if m := mmdump.Check(s, rec); m != nil {
			return fmt.Errorf("MISMATCH %s read #%d id %s len %d start %d finish %d: %s\nseq %s",
				files[fi], t.reads-btoi(!full), rec.Header, len(rec.Seq), rec.Start, int64(rec.Finish), m, rec.Seq)
		}
		t.scans++
		if full {
			t.reads++
			t.minimizers += int64(len(rec.Minimizers))
			anyAmbig := false
			for _, a := range rec.Ambiguous {
				if a {
					t.ambigMinimizers++
					anyAmbig = true
				}
			}
			if anyAmbig {
				t.readsWithAmbigMinimizer++
			}
			n := 0
			for _, c := range rec.Seq {
				switch c {
				case 'A', 'C', 'G', 'T', 'a', 'c', 'g', 't':
				default:
					n++
				}
			}
			if n > 0 {
				t.readsWithNonACGT++
				t.nonACGTBases += int64(n)
			}
		} else {
			t.rangeScans++
			t.rangeMinimizers += int64(len(rec.Minimizers))
		}
		if ranges {
			full = !full
		}
	}
	if fx != nil {
		if more, err := fx.next(); err != nil || more {
			return fmt.Errorf("%s: Go reader has records upstream did not report (err %v)", files[curFile], err)
		}
	}
	var tot tally
	for i, t := range per {
		fmt.Printf("file %s reads=%d minimizers=%d ambiguous_minimizers=%d reads_with_ambiguous_minimizer=%d "+
			"reads_with_non_ACGT=%d non_ACGT_bases=%d range_scans=%d range_minimizers=%d\n",
			files[i], t.reads, t.minimizers, t.ambigMinimizers, t.readsWithAmbigMinimizer,
			t.readsWithNonACGT, t.nonACGTBases, t.rangeScans, t.rangeMinimizers)
		tot.reads += t.reads
		tot.scans += t.scans
		tot.minimizers += t.minimizers
		tot.ambigMinimizers += t.ambigMinimizers
		tot.readsWithAmbigMinimizer += t.readsWithAmbigMinimizer
		tot.readsWithNonACGT += t.readsWithNonACGT
		tot.nonACGTBases += t.nonACGTBases
		tot.rangeScans += t.rangeScans
		tot.rangeMinimizers += t.rangeMinimizers
	}
	if uint64(tot.scans) != d.Records || uint64(tot.minimizers+tot.rangeMinimizers) != d.Minimizers {
		return fmt.Errorf("totals disagree with harness end marker: scans %d/%d minimizers %d/%d",
			tot.scans, d.Records, tot.minimizers+tot.rangeMinimizers, d.Minimizers)
	}
	fmt.Printf("MATCH reads=%d minimizers=%d ambiguous_minimizers=%d reads_with_ambiguous_minimizer=%d "+
		"reads_with_non_ACGT=%d non_ACGT_bases=%d range_scans=%d range_minimizers=%d\n",
		tot.reads, tot.minimizers, tot.ambigMinimizers, tot.readsWithAmbigMinimizer,
		tot.readsWithNonACGT, tot.nonACGTBases, tot.rangeScans, tot.rangeMinimizers)
	return nil
}

func btoi(b bool) int64 {
	if b {
		return 1
	}
	return 0
}
