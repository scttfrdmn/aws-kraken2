// Ported from DerrickWood/kraken2 src/mmscanner.cc (NextMinimizer) at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package mmscan

// Ambiguous marks an ambiguous position in AppendMinimizers' output. No unambiguous minimizer
// can equal it: a minimizer is an l-mer of at most 63 bits (l*bitsPerChar <= 63), and the
// only all-ones value Next reports, the initial last_minimizer_, is reported only while
// is_ambiguous() holds (fewer than k-l l-mers since a reset, or an ambiguous base in the
// current l-mer).
const Ambiguous = ^uint64(0)

// AppendMinimizers loads seq and appends to out what Next would report, call by call, until
// it reports nothing: the minimizer, or Ambiguous where is_ambiguous() held. It is Next's
// loop over a whole sequence with the scanner state in locals: no call, and no loads and
// stores of the state, per minimizer (issue #39). TestAppendMinimizersMatchesNext holds the
// two to the same output. Afterwards the scanner is exhausted, as after Next returned !ok.
func (s *Scanner) AppendMinimizers(seq []byte, out []uint64) []uint64 {
	s.Load(seq)
	str := s.str
	start, finish, strPos := s.start, s.finish, s.strPos
	k, l, kl := s.k, s.l, s.k-s.l
	bpc := s.bitsPerChar & 63
	lmerMask, ambigCode, toggle, ssm := s.lmerMask, s.ambigCode, s.toggleMask, s.spacedSeedMask
	dna, rcOld := s.dna, s.revcomVersion == 0
	n2 := uint(uint8(l)) * 2 // reverse_complement's n is a uint8_t
	rcShift := (64 - n2) & 63
	rcMask := (uint64(1) << (n2 & 63)) - 1
	if n2 >= 64 {
		rcMask = ^uint64(0)
	}
	lookup := &s.lookup
	q, qMask := s.q, s.qMask
	var lmer, lastAmbig uint64
	lastMin := ^uint64(0)
	loadedCh, queuePos, qHead, qLen := 0, 0, 0, 0
outer:
	for strPos < finish {
		changed := false
		for !changed {
			if loadedCh == l {
				loadedCh--
			}
			for loadedCh < l && strPos < finish {
				loadedCh++
				lmer <<= bpc
				lastAmbig <<= bpc
				code := lookup[str[strPos]]
				strPos++
				if code == 0xFF {
					qHead, qLen = 0, 0
					queuePos = 0
					lmer = 0
					loadedCh = 0
					lastAmbig |= ambigCode
				} else {
					lmer |= uint64(code)
				}
				lmer &= lmerMask
				lastAmbig &= lmerMask
				// Not yet a full k-mer: report nothing; an incomplete l-mer: report the
				// previous minimizer.
				if strPos-start >= k && loadedCh < l {
					m := lastMin
					if queuePos < kl || lastAmbig != 0 {
						m = Ambiguous
					}
					out = append(out, m)
					continue outer
				}
			}
			if loadedCh < l {
				break outer
			}
			canonical := lmer
			if dna { // canonical_representation, reverse_complement inlined
				x := lmer
				x = ((x & 0xCCCCCCCCCCCCCCCC) >> 2) | ((x & 0x3333333333333333) << 2)
				x = ((x & 0xF0F0F0F0F0F0F0F0) >> 4) | ((x & 0x0F0F0F0F0F0F0F0F) << 4)
				x = ((x & 0xFF00FF00FF00FF00) >> 8) | ((x & 0x00FF00FF00FF00FF) << 8)
				x = ((x & 0xFFFF0000FFFF0000) >> 16) | ((x & 0x0000FFFF0000FFFF) << 16)
				x = (x >> 32) | (x << 32)
				var rc uint64
				if rcOld {
					rc = ^x & rcMask
				} else {
					rc = (^x >> rcShift) & rcMask
				}
				if rc < canonical {
					canonical = rc
				}
			}
			if ssm != 0 {
				canonical &= ssm
			}
			candidate := canonical ^ toggle
			if kl == 0 { // Short-circuit queue work
				lastMin = candidate ^ toggle
				m := lastMin
				if lastAmbig != 0 {
					m = Ambiguous
				}
				out = append(out, m)
				continue outer
			}
			// Sliding window minimum
			for qLen > 0 && q[(qHead+qLen-1)&qMask].candidate > candidate {
				qLen--
			}
			if qLen == 0 && queuePos >= kl {
				changed = true
			}
			q[(qHead+qLen)&qMask] = minimizerData{candidate, queuePos}
			qLen++
			if q[qHead&qMask].pos < queuePos-kl {
				qHead = (qHead + 1) & qMask
				qLen--
				changed = true
			}
			if queuePos == kl {
				changed = true
			}
			queuePos++
			// Upstream compares the absolute str_pos_ here (see Next).
			if strPos >= k {
				break
			}
		}
		lastMin = q[qHead&qMask].candidate ^ toggle
		m := lastMin
		if queuePos < kl || lastAmbig != 0 {
			m = Ambiguous
		}
		out = append(out, m)
	}
	// Leave the scanner where Next would: exhausted, with its state.
	s.strPos, s.lmer, s.lastAmbig, s.lastMinimizer = strPos, lmer, lastAmbig, lastMin
	s.loadedCh, s.queuePos, s.qHead, s.qLen = loadedCh, queuePos, qHead, qLen
	return out
}
