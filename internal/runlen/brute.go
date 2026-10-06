package runlen

import "errors"

// Brute is the reference implementation the tests and `k2probe runs -brute` check ScanChunk32 and
// Accumulator against: one sequential walk over a whole occupancy vector, with no chunking. It
// rotates the table to start just after an empty cell, so the wrap run needs no special case.
func Brute(occ []bool, bounds []uint64) (*Result, error) {
	c := uint64(len(occ))
	r := &Result{Capacity: c, Cells: c, Boundaries: make([]Boundary, len(bounds))}
	e0 := -1
	for i, o := range occ {
		if o {
			r.Occupied++
		} else if e0 < 0 {
			e0 = i
		}
	}
	if e0 < 0 {
		return nil, errors.New("runlen: every cell is occupied; runs are undefined")
	}
	var run, start uint64
	for k := uint64(1); k <= c; k++ {
		i := (uint64(e0) + k) % c
		if occ[i] {
			if run == 0 {
				start = i
			}
			run++
			continue
		}
		if run > 0 {
			r.Hist.add(run, 1)
			r.Runs++
			if run > r.Longest {
				r.Longest, r.LongestStart = run, start
			}
			if start+run > c {
				r.Wrapped = true
			}
		}
		run = 0
	}
	for j, b := range bounds {
		bd := &r.Boundaries[j]
		bd.B = b
		last := (b + c - 1) % c
		if !occ[last] {
			continue
		}
		bd.Occupied = true
		for i := b % c; occ[i]; i = (i + 1) % c {
			bd.RunPast++
		}
		bd.Tail = bd.RunPast + 1
		back := uint64(0)
		for i := last; occ[i]; i = (i + c - 1) % c {
			back++
		}
		bd.RunStart = (last + c + 1 - back) % c
		bd.RunLen = back + bd.RunPast
	}
	return r, nil
}
