// Copyright 2026 aws-kraken2 contributors. MIT License.
//
// Provenance: stdSort is a structural transliteration of libstdc++'s std::sort and its heap
// helpers (bits/stl_algo.h: __introsort_loop, __move_median_to_first,
// __unguarded_partition(_pivot), __final_insertion_sort, __insertion_sort,
// __unguarded_linear_insert, __partial_sort; bits/stl_heap.h: __make_heap, __adjust_heap,
// __push_heap, __pop_heap, __sort_heap), which derive from the HP STL (Copyright 1994
// Hewlett-Packard Company) and the SGI STL (Copyright 1996 Silicon Graphics Computer Systems,
// Inc.). It is reproduced only so that ties between equal elements land in the order upstream's
// GCC builds leave them (report sibling order); it is not used for anything else.

package report

import "math/bits"

// stdSort sorts a in place and leaves equal elements in exactly the order libstdc++'s
// std::sort (GCC's introsort) leaves them.
//
// Upstream sorts each node's children with std::sort, which is not stable, so the order of
// siblings with equal clade counts -- and hence report bytes -- is whatever libstdc++'s
// algorithm produces. A Go sort would order those ties differently. This is the textbook
// introsort (Musser 1997) with the parameters and pivot/partition/insertion-sort/heapsort
// choices libstdc++ has used through GCC 16: a 16-element insertion-sort threshold, a depth
// limit of 2*floor(log2(n)), median-of-three of (first+1, mid, last-1) moved to first, an
// unguarded Hoare partition, a heapsort fallback, and a final insertion sort.
// less must be a strict weak ordering; it is called with element values.
func stdSort(a []uint64, less func(x, y uint64) bool) {
	n := len(a)
	if n == 0 {
		return
	}
	introsortLoop(a, 0, n, 2*(bits.Len(uint(n))-1), less)
	finalInsertionSort(a, 0, n, less)
}

const sortThreshold = 16

func introsortLoop(a []uint64, first, last, depth int, less func(x, y uint64) bool) {
	for last-first > sortThreshold {
		if depth == 0 {
			heapSort(a[first:last], less)
			return
		}
		depth--
		cut := partitionPivot(a, first, last, less)
		introsortLoop(a, cut, last, depth, less)
		last = cut
	}
}

func partitionPivot(a []uint64, first, last int, less func(x, y uint64) bool) int {
	mid := first + (last-first)/2
	moveMedianToFirst(a, first, first+1, mid, last-1, less)
	return unguardedPartition(a, first+1, last, first, less)
}

func moveMedianToFirst(a []uint64, result, x, y, z int, less func(x, y uint64) bool) {
	var m int
	switch {
	case less(a[x], a[y]):
		switch {
		case less(a[y], a[z]):
			m = y
		case less(a[x], a[z]):
			m = z
		default:
			m = x
		}
	case less(a[x], a[z]):
		m = x
	case less(a[y], a[z]):
		m = z
	default:
		m = y
	}
	a[result], a[m] = a[m], a[result]
}

func unguardedPartition(a []uint64, first, last, pivot int, less func(x, y uint64) bool) int {
	for {
		for less(a[first], a[pivot]) {
			first++
		}
		last--
		for less(a[pivot], a[last]) {
			last--
		}
		if first >= last {
			return first
		}
		a[first], a[last] = a[last], a[first]
		first++
	}
}

func unguardedLinearInsert(a []uint64, last int, less func(x, y uint64) bool) {
	val := a[last]
	next := last - 1
	for less(val, a[next]) {
		a[last] = a[next]
		last = next
		next--
	}
	a[last] = val
}

func insertionSort(a []uint64, first, last int, less func(x, y uint64) bool) {
	if first == last {
		return
	}
	for i := first + 1; i != last; i++ {
		if less(a[i], a[first]) {
			val := a[i]
			copy(a[first+1:i+1], a[first:i])
			a[first] = val
		} else {
			unguardedLinearInsert(a, i, less)
		}
	}
}

func finalInsertionSort(a []uint64, first, last int, less func(x, y uint64) bool) {
	if last-first > sortThreshold {
		insertionSort(a, first, first+sortThreshold, less)
		for i := first + sortThreshold; i != last; i++ {
			unguardedLinearInsert(a, i, less)
		}
	} else {
		insertionSort(a, first, last, less)
	}
}

// heapSort is partial_sort(first, last, last): make_heap then sort_heap.
func heapSort(a []uint64, less func(x, y uint64) bool) {
	n := len(a)
	if n >= 2 {
		for parent := (n - 2) / 2; ; parent-- {
			adjustHeap(a, parent, n, a[parent], less)
			if parent == 0 {
				break
			}
		}
	}
	for last := n; last > 1; {
		last--
		val := a[last]
		a[last] = a[0]
		adjustHeap(a, 0, last, val, less)
	}
}

func adjustHeap(a []uint64, hole, n int, val uint64, less func(x, y uint64) bool) {
	top := hole
	child := hole
	for child < (n-1)/2 {
		child = 2 * (child + 1)
		if less(a[child], a[child-1]) {
			child--
		}
		a[hole] = a[child]
		hole = child
	}
	if n&1 == 0 && child == (n-2)/2 {
		child = 2 * (child + 1)
		a[hole] = a[child-1]
		hole = child - 1
	}
	// push_heap
	parent := (hole - 1) / 2
	for hole > top && less(a[parent], val) {
		a[hole] = a[parent]
		hole = parent
		parent = (hole - 1) / 2
	}
	a[hole] = val
}
