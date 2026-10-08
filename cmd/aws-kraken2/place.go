package main

// Sample placement for sample-parallel cohort batches (#25): which node is a sample's home.
//
//   - mod: sample j of the batch (in manifest order) goes to node j mod N, and a node runs its
//     samples in manifest order. The E1 design; kept as the control.
//   - lpt: longest processing time first, by the samples' declared weights (pairs or bytes,
//     from the manifest). Samples are taken heaviest first (ties: manifest order), and each goes
//     to the node with the least weight so far (ties: the lowest rank). A node runs its samples
//     in that order, heaviest first. Every node computes the same placement from the same
//     manifest; no communication is needed. LPT's makespan is at most (4/3 − 1/(3N)) of the
//     optimum, and never more than the optimum plus the heaviest sample.

import "sort"

// placeMod returns, per rank, the batch indices it runs, in run order.
func placeMod(n, nodes int) [][]int {
	out := make([][]int, nodes)
	for j := 0; j < n; j++ {
		out[j%nodes] = append(out[j%nodes], j)
	}
	return out
}

// placeLPT returns, per rank, the batch indices it runs, in run order (heaviest first).
func placeLPT(weights []int64, nodes int) [][]int {
	idx := make([]int, len(weights))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(a, b int) bool { return weights[idx[a]] > weights[idx[b]] })
	out := make([][]int, nodes)
	load := make([]int64, nodes)
	for _, j := range idx {
		r := 0
		for k := 1; k < nodes; k++ {
			if load[k] < load[r] {
				r = k
			}
		}
		out[r] = append(out[r], j)
		load[r] += weights[j]
	}
	return out
}

// placeBatch returns the batch indices rank runs, in order, for the batch's placement.
func placeBatch(batch []*cohortLine, rank, nodes int) []int {
	if batch[0].place == "lpt" {
		w := make([]int64, len(batch))
		for i, l := range batch {
			w[i] = l.weight
		}
		return placeLPT(w, nodes)[rank]
	}
	return placeMod(len(batch), nodes)[rank]
}
