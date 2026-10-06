// Ported from DerrickWood/kraken2 scripts/kraken2 and scripts/kraken2lib.pm (find_db) at
// 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Command aws-kraken2 classifies reads like upstream kraken2 at the pin, byte-identically: for
// the same database, options and input, --output, --report and the classified/unclassified
// files are the same bytes (CLAUDE.md, Law 1; checked by make oracle, docs/oracle.md).
//
// Its command line is upstream's kraken2 wrapper's: the same option names, defaults (including
// --minimum-hit-groups 2 and KRAKEN2_NUM_THREADS), validation, messages and exit statuses,
// database lookup (--db, KRAKEN2_DEFAULT_DB, KRAKEN2_DB_PATH) and compression detection. Where
// the wrapper hands over to upstream's classify binary, this program carries on in-process with
// the same checks classify makes. Not supported: --report-minimizer-data (issue #18) and
// translated-search (protein) databases; both are refused with an error.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// upstreamVersion is the kraken2 version string at the pin (upstream's VERSION file is
// substituted into the wrapper at install).
const upstreamVersion = "2.17.1"

// Exit statuses. Perl's die exits with errno if set (the database checks leave ENOENT), else
// 255; classify uses sysexits.h.
const (
	exitDie      = 255
	exitDieErrno = 2
	exitFailure  = 1
	exUsage      = 64
	exDataErr    = 65
	exNoInput    = 66
	exIOErr      = 74
)

// upstreamPin is set from scripts/pin.env at build time (Makefile -ldflags -X).
var upstreamPin = "unknown"

var perlNumPrefix = regexp.MustCompile(`^[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?`)

var prog = filepath.Base(os.Args[0])

// options are the wrapper's variables after GetOptions, with its defaults.
type options struct {
	quick               bool
	db                  *string
	threads             *string
	memoryMapping       bool
	gunzip, bunzip2     bool
	paired              bool
	useNames            bool
	unclassifiedOut     *string
	classifiedOut       *string
	output              *string
	confidence          string // as given; the wrapper passes it on as text (-T)
	minimumBaseQuality  string
	report              *string
	useMpaStyle         bool
	reportZeroCounts    bool
	minimumHitGroups    string
	reportMinimizerData bool
	files               []string
}

func strp(s string) *string { return &s }

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	o := options{confidence: "0.0", minimumBaseQuality: "0", minimumHitGroups: "2"}
	set := func(b *bool) func(string) { return func(string) { *b = true } }
	specs := []optSpec{
		{"help", optFlag, func(string) { usage(0) }},
		{"version", optFlag, func(string) { displayVersion() }},
		{"db", optString, func(v string) { o.db = strp(v) }},
		{"threads", optInt, func(v string) { o.threads = strp(v) }},
		{"quick", optFlag, set(&o.quick)},
		{"unclassified-out", optString, func(v string) { o.unclassifiedOut = strp(v) }},
		{"classified-out", optString, func(v string) { o.classifiedOut = strp(v) }},
		{"output", optString, func(v string) { o.output = strp(v) }},
		{"confidence", optFloat, func(v string) { o.confidence = v }},
		{"memory-mapping", optFlag, set(&o.memoryMapping)},
		{"paired", optFlag, set(&o.paired)},
		{"use-names", optFlag, set(&o.useNames)},
		{"gzip-compressed", optFlag, set(&o.gunzip)},
		{"bzip2-compressed", optFlag, set(&o.bunzip2)},
		{"only-classified-output", optFlag, func(string) {}}, // parsed, then unused upstream
		{"minimum-base-quality", optInt, func(v string) { o.minimumBaseQuality = v }},
		{"report", optString, func(v string) { o.report = strp(v) }},
		{"use-mpa-style", optFlag, set(&o.useMpaStyle)},
		{"report-zero-counts", optFlag, set(&o.reportZeroCounts)},
		{"minimum-hit-groups", optInt, func(v string) { o.minimumHitGroups = v }},
		{"report-minimizer-data", optFlag, set(&o.reportMinimizerData)},
	}
	o.files = getOptions(args, specs, os.Stderr)

	if o.threads == nil {
		t := os.Getenv("KRAKEN2_NUM_THREADS")
		if t == "" || t == "0" { // Perl: $ENV{...} || 1
			t = "1"
		}
		o.threads = &t
	}
	if len(o.files) == 0 {
		fmt.Fprintln(os.Stderr, "Need to specify input filenames!")
		usage(exUsage)
	}
	dbPrefix, err := findDB(o.db)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %s", prog, err.msg)
		return err.status
	}
	for _, f := range []string{"taxo.k2d", "hash.k2d", "opts.k2d"} {
		if _, err := os.Stat(dbPrefix + "/" + f); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %s/%s does not exist!\n", prog, dbPrefix, f)
			return exitDieErrno
		}
	}
	if o.paired && len(o.files)%2 != 0 {
		return die("--paired requires positive and even number filenames")
	}
	if o.gunzip && o.bunzip2 {
		return die("can't use both gzip and bzip2 compression flags")
	}
	conf := perlAtof(o.confidence)
	if conf < 0 {
		return die("confidence threshold must be nonnegative")
	}
	if conf > 1 {
		return die("confidence threshold must be no greater than 1")
	}
	if perlAtoi(o.minimumHitGroups) < 0 {
		return die("minimum number of hit groups must be nonnegative")
	}

	// What follows is classify's own command-line handling (ParseCommandLine) of the flags the
	// wrapper builds, then the run.
	c := classifyArgs{
		hashFile:        dbPrefix + "/hash.k2d",
		taxoFile:        dbPrefix + "/taxo.k2d",
		optsFile:        dbPrefix + "/opts.k2d",
		threads:         int(cAtoi(*o.threads)),
		quick:           o.quick,
		paired:          o.paired,
		useNames:        o.useNames,
		confidence:      conf,
		minQuality:      int(cAtoi(o.minimumBaseQuality)),
		minHitGroups:    int(cAtoi(o.minimumHitGroups)),
		mpa:             o.useMpaStyle,
		zeroCounts:      o.reportZeroCounts,
		memoryMapping:   o.memoryMapping,
		reportKmerData:  o.reportMinimizerData,
		files:           o.files,
		gzipFlag:        o.gunzip,
		bzip2Flag:       o.bunzip2,
		kraken2Output:   o.output,
		classifiedOut:   o.classifiedOut,
		unclassifiedOut: o.unclassifiedOut,
		reportFile:      o.report,
	}
	if c.threads < 1 {
		return classifyErr(exUsage, "number of threads can't be less than 1")
	}
	if c.mpa && (c.reportFile == nil || *c.reportFile == "") {
		fmt.Fprintln(os.Stderr, "classify: -m requires -R be used")
		classifyUsage()
		return exUsage
	}
	if c.reportKmerData {
		fmt.Fprintf(os.Stderr, "%s: --report-minimizer-data is not supported yet (issue #18); "+
			"run upstream kraken2 for minimizer data\n", prog)
		return exUsage
	}
	return classifyRun(&c)
}

