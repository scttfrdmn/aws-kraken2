// Ported from DerrickWood/kraken2 src/classify.cc at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package classify is the per-read part of upstream's classify.cc: the minimizer loop of
// ClassifySequence, ResolveTree, the per-read --output line and AddHitlistString.
//
// The work is split into the same three phases upstream itself uses at the pin, so that an
// engine can run them at different times and on different machines:
//
//  1. Scan: feed a read's ordered (minimizer, ambiguous) events into a Tokens. Tokens decides
//     lookup vs repeat vs skip vs ambiguous from minimizer values alone, exactly as upstream's
//     phase 1 does, and collects the minimizers that need a hash lookup (Tokens.Keys).
//  2. Lookup: fill Tokens.Vals[i] with the stored value for Tokens.Keys[i] (Tokens.Resolve does
//     this from a Resolver; an engine may batch and route them itself).
//  3. Classify: Classifier.Classify replays the tokens with the values, applies --quick,
//     --minimum-hit-groups and --confidence, appends the --output line to the worker's buffer
//     and updates the worker's per-taxon counters.
//
// No state is global: a Classifier holds per-worker scratch only, a Tokens holds one read, and
// a Worker holds one worker's output bytes and counters, so ordering and merging are the
// caller's job.
package classify

import (
	"errors"
	"math"
	"strconv"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
)

// Sentinel taxa in the per-read taxa vector (classify.cc MATE_PAIR_BORDER_TAXON,
// READING_FRAME_BORDER_TAXON, AMBIGUOUS_SPAN_TAXON; taxid_t is uint64_t, TAXID_MAX = ~0).
const (
	MatePairBorderTaxon     uint64 = math.MaxUint64
	ReadingFrameBorderTaxon uint64 = math.MaxUint64 - 1
	AmbiguousSpanTaxon      uint64 = math.MaxUint64 - 2
	// uniqueMinimizerTag is classify -F's UNIQUE_MINIMIZER_TAG: the top bit of taxid_t.
	uniqueMinimizerTag uint64 = 1 << 63
)

// ErrTranslatedSearch is returned for a protein database (opts.k2d dna_db == false).
var ErrTranslatedSearch = errors.New("classify: translated search (protein database) is not supported")

// Resolver returns the stored value (internal taxid, 0 = none) for a minimizer key.
type Resolver interface{ Get(key uint64) uint32 }

// Scanner yields minimizers for one sequence.
type Scanner interface {
	Load(seq []byte)
	Next() (minimizer uint64, ambiguous bool, ok bool)
}

// Tree is the taxonomy view classification needs (internal IDs).
type Tree interface {
	IsAAncestorOfB(a, b uint64) bool
	LowestCommonAncestor(a, b uint64) uint64
	Parent(id uint64) uint64
	ExternalID(id uint64) uint64
	Name(id uint64) string
}

// IndexInfo is the part of opts.k2d classification reads.
type IndexInfo struct {
	DNA                        bool   // dna_db
	MinimumAcceptableHashValue uint64 // minimum_acceptable_hash_value
}

// Options are the classify options that affect per-read results. Field comments give the
// classify flag (and the kraken2 wrapper flag that sets it).
type Options struct {
	Paired               bool    // -P / -S (--paired, --interleaved)
	Quick                bool    // -q (--quick)
	Confidence           float64 // -T (--confidence), in [0, 1]
	MinimumHitGroups     int     // -g (--minimum-hit-groups; the wrapper defaults to 2)
	UseNames             bool    // -n (--use-names)
	FlagUniqueMinimizers bool    // -F (no wrapper flag)
	// CountTaxa maintains per-taxon counters: upstream does so when -R (--report) or -d is set.
	CountTaxa bool
	// KmerData feeds every hit minimizer to Worker.Kmers: -K (--report-minimizer-data) or -d.
	KmerData bool
	// NoOutput skips building the --output line: -O - .
	NoOutput bool
}

// TaxonCount is one taxon's counters (readcounts.h READCOUNTER without the distinct-k-mer
// container, which Worker.Kmers receives instead).
type TaxonCount struct {
	Reads uint64 // reads called at this taxon (n_reads)
	Kmers uint64 // minimizer hits at this taxon (n_kmers)
}

// KmerSink receives each hit minimizer for distinct-minimizer estimation (rc.add_kmer).
type KmerSink interface{ AddKmer(taxon, minimizer uint64) }

