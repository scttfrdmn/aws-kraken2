// Ported from DerrickWood/kraken2 src/mmscanner.{h,cc} at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package mmscan is a port of kraken2's MinimizerScanner. It reports, for every k-mer
// of a sequence interval, the l-mer minimizer under the toggle-mask ordering, with
// upstream's exact quirks: which positions report, when a stale minimizer is
// re-reported, how ambiguous bases reset the window, and both reverse-complement
// versions.
//
// Usage mirrors upstream's loop in classify.cc (ClassifySequence):
//
//	s.Load(seq)
//	for {
//		mm, ambig, ok := s.Next() // upstream: ptr = NextMinimizer(); ptr != nullptr
//		if !ok { break }
//		if ambig { ... }          // upstream: scanner.is_ambiguous()
//		...                       // upstream: *ptr
//	}
//
// The minimizer value is reported even when ambig is true (it is whatever
// last_minimizer_ held: ^0 after a Load, or a previous minimizer); upstream's
// classifier ignores it in that case.
//
// Upstream quirk, preserved: after an ambiguous base at position p, is_ambiguous() is already
// false for the k-mer that starts at p (it ends at p+k-1). Its minimizer is taken over only the
// k-l l-mers after p, not k-l+1. So a read whose only N is its first base reports no ambiguous
// minimizer. The real-read probe confirms this (docs/g0b.md).
//
// minimum_acceptable_hash_value (capped databases) is NOT applied here. Upstream applies it
// in classify.cc ClassifySequence, Phase 1, only to non-ambiguous minimizers that differ
// from the previous one in the same frame/mate:
//
//	skip_lookup = idx_opts.minimum_acceptable_hash_value &&
//	    MurmurHash3(*minimizer_ptr) < idx_opts.minimum_acceptable_hash_value;
//
// (classify.cc:1007-1008 at the pin), after last_minimizer is updated, so a skipped
// minimizer still suppresses lookups of its immediate repeats (they become TOK_REPEAT).
package mmscan

import "fmt"

// Constants from mmscanner.h.
const (
	DefaultToggleMask     uint64 = 0xe37e28c4271b5a2d
	DefaultSpacedSeedMask uint64 = 0
	BitsPerCharDNA               = 2
	BitsPerCharPro               = 4
	CurrentRevcomVersion         = 1
)

type minimizerData struct {
	candidate uint64
	pos       int
}

// Scanner is upstream's MinimizerScanner. It is not safe for concurrent use; use
// one per goroutine, as upstream uses one per OpenMP thread. Load and Next do not
// allocate.
type Scanner struct {
	str            []byte
	k, l           int
	strPos, start  int
	finish         int
	spacedSeedMask uint64
	dna            bool
	toggleMask     uint64
	lmer           uint64
	lmerMask       uint64
	lastMinimizer  uint64
	loadedCh       int
	// queue_ (a std::vector used as a deque) as a ring buffer of power-of-two size.
	q             []minimizerData
	qMask         int
	qHead         int
	qLen          int
	queuePos      int
	lastAmbig     uint64
	bitsPerChar   uint
	ambigCode     uint64
	revcomVersion int
	lookup        [256]uint8
}

