// Ported from DerrickWood/kraken2 src/taxonomy.{h,cc} at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

// Package taxo reads kraken2's taxo.k2d taxonomy (the read side of upstream's Taxonomy class).
//
// All IDs are internal IDs (positions in the node array, as stored in the hash table) unless a
// name says External. Node 0 is the all-zero sentinel; node 1 is the root. Parents always have
// smaller IDs than their children, which IsAAncestorOfB and LowestCommonAncestor rely on.
package taxo

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"os"
)

// FileMagic is the 8-byte header of taxo.k2d.
const FileMagic = "K2TAXDAT"

// nodeSize is sizeof(TaxonomyNode): seven uint64 fields.
const nodeSize = 7 * 8

// headerSize is the magic plus node_count_, name_data_len_ and rank_data_len_ (size_t each).
const headerSize = len(FileMagic) + 3*8

// Node mirrors upstream's TaxonomyNode field for field.
type Node struct {
	ParentID    uint64 // Must be lower-numbered node
	FirstChild  uint64 // Must be higher-numbered node
	ChildCount  uint64 // Children of a node are in contiguous block
	NameOffset  uint64 // Location of name in name data super-string
	RankOffset  uint64 // Location of rank in rank data super-string
	ExternalID  uint64 // Taxonomy ID for reporting purposes (usually NCBI)
	GodparentID uint64 // Reserved for future use to enable faster traversal
}

// Tree is the subset of the taxonomy that classification needs.
type Tree interface {
	IsAAncestorOfB(a, b uint64) bool
	LowestCommonAncestor(a, b uint64) uint64
	Parent(id uint64) uint64
	ExternalID(id uint64) uint64
	Name(id uint64) string
}

var _ Tree = (*Taxonomy)(nil)

// Taxonomy is a loaded taxo.k2d.
type Taxonomy struct {
	Nodes    []Node
	NameData []byte
	RankData []byte

	extToInt map[uint64]uint64
}

// Load reads a taxo.k2d file.
func Load(filename string) (*Taxonomy, error) {
	b, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}
	t, err := Parse(b)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", filename, err)
	}
	return t, nil
}

// Parse decodes the bytes of a taxo.k2d file. Upstream refuses a file whose magic differs
// ("malformed taxonomy file") or that ends before all advertised data is read ("read exhausted
// taxonomy information"); Parse returns an error in both cases. Trailing bytes are ignored, as
// upstream ignores them.
func Parse(b []byte) (*Taxonomy, error) {
	if len(b) < len(FileMagic) || string(b[:len(FileMagic)]) != FileMagic {
		return nil, fmt.Errorf("malformed taxonomy file")
	}
	if len(b) < headerSize {
		return nil, fmt.Errorf("read exhausted taxonomy information")
	}
	le := binary.LittleEndian
	p := len(FileMagic)
	nodeCount := le.Uint64(b[p:])
	nameLen := le.Uint64(b[p+8:])
	rankLen := le.Uint64(b[p+16:])
	p = headerSize
	rest := uint64(len(b) - p)
	if nodeCount > rest/nodeSize || nameLen > rest || rankLen > rest ||
		nodeCount*nodeSize+nameLen+rankLen > rest {
		return nil, fmt.Errorf("read exhausted taxonomy information")
	}
	t := &Taxonomy{Nodes: make([]Node, nodeCount)}
	for i := range t.Nodes {
		f := b[p : p+nodeSize]
		t.Nodes[i] = Node{
			ParentID:    le.Uint64(f[0:]),
			FirstChild:  le.Uint64(f[8:]),
			ChildCount:  le.Uint64(f[16:]),
			NameOffset:  le.Uint64(f[24:]),
			RankOffset:  le.Uint64(f[32:]),
			ExternalID:  le.Uint64(f[40:]),
			GodparentID: le.Uint64(f[48:]),
		}
		p += nodeSize
	}
	t.NameData = append([]byte(nil), b[p:p+int(nameLen)]...)
	p += int(nameLen)
	t.RankData = append([]byte(nil), b[p:p+int(rankLen)]...)
	return t, nil
}

// NodeCount is upstream's node_count(), including the sentinel node 0.
func (t *Taxonomy) NodeCount() int { return len(t.Nodes) }

// cstr returns the NUL-terminated string at off (upstream reads `data + off` as a C string).
func cstr(data []byte, off uint64) string {
	if off >= uint64(len(data)) {
		return ""
	}
	s := data[off:]
	if i := bytes.IndexByte(s, 0); i >= 0 {
		s = s[:i]
	}
	return string(s)
}

// Name is the scientific name of node id.
func (t *Taxonomy) Name(id uint64) string { return cstr(t.NameData, t.Nodes[id].NameOffset) }

// Rank is the rank string of node id (e.g. "species", "no rank").
func (t *Taxonomy) Rank(id uint64) string { return cstr(t.RankData, t.Nodes[id].RankOffset) }

// ExternalID is the reporting (NCBI) taxid of node id.
func (t *Taxonomy) ExternalID(id uint64) uint64 { return t.Nodes[id].ExternalID }

// Parent is the internal ID of node id's parent (0 for the root and the sentinel).
func (t *Taxonomy) Parent(id uint64) uint64 { return t.Nodes[id].ParentID }

// IsAAncestorOfB reports whether a is b or an ancestor of b. Either ID being 0 gives false.
// Logic here depends on higher nodes having smaller IDs: advance B up the tree; A is an
// ancestor iff the B tracker hits A.
func (t *Taxonomy) IsAAncestorOfB(a, b uint64) bool {
	if a == 0 || b == 0 {
		return false
	}
	for b > a {
		b = t.Nodes[b].ParentID
	}
	return b == a
}

// LowestCommonAncestor returns the LCA of a and b; LCA(x,0) = LCA(0,x) = x.
// Logic here depends on higher nodes having smaller IDs: advance the lower tracker up the tree
// until the trackers meet.
func (t *Taxonomy) LowestCommonAncestor(a, b uint64) uint64 {
	if a == 0 || b == 0 {
		if a != 0 {
			return a
		}
		return b
	}
	for a != b {
		if a > b {
			a = t.Nodes[a].ParentID
		} else {
			b = t.Nodes[b].ParentID
		}
	}
	return a
}

// InternalID maps an external taxid to its internal ID, 0 if unknown. It follows upstream's
// GenerateExternalToInternalIDMap + GetInternalID: 0 maps to 0 and, should two nodes share an
// external ID, the higher internal ID wins. The map is built on first use, so the first call
// is not safe to race with others; call BuildExternalMap up front when sharing a Taxonomy.
func (t *Taxonomy) InternalID(external uint64) uint64 {
	if t.extToInt == nil {
		t.BuildExternalMap()
	}
	return t.extToInt[external]
}

// BuildExternalMap builds the external-to-internal ID map (upstream's
// GenerateExternalToInternalIDMap).
func (t *Taxonomy) BuildExternalMap() {
	m := make(map[uint64]uint64, len(t.Nodes))
	m[0] = 0
	for i := 1; i < len(t.Nodes); i++ {
		m[t.Nodes[i].ExternalID] = uint64(i)
	}
	t.extToInt = m
}
