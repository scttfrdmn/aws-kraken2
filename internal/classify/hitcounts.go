// Clean-room implementation (issue #44) from a prose behavioural specification of the
// iteration order of std::unordered_map<unsigned long, unsigned long> as shipped in GCC
// 11.5.0's libstdc++; written without access to that library's source.
// Copyright 2026 aws-kraken2 contributors. MIT License.

package classify

import "math"

// hcNil marks "no node" in a link and "empty" in a bucket record.
const hcNil int32 = -1

// hcHead is the index of the list-head sentinel in hitCounts.nodes.
const hcHead int32 = 0

type hcNode struct {
	key, val uint64
	next     int32
}

// hitCounts is a hash map from taxon to count whose iteration order follows the spec:
// one singly-linked list of all nodes, with each non-empty bucket recording the node before
// its first node (hcHead when that is the list head). Nodes live in a pool indexed by int32;
// Clear keeps the pool's capacity and the bucket array, so the steady state allocates nothing.
type hitCounts struct {
	nodes   []hcNode // nodes[0] is the head sentinel; nodes[1:] are the live nodes
	buckets []int32  // per bucket: predecessor of its first node, or hcNil when empty
	spare   []int32  // a retired bucket array, reused by the next rehash when large enough
	nb      uint64   // B: bucket count
	thresh  uint64   // T: next-resize threshold
}

func newHitCounts() HitCounts { return newHitCountsMap() }

func newHitCountsMap() *hitCounts {
	return &hitCounts{nodes: []hcNode{{next: hcNil}}, nb: 1}
}

func (m *hitCounts) Clear() {
	// Empty only the buckets in use (B and T are kept); O(N), not O(B).
	for i := m.nodes[hcHead].next; i != hcNil; i = m.nodes[i].next {
		m.buckets[m.nodes[i].key%m.nb] = hcNil
	}
	m.nodes = m.nodes[:1]
	m.nodes[hcHead].next = hcNil
}

func (m *hitCounts) Increment(taxon uint64) { m.nodes[m.access(taxon)].val++ }

func (m *hitCounts) Lookup(taxon uint64) uint64 { return m.nodes[m.access(taxon)].val }

func (m *hitCounts) Range(f func(taxon, count uint64) bool) {
	for i := m.nodes[hcHead].next; i != hcNil; i = m.nodes[i].next {
		if !f(m.nodes[i].key, m.nodes[i].val) {
			return
		}
	}
}

// access is operator[]: the node index for key, inserting it with value 0 when absent.
func (m *hitCounts) access(key uint64) int32 {
	if m.buckets != nil {
		b := key % m.nb
		if p := m.buckets[b]; p != hcNil {
			for i := m.nodes[p].next; i != hcNil; i = m.nodes[i].next {
				k := m.nodes[i].key
				if k == key {
					return i
				}
				if k%m.nb != b {
					break
				}
			}
		}
	}
	m.grow()
	n := int32(len(m.nodes))
	m.nodes = append(m.nodes, hcNode{key: key, next: hcNil})
	m.link(n)
	return n
}

// grow runs the growth check before inserting a new key (spec §3.1).
func (m *hitCounts) grow() {
	n := uint64(len(m.nodes) - 1 + 1) // N + 1
	if n <= m.thresh {
		return
	}
	var need float64
	if m.thresh == 0 {
		need = float64(max(n, 11)) / 1.0
	} else {
		need = float64(n) / 1.0
	}
	if need < float64(m.nb) {
		m.thresh = m.nb // unreachable with the operations in scope (§3.1 step 4)
		return
	}
	r := max(uint64(math.Floor(need))+1, 2*m.nb)
	nb, t := hcNextBuckets(r, m.thresh)
	m.thresh = t
	m.rehash(nb)
}