// Worker is one worker's output and counters. Nothing in it is shared or locked.
type Worker struct {
	Out []byte // --output lines, appended in classification order
	// Counts maps internal taxid to its counters. A taxon is present once any of its
	// minimizers hit, even if no read is called there: upstream's report orders siblings by
	// presence in this map, so presence is part of the result.
	Counts     map[uint64]*TaxonCount
	Kmers      KmerSink // optional; used when Options.KmerData
	Classified uint64   // reads called (stats.total_classified)
}

func (w *Worker) count(taxon uint64) *TaxonCount {
	if w.Counts == nil {
		w.Counts = make(map[uint64]*TaxonCount)
	}
	tc := w.Counts[taxon]
	if tc == nil {
		tc = &TaxonCount{}
		w.Counts[taxon] = tc
	}
	return tc
}

// MergeCounts adds src's counters into dst (classify.cc's total_taxon_counters += ...).
func MergeCounts(dst, src map[uint64]*TaxonCount) {
	for t, s := range src {
		d := dst[t]
		if d == nil {
			d = &TaxonCount{}
			dst[t] = d
		}
		d.Reads += s.Reads
		d.Kmers += s.Kmers
	}
}

type tokKind uint8

// Token kinds (classify.cc MinTokKind; TOK_BORDER_FRAME is translated search only).
const (
	tokLookup tokKind = iota
	tokSkip
	tokRepeat
	tokAmbig
	tokBorderMate
)

// Tokens is one read's (or read pair's) scanned minimizer stream: classify.cc phase 1.
// The i-th lookup token's key is Keys[i]; its value goes in Vals[i].
type Tokens struct {
	kinds   []tokKind
	Keys    []uint64
	Vals    []uint32
	lastMin uint64
	minHash uint64
	hash    func(uint64) uint64
}

// NewTokens returns an empty token stream for an index. hashFn is MurmurHash3 (fmix64) for
// the minimum_acceptable_hash_value check; nil uses chash.MurmurHash3, the one port of it.
func NewTokens(idx IndexInfo, hashFn func(uint64) uint64) *Tokens {
	if hashFn == nil {
		hashFn = chash.MurmurHash3
	}
	t := &Tokens{minHash: idx.MinimumAcceptableHashValue, hash: hashFn}
	t.Reset()
	return t
}

// Reset starts a new read (and its first mate).
func (t *Tokens) Reset() {
	t.kinds = t.kinds[:0]
	t.Keys = t.Keys[:0]
	t.Vals = t.Vals[:0]
	t.lastMin = math.MaxUint64
}

// Add appends one scanner event.
func (t *Tokens) Add(minimizer uint64, ambiguous bool) {
	switch {
	case ambiguous:
		t.kinds = append(t.kinds, tokAmbig)
	case minimizer != t.lastMin:
		t.lastMin = minimizer
		if t.minHash != 0 && t.hash(minimizer) < t.minHash {
			t.kinds = append(t.kinds, tokSkip)
		} else {
			t.kinds = append(t.kinds, tokLookup)
			t.Keys = append(t.Keys, minimizer)
		}
	default:
		t.kinds = append(t.kinds, tokRepeat)
	}
}

// MateBorder ends the first mate of a pair and starts the second. Call it exactly once per
// read when Options.Paired, between the mates' events.
func (t *Tokens) MateBorder() {
	t.kinds = append(t.kinds, tokBorderMate)
	t.lastMin = math.MaxUint64
}

// Scan loads seq into s and appends all of its events.
func (t *Tokens) Scan(s Scanner, seq []byte) {
	s.Load(seq)
	for {
		m, amb, ok := s.Next()
		if !ok {
			return
		}
		t.Add(m, amb)
	}
}

// Resolve fills Vals from r: classify.cc phase 2.
func (t *Tokens) Resolve(r Resolver) {
	t.Vals = t.Vals[:0]
	for _, k := range t.Keys {
		t.Vals = append(t.Vals, r.Get(k))
	}
}

type hit struct {
	taxon uint64
	count uint64
}

// Classifier is one worker's classification scratch. It is not safe for concurrent use;
// give each worker its own.
type Classifier struct {
	tree  Tree
	opts  Options
	idx   IndexInfo
	tag   uint64
	taxa  []uint64
	hits  []hit
	toks  *Tokens
	hashF func(uint64) uint64
}

