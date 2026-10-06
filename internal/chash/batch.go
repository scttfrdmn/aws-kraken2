// Ported from DerrickWood/kraken2 src/compact_hash.h (Get) at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package chash

// BatchScratch is per-goroutine scratch for GetBatch. The zero value is ready.
type BatchScratch struct {
	idx  []uint64
	sink uint32
}

// GetBatch appends Get(k)'s value for each of keys to vals, in order, and returns vals. It
// computes every key's home slot and touches its cell first, so the table's cache misses for a
// read's keys are in flight together, then probes each key from its home slot (issue #39).
// The values are exactly Get's.
func (t *Table) GetBatch(keys []uint64, vals []uint32, s *BatchScratch) []uint32 {
	if t.cells32 == nil || t.Mode != Linear {
		for _, k := range keys {
			v, _ := t.Get(k)
			vals = append(vals, v)
		}
		return vals
	}
	cells := t.cells32
	capacity := t.Layout.Capacity
	if cap(s.idx) < len(keys) {
		s.idx = make([]uint64, len(keys), 2*len(keys))
	}
	idx := s.idx[:len(keys)]
	var touch uint32
	for i, k := range keys {
		j := MurmurHash3(k) % capacity
		idx[i] = j
		touch |= cells[j] // a load only, so the misses overlap
	}
	s.sink = touch
	vb := t.Layout.ValueBits
	mask := t.mask
	shift := t.shiftK
	for i, k := range keys {
		compacted := MurmurHash3(k) >> shift
		j := idx[i]
		first := j
		var v uint32
		for {
			d := cells[j]
			v = d & mask
			if v == 0 {
				break
			}
			if uint64(d>>vb) == compacted {
				break
			}
			if j++; j == capacity {
				j = 0
			}
			if j == first {
				v = 0
				break
			}
		}
		vals = append(vals, v)
	}
	return vals
}