type dieErr struct {
	msg    string
	status int
}

func die(msg string) int {
	fmt.Fprintf(os.Stderr, "%s: %s\n", prog, msg)
	return exitDie
}

func classifyErr(status int, format string, a ...any) int {
	fmt.Fprintf(os.Stderr, "classify: "+format+"\n", a...)
	return status
}

// findDB is kraken2lib.pm find_db.
func findDB(supplied *string) (string, *dieErr) {
	if supplied == nil {
		d, ok := os.LookupEnv("KRAKEN2_DEFAULT_DB")
		if !ok {
			return "", &dieErr{"Must specify DB with either --db or $KRAKEN2_DEFAULT_DB\n", exitDie}
		}
		supplied = &d
	}
	dbPath := []string{"."}
	pathStr, havePath := os.LookupEnv("KRAKEN2_DB_PATH")
	if havePath {
		p := pathStr
		if strings.HasPrefix(p, ":") {
			p = "." + p
		}
		if strings.HasSuffix(p, ":") {
			p += "."
		}
		p = strings.Replace(p, "::", ":.:", 1)
		dbPath = perlSplitColon(p)
	}
	var prefix string
	if strings.Contains(*supplied, "/") {
		prefix = *supplied
	} else {
		for _, dir := range dbPath {
			checked := dir + "/" + *supplied
			if fi, err := os.Stat(checked); err == nil && fi.IsDir() {
				prefix = checked
				break
			}
		}
		if prefix == "" {
			printed := "undefined"
			if havePath {
				printed = `"` + pathStr + `"`
			}
			return "", &dieErr{fmt.Sprintf("unable to find %s in $KRAKEN2_DB_PATH (%s)\n", *supplied, printed), exitDieErrno}
		}
	}
	for _, f := range []string{"taxo.k2d", "hash.k2d", "opts.k2d"} {
		if _, err := os.Stat(prefix + "/" + f); err != nil {
			return "", &dieErr{fmt.Sprintf("database (\"%s\") does not contain necessary file %s\n", prefix, f), exitDieErrno}
		}
	}
	return prefix, nil
}

// perlSplitColon is Perl's split /:/, which drops trailing empty fields.
func perlSplitColon(s string) []string {
	f := strings.Split(s, ":")
	for len(f) > 0 && f[len(f)-1] == "" {
		f = f[:len(f)-1]
	}
	return f
}