// New returns a Classifier. hashFn is as for NewTokens.
func New(tree Tree, idx IndexInfo, opts Options, hashFn func(uint64) uint64) (*Classifier, error) {
	if !idx.DNA {
		return nil, ErrTranslatedSearch
	}
	if hashFn == nil {
		hashFn = chash.MurmurHash3
	}
	c := &Classifier{tree: tree, opts: opts, idx: idx, hashF: hashFn}
	if opts.FlagUniqueMinimizers {
		c.tag = uniqueMinimizerTag
	}
	return c, nil
}

// NewTokens returns a token stream for this classifier's index.
func (c *Classifier) NewTokens() *Tokens { return NewTokens(c.idx, c.hashF) }

// ClassifySequence runs all three phases for one read: seq2 is the second mate and is
// ignored unless Options.Paired. id is the record identifier (up to the first whitespace).
func (c *Classifier) ClassifySequence(s Scanner, r Resolver, id, seq1, seq2 []byte, w *Worker) uint64 {
	if c.toks == nil {
		c.toks = c.NewTokens()
	}
	t := c.toks
	t.Reset()
	t.Scan(s, seq1)
	if c.opts.Paired {
		t.MateBorder()
		t.Scan(s, seq2)
	}
	t.Resolve(r)
	var len2 uint32
	if c.opts.Paired {
		len2 = uint32(len(seq2))
	}
	return c.Classify(t, id, uint32(len(seq1)), len2, w)
}

func (c *Classifier) addHit(taxon uint64) {
	for i := len(c.hits) - 1; i >= 0; i-- {
		if c.hits[i].taxon == taxon {
			c.hits[i].count++
			return
		}
	}
	c.hits = append(c.hits, hit{taxon, 1})
}

// replay is classify.cc phase 3, through the --quick early exit.
func (c *Classifier) replay(t *Tokens, w *Worker) (hitGroups int64) {
	c.taxa = c.taxa[:0]
	c.hits = c.hits[:0]
	var lastTaxon, tag uint64
	li := 0
	for _, k := range t.kinds {
		var taxon uint64
		switch k {
		case tokAmbig:
			c.taxa = append(c.taxa, AmbiguousSpanTaxon)
			continue
		case tokBorderMate:
			c.taxa = append(c.taxa, MatePairBorderTaxon)
			continue
		case tokSkip:
			taxon = 0
			lastTaxon = 0
		case tokLookup:
			taxon = uint64(t.Vals[li])
			key := t.Keys[li]
			li++
			lastTaxon = taxon
			if taxon != 0 {
				tag = c.tag
				hitGroups++
				if c.opts.CountTaxa {
					tc := w.count(taxon)
					if c.opts.KmerData {
						tc.Kmers++
						if w.Kmers != nil {
							w.Kmers.AddKmer(taxon, key)
						}
					}
				}
			}
		default: // tokRepeat
			taxon = lastTaxon
			// Upstream bumps this counter even without -R/-d, but the counters are only
			// ever read with one of them set.
			if taxon != 0 && c.opts.CountTaxa {
				w.count(taxon).Kmers++
			}
		}
		c.taxa = append(c.taxa, tag|taxon)
		tag = 0
		if taxon != 0 {
			c.addHit(taxon)
			if c.opts.Quick && hitGroups >= int64(c.opts.MinimumHitGroups) {
				return hitGroups
			}
		}
	}
	return hitGroups
}

// resolveTree is classify.cc ResolveTree, with its types: uint32 scores, a uint32 required
// score of ceil(confidence * total_minimizers) computed in double.
func (c *Classifier) resolveTree(totalMinimizers uint64) uint64 {
	var maxTaxon uint64
	var maxScore uint32
	required := uint32(math.Ceil(c.opts.Confidence * float64(totalMinimizers)))

	// Sum each taxon's root-to-leaf path; ties resolve to the LCA. hit_counts is an
	// unordered_map upstream; the result does not depend on its order (the call is the LCA
	// of every taxon with the maximum score), so a slice serves.
	for _, h := range c.hits {
		var score uint32
		for _, h2 := range c.hits {
			if c.tree.IsAAncestorOfB(h2.taxon, h.taxon) {
				score += uint32(h2.count)
			}
		}
		if score > maxScore {
			maxScore = score
			maxTaxon = h.taxon
		} else if score == maxScore {
			maxTaxon = c.tree.LowestCommonAncestor(maxTaxon, h.taxon)
		}
	}

	// Reset max score to only the hits at the called taxon.
	maxScore = 0
	for _, h := range c.hits {
		if h.taxon == maxTaxon {
			maxScore = uint32(h.count)
			break
		}
	}
	// Climb until the clade has the required support, or run off the tree.
	for maxTaxon != 0 && maxScore < required {
		maxScore = 0
		for _, h := range c.hits {
			if c.tree.IsAAncestorOfB(maxTaxon, h.taxon) {
				maxScore += uint32(h.count)
			}
		}
		if maxScore >= required {
			return maxTaxon
		}
		maxTaxon = c.tree.Parent(maxTaxon)
	}
	return maxTaxon
}

