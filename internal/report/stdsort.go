// Clean-room implementation (issue #35) from a prose behavioural specification of std::sort as
// shipped in GCC 11.5.0's libstdc++; written without access to that library's source.
// Copyright 2026 aws-kraken2 contributors. MIT License.

package report

import "math/bits"

// stdSortThreshold is the introsort cutoff: subranges of at most this size are left for the
// final insertion pass.
const stdSortThreshold = 16

// stdSort sorts a in place under the strict weak ordering less, leaving the elements (equal ones
// included) in exactly the order libstdc++'s std::sort (GCC 11.5.0) produces: introsort with a
// median-of-3 pivot and unguarded partition, a heapsort fallback once the depth budget
// 2*floor(log2 n) is spent, and a final insertion pass. It does not allocate.
func stdSort(a []uint64, less func(x, y uint64) bool) {
	n := len(a)
	if n == 0 {
		return
	}
	stdSortDepth(a, less, 2*(bits.Len(uint(n))-1))
}

// stdSortDepth is stdSort with an explicit depth budget (a test hook; stdSort passes 2*floor(log2 n)).
func stdSortDepth(a []uint64, less func(x, y uint64) bool, depth int) {
	if len(a) == 0 {
		return
	}
	introLoop(a, 0, len(a), depth, less)
	finalInsertion(a, less)
}

func introLoop(a []uint64, f, l, d int, less func(x, y uint64) bool) {
	for l-f > stdSortThreshold {
		if d == 0 {
			heapSort(a[f:l], less)
			return
		}
		d--
		medianToFirst(a, f, l, less)
		c := unguardedPartition(a, f, l, less)
		introLoop(a, c, l, d, less)
		l = c
	}
}

func medianToFirst(a []uint64, f, l int, less func(x, y uint64) bool) {
	xi, yi, zi := f+1, f+(l-f)/2, l-1
	x, y, z := a[xi], a[yi], a[zi]
	var m int
	if less(x, y) {
		switch {
		case less(y, z):
			m = yi
		case less(x, z):
			m = zi
		default:
			m = xi
		}
	} else {
		switch {
		case less(x, z):
			m = xi
		case less(y, z):
			m = zi
		default:
			m = yi
		}
	}
	a[f], a[m] = a[m], a[f]
}

func unguardedPartition(a []uint64, f, l int, less func(x, y uint64) bool) int {
	p := a[f]
	i, j := f+1, l
	for {
		for less(a[i], p) {
			i++
		}
		j--
		for less(p, a[j]) {
			j--
		}
		if i >= j {
			return i
		}
		a[i], a[j] = a[j], a[i]
		i++
	}
}

func settle(a []uint64, h, n int, v uint64, less func(x, y uint64) bool) {
	top := h
	for h < (n-1)/2 {
		c := 2*h + 2
		if less(a[c], a[c-1]) {
			c--
		}
		a[h] = a[c]
		h = c
	}
	if n%2 == 0 && h == (n-2)/2 {
		a[h] = a[n-1]
		h = n - 1
	}
	for h > top {
		p := (h - 1) / 2
		if !less(a[p], v) {
			break
		}
		a[h] = a[p]
		h = p
	}
	a[h] = v
}

func heapSort(a []uint64, less func(x, y uint64) bool) {
	m := len(a)
	if m >= 2 {
		for k := (m - 2) / 2; k >= 0; k-- {
			settle(a, k, m, a[k], less)
		}
	}
	for e := m - 1; e >= 1; e-- {
		v := a[e]
		a[e] = a[0]
		settle(a, 0, e, v, less)
	}
}

func finalInsertion(a []uint64, less func(x, y uint64) bool) {
	n := len(a)
	guarded := n
	if n > stdSortThreshold {
		guarded = stdSortThreshold
	}
	for i := 1; i < guarded; i++ {
		x := a[i]
		if less(x, a[0]) {
			copy(a[1:i+1], a[:i])
			a[0] = x
		} else {
			unguardedInsert(a, i, less)
		}
	}
	for i := guarded; i < n; i++ {
		unguardedInsert(a, i, less)
	}
}

func unguardedInsert(a []uint64, i int, less func(x, y uint64) bool) {
	x := a[i]
	j := i
	for less(x, a[j-1]) {
		a[j] = a[j-1]
		j--
	}
	a[j] = x
}
