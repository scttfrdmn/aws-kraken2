// Ported from DerrickWood/kraken2 src/reports.{h,cc} at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package report writes kraken2's --report output: the kraken-style report
// (ReportKrakenStyle) and, with --use-mpa-style, the MetaPhlAn-style one (ReportMpaStyle).
//
// # Inputs
//
// Calls maps an internal taxid to the number of reads classified directly to it, i.e.
// upstream's call_counters / taxon_counters_t. Key presence matters, not just the value:
// upstream's classifier creates a (zero-read) counter for every taxon any read's minimizer hit,
// and KrakenReportDFS orders siblings with a comparator that puts present taxa before absent
// ones. Because std::sort is unstable, that changes the order of tied siblings. A caller
// matching upstream must therefore insert calls[t] (value 0 if no read lands there) for every
// taxon t returned by a hash lookup, whether or not the read is classified.
//
// # Extension point
//
// --report-minimizer-data (issue #18) adds two columns, clade k-mer count and distinct k-mer
// estimate, after the taxon read count. That will be a new Options field carrying per-taxon
// k-mer counters; leaving it unset keeps today's output, so existing callers stay
// byte-identical.
package report

import (
	"bufio"
	"io"
	"math"
	"runtime"
	"strconv"
	"strings"

	"github.com/scttfrdmn/aws-kraken2/internal/taxo"
)

// Options mirror classify's report flags.
type Options struct {
	ZeroCounts bool // --report-zero-counts
}

// cladeCounts is upstream's GetCladeCounters/GetCladeCounts: each call count is added to the
// taxon and all its ancestors, so every ancestor of a present taxon is present.
func cladeCounts(tax *taxo.Taxonomy, calls map[uint64]uint64) map[uint64]uint64 {
	clade := make(map[uint64]uint64, 2*len(calls))
	for id, n := range calls {
		for id != 0 {
			clade[id] += n
			id = tax.Nodes[id].ParentID
		}
	}
	return clade
}

// KrakenStyle writes the kraken-style report (upstream's ReportKrakenStyle without
// report_kmer_data). totalSeqs and totalUnclassified are classify's stats.total_sequences and
// total_sequences - total_classified.
func KrakenStyle(w io.Writer, tax *taxo.Taxonomy, calls map[uint64]uint64, totalSeqs, totalUnclassified uint64, opt Options) error {
	r := &kraken{
		w:     bufio.NewWriter(w),
		tax:   tax,
		calls: calls,
		clade: cladeCounts(tax, calls),
		total: totalSeqs,
		zeros: opt.ZeroCounts,
	}
	// Special handling of the unclassified sequences.
	if totalUnclassified != 0 || opt.ZeroCounts {
		r.line(totalUnclassified, totalUnclassified, "U", 0, "unclassified", 0)
	}
	// DFS through the taxonomy, printing nodes as encountered.
	if len(tax.Nodes) > 1 {
		r.dfs(1, 'R', -1, 0)
	}
	return r.w.Flush()
}

type kraken struct {
	w     *bufio.Writer
	tax   *taxo.Taxonomy
	calls map[uint64]uint64
	clade map[uint64]uint64
	total uint64
	zeros bool
	buf   []byte
}

// sortChildren orders siblings; a variable only so the oracle test can show that a different
// tie order is detected.
var sortChildren = stdSort

// rankCode is the kraken-style code for the standard ranks, 0 for any other rank.
func rankCode(rank string) byte {
	switch rank {
	case "superkingdom", "domain":
		return 'D'
	case "kingdom":
		return 'K'
	case "phylum":
		return 'P'
	case "class":
		return 'C'
	case "order":
		return 'O'
	case "family":
		return 'F'
	case "genus":
		return 'G'
	case "species":
		return 'S'
	}
	return 0
}

// dfs is KrakenReportDFS. Upstream passes the taxid as uint32_t; internal IDs fit.
func (r *kraken) dfs(id uint64, code byte, depthInRank, depth int) {
	cladeCount := r.clade[id] // absent reads as READCOUNTER(), i.e. 0
	// Clade count of 0 means all subtree nodes have clade count of 0.
	if !r.zeros && cladeCount == 0 {
		return
	}
	node := r.tax.Nodes[id]
	if c := rankCode(r.tax.Rank(id)); c != 0 {
		code, depthInRank = c, 0
	} else {
		depthInRank++
	}
	rankStr := string(code)
	if depthInRank != 0 {
		rankStr += strconv.Itoa(depthInRank)
	}
	// PrintKrakenStyleReportLine's taxid parameter is uint32_t.
	r.line(cladeCount, r.calls[id], rankStr, uint32(node.ExternalID), r.tax.Name(id), depth)

	if node.ChildCount == 0 {
		return
	}
	children := make([]uint64, node.ChildCount)
	for i := range children {
		children[i] = node.FirstChild + uint64(i)
	}
	// Sorting child IDs by descending order of clade read counts; taxa absent from the
	// counter map sort after all present ones.
	sortChildren(children, func(a, b uint64) bool {
		ca, okA := r.clade[a]
		if !okA {
			return false
		}
		cb, okB := r.clade[b]
		if !okB {
			return true
		}
		return int64(ca) > int64(cb)
	})
	for _, c := range children {
		r.dfs(c, code, depthInRank, depth+1)
	}
}