// Classify is phase 3 for one read: it returns the call (internal taxid, 0 = unclassified),
// appends the --output line to w.Out unless Options.NoOutput, and updates w's counters.
// t.Vals must hold one value per t.Keys. len2 is ignored unless Options.Paired.
func (c *Classifier) Classify(t *Tokens, id []byte, len1, len2 uint32, w *Worker) uint64 {
	if len(t.Vals) != len(t.Keys) {
		panic("classify: Tokens.Vals not resolved")
	}
	hitGroups := c.replay(t, w)

	totalKmers := uint64(len(c.taxa))
	if c.opts.Paired {
		totalKmers-- // the mate pair marker
	}
	call := c.resolveTree(totalKmers)
	// Void a call made by too few minimizer groups.
	if call != 0 && hitGroups < int64(c.opts.MinimumHitGroups) {
		call = 0
	}
	if call != 0 {
		w.Classified++
		if c.opts.CountTaxa {
			w.count(call).Reads++
		}
	}
	if c.opts.NoOutput {
		return call
	}
	w.Out = c.appendLine(w.Out, call, id, len1, len2)
	return call
}

func (c *Classifier) appendLine(b []byte, call uint64, id []byte, len1, len2 uint32) []byte {
	if call != 0 {
		b = append(b, "C\t"...)
	} else {
		b = append(b, "U\t"...)
	}
	n := len(id)
	if c.opts.Paired && n > 2 && id[n-2] == '/' && (id[n-1] == '1' || id[n-1] == '2') {
		n -= 2
	}
	b = append(b, id[:n]...)
	b = append(b, '\t')

	ext := c.tree.ExternalID(call)
	if c.opts.UseNames {
		if call != 0 {
			b = append(b, c.tree.Name(call)...)
		} else {
			b = append(b, "unclassified"...)
		}
		b = append(b, " (taxid "...)
		b = strconv.AppendUint(b, ext, 10)
		b = append(b, ')')
	} else {
		b = strconv.AppendUint(b, ext, 10)
	}
	b = append(b, '\t')
	b = strconv.AppendUint(b, uint64(len1), 10)
	if c.opts.Paired {
		b = append(b, '|')
		b = strconv.AppendUint(b, uint64(len2), 10)
	}
	b = append(b, '\t')

	switch {
	case c.opts.Quick:
		b = strconv.AppendUint(b, ext, 10)
		b = append(b, ":Q"...)
	case len(c.taxa) == 0:
		b = append(b, "0:0"...)
	default:
		b = c.appendHitlist(b)
	}
	return append(b, '\n')
}

// appendHitlist is classify.cc AddHitlistString: run-length "taxid:count " pairs, "A:n " for
// ambiguous spans, "|:| " at the mate border, and no trailing space after a final border.
func (c *Classifier) appendHitlist(b []byte) []byte {
	taxa := c.taxa
	last := taxa[0]
	count := uint64(1)
	for _, code := range taxa[1:] {
		if code == last {
			count++
			continue
		}
		b = c.appendCode(b, last, count, true)
		count = 1
		last = code
	}
	return c.appendCode(b, last, count, false)
}

func (c *Classifier) appendCode(b []byte, code, count uint64, more bool) []byte {
	switch code {
	case MatePairBorderTaxon, ReadingFrameBorderTaxon:
		if code == MatePairBorderTaxon {
			b = append(b, "|:|"...)
		} else {
			b = append(b, "-:-"...)
		}
		if more {
			b = append(b, ' ')
		}
		return b
	case AmbiguousSpanTaxon:
		b = append(b, "A:"...)
	default:
		if code&c.tag != 0 {
			b = append(b, '*')
		}
		b = strconv.AppendUint(b, c.tree.ExternalID(code&^uniqueMinimizerTag), 10)
		b = append(b, ':')
	}
	b = strconv.AppendUint(b, count, 10)
	return append(b, ' ')
}
