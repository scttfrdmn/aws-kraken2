package classify

// HitCounts stands in for upstream's per-thread hit_counts (#44): a taxon_counts_t, which is
// std::unordered_map<taxid_t, uint64_t> with std::hash (kraken2_data.h:30), used by classify.cc
// at DerrickWood/kraken2 2731b35f7abb26ec926517274f3d87e78d42fd76 as follows.
//
//   - Lifetime: one map per worker thread (classify.cc:608), reused for every read that thread
//     classifies. Its state carries over from read to read.
//   - Clear: at the start of each read, hit_counts.clear() (classify.cc:971). The container's
//     bucket count is unchanged by clear().
//   - Increment: for each minimizer hit, hit_counts[taxon]++ (classify.cc:1085), in the order the
//     hits occur (first mate, then second). operator[] inserts the taxon with count 0 when it is
//     absent, then increments it.
//   - Range: ResolveTree (classify.cc:897-949) iterates the map in the container's iteration
//     order: the scoring walk and its inner sum (:905, :909), and the climb's sum (:931). The
//     scoring walk's result depends on this order when a score tie's LowestCommonAncestor is 0
//     (taxonomy.cc:262-272; LCA(0, x) = x), which RODA v205's orphan taxonomy nodes produce.
//   - Lookup: after the scoring walk, max_score = hit_counts[max_taxon] (classify.cc:927).
//     operator[] inserts max_taxon (which may be 0, or an LCA that no hit reached) with count 0
//     when it is absent; the insertion is part of the map's state for later iteration and reads.
//
// Equality with upstream requires Range to visit taxa in exactly the order upstream's container
// would, for the same sequence of operations since the map was created. The order is specified
// by black-box observation only: upstream/umap_order.cc runs the operations against the real
// container, and internal/classify/testdata/umap/ holds its golden output (docs/hitorder.md).
// An implementation is written clean-room from a prose specification (#44, as #35).
type HitCounts interface {
	// Clear is hit_counts.clear(): no entries; any state clear() keeps is kept.
	Clear()
	// Increment is hit_counts[taxon]++.
	Increment(taxon uint64)
	// Lookup is hit_counts[taxon] as an rvalue: the count, inserting taxon with 0 if absent.
	Lookup(taxon uint64) uint64
	// Range calls f for every entry in the container's iteration order until f returns false.
	Range(f func(taxon, count uint64) bool)
}

// newHitCounts (hitcounts.go) returns one worker's map: the clean-room implementation of
// upstream's iteration order (#44).