// line is PrintKrakenStyleReportLine without report_kmer_data.
func (r *kraken) line(clade, taxon uint64, rankStr string, taxid uint32, name string, depth int) {
	b := r.buf[:0]
	b = appendPct(b, 100.0*float64(int64(clade))/float64(r.total))
	b = append(b, '\t')
	b = strconv.AppendInt(b, int64(clade), 10)
	b = append(b, '\t')
	b = strconv.AppendInt(b, int64(taxon), 10)
	b = append(b, '\t')
	b = append(b, rankStr...)
	b = append(b, '\t')
	b = strconv.AppendUint(b, uint64(taxid), 10)
	b = append(b, '\t')
	for i := 0; i < depth; i++ {
		b = append(b, ' ', ' ')
	}
	b = append(b, name...)
	b = append(b, '\n')
	r.buf = b
	r.w.Write(b) // bufio.Writer keeps the first error for Flush
}

// appendPct appends v formatted as C's printf("%6.2f"). Go's 'f' formatting is correctly
// rounded (ties to even on the exact binary value), as glibc's and macOS's printf are; only
// the non-finite spellings differ. NaN occurs when there are no sequences at all (0/0): glibc
// prints a set sign bit as "-nan" (x86's default NaN), macOS prints "nan" either way.
func appendPct(b []byte, v float64) []byte {
	var s string
	switch {
	case math.IsNaN(v):
		s = "nan"
		if math.Signbit(v) && runtime.GOOS != "darwin" {
			s = "-nan"
		}
	case math.IsInf(v, 1):
		s = "inf"
	case math.IsInf(v, -1):
		s = "-inf"
	default:
		s = strconv.FormatFloat(v, 'f', 2, 64)
	}
	for i := len(s); i < 6; i++ {
		b = append(b, ' ')
	}
	return append(b, s...)
}

// MpaStyle writes the MetaPhlAn-style report (upstream's ReportMpaStyle).
func MpaStyle(w io.Writer, tax *taxo.Taxonomy, calls map[uint64]uint64, opt Options) error {
	m := &mpa{
		w:     bufio.NewWriter(w),
		tax:   tax,
		clade: cladeCounts(tax, calls),
		zeros: opt.ZeroCounts,
	}
	if len(tax.Nodes) > 1 {
		m.dfs(1)
	}
	return m.w.Flush()
}

type mpa struct {
	w     *bufio.Writer
	tax   *taxo.Taxonomy
	clade map[uint64]uint64
	zeros bool
	names []string
}

func mpaCode(rank string) byte {
	switch rank {
	case "superkingdom", "domain":
		return 'd'
	case "kingdom":
		return 'k'
	case "phylum":
		return 'p'
	case "class":
		return 'c'
	case "order":
		return 'o'
	case "family":
		return 'f'
	case "genus":
		return 'g'
	case "species":
		return 's'
	}
	return 0
}

// dfs is MpaReportDFS.
func (m *mpa) dfs(id uint64) {
	cladeCount := m.clade[id]
	// Clade count of 0 means all subtree nodes have clade count of 0.
	if !m.zeros && cladeCount == 0 {
		return
	}
	node := m.tax.Nodes[id]
	code := mpaCode(m.tax.Rank(id))
	if code != 0 {
		m.names = append(m.names, string(code)+"__"+m.tax.Name(id))
		// bufio.Writer keeps the first write error for Flush.
		m.w.WriteString(strings.Join(m.names, "|"))
		m.w.WriteByte('\t')
		m.w.WriteString(strconv.FormatUint(cladeCount, 10))
		m.w.WriteByte('\n')
	}
	if node.ChildCount != 0 {
		children := make([]uint64, node.ChildCount)
		for i := range children {
			children[i] = node.FirstChild + uint64(i)
		}
		// Sorting child IDs by descending order of clade counts (absent counts as 0 here:
		// upstream indexes the unordered_map with operator[]).
		sortChildren(children, func(a, b uint64) bool { return m.clade[a] > m.clade[b] })
		for _, c := range children {
			m.dfs(c)
		}
	}
	if code != 0 {
		m.names = m.names[:len(m.names)-1]
	}
}