// hcNextBuckets is spec §3.2: the bucket count for request r, and the new threshold
// (t is the current threshold, kept for r == 0).
func hcNextBuckets(r, t uint64) (uint64, uint64) {
	if r < uint64(len(hcSmall)) {
		if r == 0 {
			return 1, t
		}
		b := hcSmall[r]
		return b, b
	}
	// Smallest prime >= r, searching from 17 (index 6) up to but excluding the final entry.
	lo, hi := 6, len(hcPrimes)-1
	for lo < hi {
		mid := (lo + hi) / 2
		if hcPrimes[mid] < r {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == len(hcPrimes)-1 {
		return hcPrimes[lo], math.MaxUint64
	}
	return hcPrimes[lo], hcPrimes[lo]
}

// rehash re-links every node into a fresh array of nb buckets, walking the old list from
// its head and placing each node by the insertion rule (spec §5).
func (m *hitCounts) rehash(nb uint64) {
	var nbk []int32
	if uint64(cap(m.spare)) >= nb {
		nbk = m.spare[:nb]
	} else {
		nbk = make([]int32, nb)
	}
	for i := range nbk {
		nbk[i] = hcNil
	}
	m.spare = m.buckets
	m.buckets, m.nb = nbk, nb
	i := m.nodes[hcHead].next
	m.nodes[hcHead].next = hcNil
	for i != hcNil {
		next := m.nodes[i].next
		m.link(i)
		i = next
	}
}

// link places node n as the first node of its bucket (spec §4).
func (m *hitCounts) link(n int32) {
	b := m.nodes[n].key % m.nb
	if p := m.buckets[b]; p != hcNil {
		m.nodes[n].next = m.nodes[p].next
		m.nodes[p].next = n
		return
	}
	head := m.nodes[hcHead].next
	m.nodes[n].next = head
	m.nodes[hcHead].next = n
	if head != hcNil {
		m.buckets[m.nodes[head].key%m.nb] = n
	}
	m.buckets[b] = hcHead
}

// hcSmall is the bucket count for requests 0 to 13 (spec §3.2).
var hcSmall = [...]uint64{2, 2, 2, 3, 5, 5, 7, 7, 11, 11, 11, 11, 13, 13}

// hcPrimes is the spec's prime list (§3.3) including its final cap entry.
var hcPrimes = [...]uint64{
	2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89,
	97, 103, 109, 113, 127, 137, 139, 149, 157, 167, 179, 193, 199, 211, 227, 241, 257, 277, 293,
	313, 337, 359, 383, 409, 439, 467, 503, 541, 577, 619, 661, 709, 761, 823, 887, 953, 1031,
	1109, 1193, 1289, 1381, 1493, 1613, 1741, 1879, 2029, 2179, 2357, 2549, 2753, 2971, 3209,
	3469, 3739, 4027, 4349, 4703, 5087, 5503, 5953, 6427, 6949, 7517, 8123, 8783, 9497, 10273,
	11113, 12011, 12983, 14033, 15173, 16411, 17749, 19183, 20753, 22447, 24281, 26267, 28411,
	30727, 33223, 35933, 38873, 42043, 45481, 49201, 53201, 57557, 62233, 67307, 72817, 78779,
	85229, 92203, 99733, 107897, 116731, 126271, 136607, 147793, 159871, 172933, 187091, 202409,
	218971, 236897, 256279, 277261, 299951, 324503, 351061, 379787, 410857, 444487, 480881,
	520241, 562841, 608903, 658753, 712697, 771049, 834181, 902483, 976369, 1056323, 1142821,
	1236397, 1337629, 1447153, 1565659, 1693859, 1832561, 1982627, 2144977, 2320627, 2510653,
	2716249, 2938679, 3179303, 3439651, 3721303, 4026031, 4355707, 4712381, 5098259, 5515729,
	5967347, 6456007, 6984629, 7556579, 8175383, 8844859, 9569143, 10352717, 11200489, 12117689,
	13109983, 14183539, 15345007, 16601593, 17961079, 19431899, 21023161, 22744717, 24607243,
	26622317, 28802401, 31160981, 33712729, 36473443, 39460231, 42691603, 46187573, 49969847,
	54061849, 58488943, 63278561, 68460391, 74066549, 80131819, 86693767, 93793069, 101473717,
	109783337, 118773397, 128499677, 139022417, 150406843, 162723577, 176048909, 190465427,
	206062531, 222936881, 241193053, 260944219, 282312799, 305431229, 330442829, 357502601,
	386778277, 418451333, 452718089, 489790921, 529899637, 573292817, 620239453, 671030513,
	725980837, 785430967, 849749479, 919334987, 994618837, 1076067617, 1164186217, 1259520799,
	1362662261, 1474249943, 1594975441, 1725587117, 1866894511, 2019773507, 2185171673,
	2364114217, 2557710269, 2767159799, 2993761039, 3238918481, 3504151727, 3791104843,
	4101556399, 4294967291, 6442450933, 8589934583, 12884901857, 17179869143, 25769803693,
	34359738337, 51539607367, 68719476731, 103079215087, 137438953447, 206158430123, 274877906899,
	412316860387, 549755813881, 824633720731, 1099511627689, 1649267441579, 2199023255531,
	3298534883309, 4398046511093, 6597069766607, 8796093022151, 13194139533241, 17592186044399,
	26388279066581, 35184372088777, 52776558133177, 70368744177643, 105553116266399,
	140737488355213, 211106232532861, 281474976710597, 562949953421231, 1125899906842597,
	2251799813685119, 4503599627370449, 9007199254740881, 18014398509481951, 36028797018963913,
	72057594037927931, 144115188075855859, 288230376151711717, 576460752303423433,
	1152921504606846883, 2305843009213693951, 4611686018427387847, 9223372036854775783,
	18446744073709551557,
}
