package main

import (
	"flag"
	"fmt"

	"github.com/scttfrdmn/aws-kraken2/internal/taxo"
)

func init() {
	commands["taxo-orphans"] = command{
		summary: "list taxonomy nodes whose lineage does not reach the root, and nodes with external ID 0 (#44)",
		run:     taxoOrphans,
	}
}

// taxoOrphans walks every node's parent chain. A node whose chain reaches internal ID 0 without
// passing the root (internal 1) is an orphan: LowestCommonAncestor of it and any rooted taxon is
// 0, which makes ResolveTree's tie-breaking depend on hit_counts' iteration order (#44).
func taxoOrphans(args []string) error {
	fs := flag.NewFlagSet("taxo-orphans", flag.ExitOnError)
	max := fs.Int("max", 50, "list at most this many orphans")
	fs.Parse(args)
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: k2probe taxo-orphans [-max N] taxo.k2d")
	}
	t, err := taxo.Load(fs.Arg(0))
	if err != nil {
		return err
	}
	n, ext0 := 0, 0
	for i := uint64(1); i < uint64(len(t.Nodes)); i++ {
		if t.Nodes[i].ExternalID == 0 {
			ext0++
			fmt.Printf("external_id_0\tinternal %d\tparent %d\n", i, t.Nodes[i].ParentID)
		}
		b, steps := i, 0
		for b > 1 && steps < 1000 {
			b = t.Nodes[b].ParentID
			steps++
		}
		if b != 1 {
			if n < *max {
				fmt.Printf("orphan\tinternal %d\texternal %d\tparent %d\tchain_ends_at %d\n", i, t.Nodes[i].ExternalID, t.Nodes[i].ParentID, b)
			}
			n++
		}
	}
	fmt.Printf("nodes %d; orphans %d; external_id_0 (besides node 0) %d\n", len(t.Nodes), n, ext0)
	return nil
}
