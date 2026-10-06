// Ported from DerrickWood/kraken2 src/taxonomy.cc at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package classify

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

// testTree is a test-only Tree: internal IDs index the slices, parents have lower IDs than
// children (as upstream's Taxonomy requires). IsAAncestorOfB and LowestCommonAncestor are
// taxonomy.cc's.
type testTree struct {
	parent []uint64
	ext    []uint64
	name   []string
}

func (t *testTree) IsAAncestorOfB(a, b uint64) bool {
	if a == 0 || b == 0 {
		return false
	}
	for b > a {
		b = t.parent[b]
	}
	return b == a
}

func (t *testTree) LowestCommonAncestor(a, b uint64) uint64 {
	if a == 0 || b == 0 {
		if a != 0 {
			return a
		}
		return b
	}
	for a != b {
		if a > b {
			a = t.parent[a]
		} else {
			b = t.parent[b]
		}
	}
	return a
}

func (t *testTree) Parent(id uint64) uint64     { return t.parent[id] }
func (t *testTree) ExternalID(id uint64) uint64 { return t.ext[id] }
func (t *testTree) Name(id uint64) string       { return t.name[id] }

// loadTestTree reads classify_trace's taxonomy dump: id \t parent \t external \t name.
func loadTestTree(path string) (*testTree, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	t := &testTree{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.SplitN(sc.Text(), "\t", 4)
		p, err1 := strconv.ParseUint(fs[1], 10, 64)
		e, err2 := strconv.ParseUint(fs[2], 10, 64)
		if err1 != nil || err2 != nil || len(fs) != 4 {
			return nil, os.ErrInvalid
		}
		t.parent = append(t.parent, p)
		t.ext = append(t.ext, e)
		t.name = append(t.name, fs[3])
	}
	return t, sc.Err()
}