// New mirrors MinimizerScanner's constructor. Note the parameter order follows the
// suggested Go shape (toggle mask before dnaSequence), which differs from the C++
// constructor's (spaced_seed_mask, dna_sequence, toggle_mask, revcom_version).
//
// Upstream's only check is the l size limit (errx in the constructor); the Go port
// returns that as an error. It additionally rejects l < 1 and k < l, for which
// upstream's behaviour is undefined (front() on an empty queue).
func New(k, l int, spacedSeedMask, toggleMask uint64, dnaSequence bool, revcomVersion int) (*Scanner, error) {
	bpc := BitsPerCharPro
	kind := "protein"
	if dnaSequence {
		bpc = BitsPerCharDNA
		kind = "nucleotide"
	}
	if l > (64-1)/bpc {
		return nil, fmt.Errorf("l exceeds size limits for minimizer %s scanner", kind)
	}
	if l < 1 || k < l {
		return nil, fmt.Errorf("mmscan: need 1 <= l <= k, got k=%d l=%d", k, l)
	}
	s := &Scanner{
		k:              k,
		l:              l,
		spacedSeedMask: spacedSeedMask,
		dna:            dnaSequence,
		toggleMask:     toggleMask,
		revcomVersion:  revcomVersion,
		bitsPerChar:    uint(bpc),
		ambigCode:      (1 << uint(bpc)) - 1,
	}
	s.lmerMask = (uint64(1) << uint(l*bpc)) - 1
	s.toggleMask &= s.lmerMask
	// The window holds at most k-l+1 entries after expiry, k-l+2 transiently.
	n := 1
	for n < k-l+2 {
		n <<= 1
	}
	s.q = make([]minimizerData, n)
	s.qMask = n - 1
	for i := range s.lookup {
		s.lookup[i] = 0xFF
	}
	if dnaSequence {
		s.set('A', 0x00)
		s.set('C', 0x01)
		s.set('G', 0x02)
		s.set('T', 0x03)
	} else {
		// Reduced 15-letter alphabet from AD Solis (2015), Proteins
		// (doi:10.1002/prot.24936). B, Z, J and X are treated as ambiguous, as upstream.
		s.set('*', 0x00) // stop codons/rare amino acids
		s.set('U', 0x00)
		s.set('O', 0x00)
		s.set('A', 0x01) // alanine
		s.set('N', 0x02) // asparagine, glutamine, serine
		s.set('Q', 0x02)
		s.set('S', 0x02)
		s.set('C', 0x03) // cysteine
		s.set('D', 0x04) // aspartic acid, glutamic acid
		s.set('E', 0x04)
		s.set('F', 0x05) // phenylalanine
		s.set('G', 0x06) // glycine
		s.set('H', 0x07) // histidine
		s.set('I', 0x08) // isoleucine, leucine
		s.set('L', 0x08)
		s.set('K', 0x09) // lysine
		s.set('P', 0x0a) // proline
		s.set('R', 0x0b) // arginine
		s.set('M', 0x0c) // methionine, valine
		s.set('V', 0x0c)
		s.set('T', 0x0d) // threonine
		s.set('W', 0x0e) // tryptophan
		s.set('Y', 0x0f) // tyrosine
	}
	return s, nil
}

// set mirrors set_lookup_table_character: the character and its tolower().
func (s *Scanner) set(c byte, val uint8) {
	s.lookup[c] = val
	if c >= 'A' && c <= 'Z' { // tolower in the C locale
		s.lookup[c+'a'-'A'] = val
	}
}

// Load is LoadSequence(seq) over the whole sequence, as classify.cc calls it.
func (s *Scanner) Load(seq []byte) { s.LoadRange(seq, 0, len(seq)) }

// LoadRange is LoadSequence(seq, start, finish) over [start, finish). A finish past
// the end is clamped to len(seq) (upstream's default is SIZE_MAX); an interval shorter
// than one l-mer invalidates the scanner so Next reports nothing.
func (s *Scanner) LoadRange(seq []byte, start, finish int) {
	s.str = seq
	s.start = start
	s.finish = finish
	s.strPos = start
	if s.finish > len(seq) {
		s.finish = len(seq)
	}
	if s.finish-s.start+1 < s.l {
		s.strPos = s.finish
	}
	s.qHead, s.qLen = 0, 0
	s.queuePos = 0
	s.loadedCh = 0
	s.lastMinimizer = ^uint64(0)
	s.lastAmbig = 0
	s.lmer = 0
}

// IsAmbiguous is is_ambiguous(): no full k-mer since the last ambiguous base, or an
// ambiguous base inside the current l-mer.
func (s *Scanner) IsAmbiguous() bool {
	return s.queuePos < s.k-s.l || s.lastAmbig != 0
}

// LastMinimizer is last_minimizer(), only valid if Next last returned ok.
func (s *Scanner) LastMinimizer() uint64 { return s.lastMinimizer }

// K returns k.
func (s *Scanner) K() int { return s.k }

// L returns l.
func (s *Scanner) L() int { return s.l }

// IsDNA reports whether this is a nucleotide scanner.
func (s *Scanner) IsDNA() bool { return s.dna }