// perlNum is Perl's numeric value of a string for truthiness (leading number, else 0).
func perlNum(s string) float64 {
	m := perlNumPrefix.FindString(strings.TrimSpace(s))
	if m == "" {
		return 0
	}
	return perlAtof(m)
}

// cAtoi is C atoi: optional whitespace and sign, then digits; anything else stops it.
func cAtoi(s string) int64 {
	s = strings.TrimLeft(s, " \t\n\v\f\r")
	neg := false
	if s != "" && (s[0] == '+' || s[0] == '-') {
		neg = s[0] == '-'
		s = s[1:]
	}
	var n int64
	for i := 0; i < len(s) && s[i] >= '0' && s[i] <= '9'; i++ {
		n = n*10 + int64(s[i]-'0')
		if n > 1<<31 {
			n = 1 << 31
		}
	}
	if neg {
		n = -n
	}
	return int64(int32(n))
}

func usage(exitCode int) {
	defaultDB := "none"
	if d, err := findDB(nil); err == nil {
		defaultDB = `"` + d + `"`
	}
	defThreads := "1"
	if t, ok := os.LookupEnv("KRAKEN2_NUM_THREADS"); ok {
		defThreads = strconv.FormatFloat(perlNum(t), 'g', 15, 64)
	}
	fmt.Fprintf(os.Stderr, `Usage: %s [options] <filename(s)>

Options:
  --db NAME               Name for Kraken 2 DB
                          (default: %s)
  --threads NUM           Number of threads (default: %s)
  --quick                 Quick operation (use first hit or hits)
  --unclassified-out FILENAME
                          Print unclassified sequences to filename
  --classified-out FILENAME
                          Print classified sequences to filename
  --output FILENAME       Print output to filename (default: stdout); "-" will
                          suppress normal output
  --confidence FLOAT      Confidence score threshold (default: 0.0); must be
                          in [0, 1].
  --minimum-base-quality NUM
                          Minimum base quality used in classification (def: 0,
                          only effective with FASTQ input).
  --report FILENAME       Print a report with aggregrate counts/clade to file
  --use-mpa-style         With --report, format report output like Kraken 1's
                          kraken-mpa-report
  --report-zero-counts    With --report, report counts for ALL taxa, even if
                          counts are zero
  --report-minimizer-data With --report, report minimizer and distinct minimizer
                          count information in addition to normal Kraken report
  --memory-mapping        Avoids loading database into RAM
  --paired                The filenames provided have paired-end reads
  --use-names             Print scientific names instead of just taxids
  --gzip-compressed       Input files are compressed with gzip
  --bzip2-compressed      Input files are compressed with bzip2
  --minimum-hit-groups NUM
                          Minimum number of hit groups (overlapping k-mers
                          sharing the same minimizer) needed to make a call
                          (default: 2)
  --help                  Print this message
  --version               Print version information

If none of the *-compressed flags are specified, and the filename provided
is a regular file, automatic format detection is attempted.
`, prog, defaultDB, defThreads)
	os.Exit(exitCode)
}

func displayVersion() {
	fmt.Printf("aws-kraken2: a byte-identical Go port of Kraken version %s (DerrickWood/kraken2 at %s)\n",
		upstreamVersion, upstreamPin)
	fmt.Println("Kraken 2: Copyright 2013-2023, Derrick Wood (dwood@cs.jhu.edu)")
	os.Exit(0)
}

func classifyUsage() {
	fmt.Fprint(os.Stderr, `Usage: classify [options] <fasta/fastq file(s)>

Options: (*mandatory)
* -H filename      Kraken 2 index filename
* -t filename      Kraken 2 taxonomy filename
* -o filename      Kraken 2 options filename
  -q               Quick mode
  -c               Ensure pairs are ordered (stop classification otherwise)  -M               Use memory mapping to access hash & taxonomy
  -T NUM           Confidence score threshold (def. 0)
  -p NUM           Number of threads (def. 1)
  -Q NUM           Minimum quality score (FASTQ only, def. 0)
  -P               Process pairs of reads
  -S               Process pairs with mates in same file
  -R filename      Print report to filename
  -m               In comb. w/ -R, use mpa-style report
  -z               In comb. w/ -R, report taxa w/ 0 count
  -n               Print scientific name instead of taxid in Kraken output
  -g NUM           Minimum number of hit groups needed for call
  -C filename      Filename/format to have classified sequences
  -U filename      Filename/format to have unclassified sequences
  -O filename      Output file for normal Kraken output
  -K               In comb. w/ -R, provide minimizer information in report
  -D               Start a daemon, this options is intended to be used with wrappers
  -d filename      Dump taxon counters to filename.
  -F               Add an asterisks in front of taxids associated with unique minimizers
`)
}