// Next is NextMinimizer(). ok=false corresponds to upstream's nullptr. When ok,
// minimizer is *ptr and ambiguous is is_ambiguous() evaluated right after the call.
func (s *Scanner) Next() (minimizer uint64, ambiguous bool, ok bool) {
	if s.strPos >= s.finish { // Abort if we've exhausted string interval
		return 0, false, false
	}
	bpc := s.bitsPerChar
	changed := false
	for !changed {
		// Incorporate next character (and more if needed to fill l-mer)
		if s.loadedCh == s.l {
			s.loadedCh--
		}
		for s.loadedCh < s.l && s.strPos < s.finish { // char loading loop
			s.loadedCh++
			s.lmer <<= bpc
			s.lastAmbig <<= bpc
			code := s.lookup[s.str[s.strPos]]
			s.strPos++
			if code == 0xFF {
				s.qHead, s.qLen = 0, 0
				s.queuePos = 0
				s.lmer = 0
				s.loadedCh = 0
				s.lastAmbig |= s.ambigCode
			} else {
				s.lmer |= uint64(code)
			}
			s.lmer &= s.lmerMask
			s.lastAmbig &= s.lmerMask
			// If we haven't filled up the first k-mer, don't return. Otherwise, if
			// the l-mer is incomplete, still return (the previous minimizer).
			if s.strPos-s.start >= s.k && s.loadedCh < s.l {
				return s.lastMinimizer, s.IsAmbiguous(), true
			}
		}
		if s.loadedCh < s.l { // exhausted interval without filling the l-mer
			return 0, false, false
		}
		canonical := s.lmer
		if s.dna {
			canonical = s.canonicalRepresentation(s.lmer, s.l)
		}
		if s.spacedSeedMask != 0 {
			canonical &= s.spacedSeedMask
		}
		candidate := canonical ^ s.toggleMask
		if s.k == s.l { // Short-circuit queue work
			s.lastMinimizer = candidate ^ s.toggleMask
			return s.lastMinimizer, s.IsAmbiguous(), true
		}
		// Sliding window minimum calculation
		for s.qLen > 0 && s.q[(s.qHead+s.qLen-1)&s.qMask].candidate > candidate {
			s.qLen-- // pop_back
		}
		if s.qLen == 0 && s.queuePos >= s.k-s.l {
			// Empty queue means front will change; minimizer changes iff we've
			// processed enough l-mers.
			changed = true
		}
		s.q[(s.qHead+s.qLen)&s.qMask] = minimizerData{candidate, s.queuePos} // push_back
		s.qLen++
		// Expire an l-mer not in the current window.
		if s.q[s.qHead].pos < s.queuePos-s.k+s.l {
			s.qHead = (s.qHead + 1) & s.qMask // erase(begin())
			s.qLen--
			changed = true
		}
		// Change from no minimizer (beginning of sequence/near ambig. char)
		if s.queuePos == s.k-s.l {
			changed = true
		}
		s.queuePos++
		// Return only if we've read in at least one k-mer's worth of chars. Upstream
		// compares the absolute position str_pos_ (not str_pos_ - start_) here.
		if s.strPos >= s.k {
			break
		}
	}
	s.lastMinimizer = s.q[s.qHead].candidate ^ s.toggleMask
	return s.lastMinimizer, s.IsAmbiguous(), true
}

// reverseComplement mirrors reverse_complement, including the pre-2.0.8
// (revcom_version == 0) behaviour kept for old databases.
func (s *Scanner) reverseComplement(kmer uint64, n int) uint64 {
	n = int(uint8(n)) // upstream passes n as uint8_t
	kmer = ((kmer & 0xCCCCCCCCCCCCCCCC) >> 2) | ((kmer & 0x3333333333333333) << 2)
	kmer = ((kmer & 0xF0F0F0F0F0F0F0F0) >> 4) | ((kmer & 0x0F0F0F0F0F0F0F0F) << 4)
	kmer = ((kmer & 0xFF00FF00FF00FF00) >> 8) | ((kmer & 0x00FF00FF00FF00FF) << 8)
	kmer = ((kmer & 0xFFFF0000FFFF0000) >> 16) | ((kmer & 0x0000FFFF0000FFFF) << 16)
	kmer = (kmer >> 32) | (kmer << 32)
	mask := (uint64(1) << uint(n*2)) - 1
	if s.revcomVersion == 0 {
		return ^kmer & mask
	}
	return (^kmer >> uint(64-n*2)) & mask
}

func (s *Scanner) canonicalRepresentation(kmer uint64, n int) uint64 {
	rc := s.reverseComplement(kmer, n)
	if kmer < rc {
		return kmer
	}
	return rc
}
