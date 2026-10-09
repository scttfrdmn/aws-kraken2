package engine

// ETag verification of the sharded load (#49, AK2_ENGINE_VERIFY_ETAG). An S3 ETag of an object
// uploaded in one part is the md5 of its bytes; of a multipart upload, md5(concat(md5(part_i)))
// followed by "-" and the part count. The part size is not stored, so it is inferred as
// scripts/lib/etagcheck.py does (the smallest power-of-two MiB size, 1 MiB to 4 GiB, whose part
// count for the object's size equals the ETag's), unless it is given.
//
// # The guarantee
//
// Every byte any node holds in memory (its owned cells, its overlap tail, the last shard's
// wrapped tail) and the header every node parsed is either one of the bytes the ETag was
// recomputed from, or equal (by md5) to a copy of those bytes that is.
//
// Parts: node i of n owns the bytes U-range [start_i, end_i) = [H+Lo·cb, H+Hi·cb), node 0's
// from byte 0 (the header) and node n−1's to the object's end. These ranges partition the
// object, and node i hashes exactly the parts that start in its range ("used" bytes
// [first part's start, last part's end)), taken by file offset from the header, its shard's
// first (unwrapped) segment, and, for its last part only, one extra ranged GET of what lies past
// that segment. Each part is hashed once, by one node.
//
// Cross-checks: a node holds bytes that another node used for the ETag wherever its cells
// overlap that node's used range: the head of its own range when the previous node's last part
// straddles into it, its overlap tail past its range, the last shard's wrapped tail at the
// start of the table. For every pair (holder q, user r ≠ q) and every interval where q's held
// cells meet r's used range, q publishes the md5 of its memory there and r the md5 of the bytes
// it used there; Combine requires each such pair to exist on both sides and to be equal. Every
// node also publishes the md5 of the header it parsed, which must equal node 0's (node 0 used
// it in part 0). Held bytes in a node's own used range are hashed from its memory directly. So
// no byte a node classifies against goes unverified, and no byte is counted twice in the ETag.
//
// Every node, rank 0 included, combines the rendezvous records and compares before any sample
// is classified.

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"runtime"
	"strconv"
	"strings"
	"sync"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

// ETag is a parsed S3 ETag of hash.k2d with its part layout.
type ETag struct {
	Raw       string   // without quotes
	Sum       [16]byte // the plain md5, or the md5 of the concatenated part digests
	Multipart bool     // "<hex>-<count>"
	Parts     int      // part count (1 for a single-part ETag)
	PartSize  int64    // bytes per part (the last may be shorter); the size for a single part
	Size      int64    // the object's size
}

// ErrETagMismatch is the verifier's error when the loaded bytes do not give the ETag, or a
// node's copy of bytes differs from the copy another node used for it.
var ErrETagMismatch = errors.New("engine: hash.k2d does not match its ETag")

// ErrETagFormat is ParseETag's error when the ETag cannot be checked at all: not an md5 ETag
// (an SSE-KMS or SSE-C object's ETag is not), or no part size gives its part count.
var ErrETagFormat = errors.New("engine: ETag cannot be verified")

// ParseETag parses etag (quotes allowed) for an object of size bytes and infers its part size.
func ParseETag(etag string, size int64) (ETag, error) { return ParseETagParts(etag, size, 0) }

// ParseETagParts is ParseETag with the part size given (etagcheck.py's --part-bytes) when
// partBytes > 0, and inferred otherwise.
func ParseETagParts(etag string, size, partBytes int64) (ETag, error) {
	t := ETag{Raw: strings.Trim(strings.TrimSpace(etag), `"`), Size: size}
	if size <= 0 {
		return t, fmt.Errorf("%w: ETag %q: object size %d", ErrETagFormat, t.Raw, size)
	}
	hexSum, count, multi := strings.Cut(t.Raw, "-")
	b, err := hex.DecodeString(hexSum)
	if err != nil || len(b) != md5.Size {
		return t, fmt.Errorf("%w: ETag %q is not an md5 ETag (SSE-KMS and SSE-C objects' ETags are not)", ErrETagFormat, t.Raw)
	}
	copy(t.Sum[:], b)
	if !multi {
		t.Parts, t.PartSize = 1, size
		return t, nil
	}
	t.Multipart = true
	if t.Parts, err = strconv.Atoi(count); err != nil || t.Parts < 1 || t.Parts > 10000 {
		return t, fmt.Errorf("%w: ETag %q: part count %q", ErrETagFormat, t.Raw, count)
	}
	if partBytes > 0 {
		if (size+partBytes-1)/partBytes != int64(t.Parts) {
			return t, fmt.Errorf("%w: ETag %q: %d-byte parts of a %d-byte object are not %d parts",
				ErrETagFormat, t.Raw, partBytes, size, t.Parts)
		}
		t.PartSize = partBytes
		return t, nil
	}
	for mib := int64(1); mib <= 4096; mib *= 2 {
		if p := mib << 20; (size+p-1)/p == int64(t.Parts) {
			t.PartSize = p
			return t, nil
		}
	}
	return t, fmt.Errorf("%w: ETag %q: no power-of-two MiB part size gives %d parts of a %d-byte object; give the part size",
		ErrETagFormat, t.Raw, t.Parts, size)
}

// part returns part k's bytes [a, b).
func (t ETag) part(k int) (a, b int64) {
	a = int64(k) * t.PartSize
	return a, min(a+t.PartSize, t.Size)
}

// Overlap is the md5 of the bytes [Off, Off+Len) as held in memory by node Holder (in Held) or
// as used for the ETag by node User (in Used).
type Overlap struct {
	Holder int    `json:"holder"`
	User   int    `json:"user"`
	Off    int64  `json:"off"`
	Len    int64  `json:"len"`
	MD5    string `json:"md5"`
}

// PartDigests is one node's rendezvous record of the check (etag_parts): the md5s of the
// consecutive parts First, First+1, … it hashed, the md5 of the header it parsed, and its
// cross-check digests. PartSize and Parts restate the layout the node inferred.
type PartDigests struct {
	Rank     int       `json:"rank"`
	PartSize int64     `json:"part_bytes"`
	Parts    int       `json:"parts"`
	First    int       `json:"first"`
	MD5      []string  `json:"md5"` // hex, part First+j at j
	Header   string    `json:"header_md5"`
	Held     []Overlap `json:"held"` // Holder = Rank
	Used     []Overlap `json:"used"` // User = Rank
}

// ETagCost is one node's verification work: parts hashed, the extra ranged GETs and bytes
// (beyond its shard) it read for them, and the bytes it hashed for the cross-checks.
type ETagCost struct {
	Parts         int
	ExtraRequests int64
	ExtraBytes    int64
	CrossBytes    int64
}

// ByteRange returns the bytes [start, end) of an object of size bytes whose parts node i of n
// hashes: its owned slots' cells, node 0's from byte 0, node n−1's to the end.
func ByteRange(l chash.Layout, i, n int, size int64) (start, end int64) {
	lo, hi := Cut(i, n, l.Capacity)
	cb := int64(l.CellBytes)
	start, end = chash.HeaderSize+int64(lo)*cb, chash.HeaderSize+int64(hi)*cb
	if i == 0 {
		start = 0
	}
	if i == n-1 {
		end = size
	}
	return start, end
}

// span is a byte interval [a, b).
type span struct{ a, b int64 }

func (s span) and(o span) span { return span{max(s.a, o.a), min(s.b, o.b)} }
func (s span) empty() bool     { return s.a >= s.b }

// usedSpan is the bytes node i hashes for the ETag (the parts starting in its ByteRange), and
// those parts' indices [first, last]; empty (last < first) when no part starts there.
func usedSpan(l chash.Layout, i, n int, t ETag) (s span, first, last int) {
	start, end := ByteRange(l, i, n, t.Size)
	first = int((start + t.PartSize - 1) / t.PartSize)
	last = int((end - 1) / t.PartSize)
	if end <= start || last < first {
		return span{}, first, first - 1
	}
	a, _ := t.part(first)
	_, b := t.part(last)
	return span{a, b}, first, last
}

// heldSpans is the bytes node i of n holds in memory with the given tail, as LoadShard lays its
// cells out: global cells [lo, lo+len) mod C, one span or two when they wrap past C−1.
func heldSpans(l chash.Layout, i, n int, tail uint64) []span {
	c := l.Capacity
	lo, hi := Cut(i, n, c)
	length := hi - lo + tail
	if n == 1 || tail >= c-(hi-lo) {
		length = c
	}
	cb := int64(l.CellBytes)
	first := min(length, c-lo)
	out := []span{{chash.HeaderSize + int64(lo)*cb, chash.HeaderSize + int64(lo+first)*cb}}
	if rest := length - first; rest > 0 {
		out = append(out, span{chash.HeaderSize, chash.HeaderSize + int64(rest)*cb})
	}
	return out
}

// HeaderBytes is the 32-byte hash.k2d header of h: four uint64 LE, the bytes ParseHeader read.
func HeaderBytes(h chash.Header) []byte {
	b := make([]byte, chash.HeaderSize)
	le := binary.LittleEndian
	le.PutUint64(b[0:], h.Capacity)
	le.PutUint64(b[8:], h.Size)
	le.PutUint64(b[16:], h.KeyBits)
	le.PutUint64(b[24:], h.ValueBits)
	return b
}

// piece is a run of the object's bytes held in buf from file offset off.
type piece struct {
	off int64
	buf []byte
}

// md5Over hashes the bytes [s.a, s.b) from pieces (disjoint, in file order), and fails if they
// do not cover it.
func md5Over(s span, pieces []piece) (string, error) {
	h := md5.New()
	at := s.a
	for _, p := range pieces {
		x := s.and(span{p.off, p.off + int64(len(p.buf))})
		if x.empty() {
			continue
		}
		if x.a != at {
			break
		}
		h.Write(p.buf[x.a-p.off : x.b-p.off])
		at = x.b
	}
	if at != s.b {
		return "", fmt.Errorf("engine: etag: bytes [%d,%d) not all held (stop at %d)", s.a, s.b, at)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// HashParts computes this shard's record of the check against t (see the package comment):
// the md5 of every part that starts in the shard's byte range, from the shard's cells, header
// (the 32 bytes the node parsed), and one ranged GET through src of whatever its last part has
// past the shard's cells; and the cross-check digests, for which every node must have loaded
// with the same tail. workers <= 0 uses GOMAXPROCS goroutines.
func (s *Shard) HashParts(ctx context.Context, t ETag, header []byte, src rangeread.Source, tail uint64, workers int) (PartDigests, ETagCost, error) {
	d := PartDigests{Rank: s.Index, PartSize: t.PartSize, Parts: t.Parts, MD5: []string{},
		Held: []Overlap{}, Used: []Overlap{}}
	var cost ETagCost
	if len(header) != chash.HeaderSize {
		return d, cost, fmt.Errorf("engine: etag: %d header bytes", len(header))
	}
	hs := md5.Sum(header)
	d.Header = hex.EncodeToString(hs[:])
	l, c := s.Layout, s.Layout.Capacity
	cb := int64(l.CellBytes)
	if want := chash.HeaderSize + int64(c)*cb; want != t.Size {
		return d, cost, fmt.Errorf("engine: etag: object is %d bytes, the table %d", t.Size, want)
	}
	held := heldSpans(l, s.Index, s.N, tail)
	cells := s.region.Bytes()
	var heldLen int64
	for _, h := range held {
		heldLen += h.b - h.a
	}
	if int64(len(cells)) != int64(s.Len)*cb || heldLen != int64(len(cells)) || held[0].a != chash.HeaderSize+int64(s.Lo)*cb {
		return d, cost, fmt.Errorf("engine: etag: shard %d/%d holds %d cells from %d; tail %d gives %v",
			s.Index, s.N, s.Len, s.Lo, tail, held)
	}
	// Memory: the first segment, then (wrapped) the rest from slot 0.
	seg := piece{held[0].a, cells[:held[0].b-held[0].a]}
	mem := []piece{seg}
	if len(held) == 2 {
		mem = []piece{{held[1].a, cells[len(seg.buf):]}, seg} // file order
	}
	used, first, last := usedSpan(l, s.Index, s.N, t)
	d.First = first
	// What the used bytes have past the first segment: one ranged GET.
	var rem []byte
	if !used.empty() && used.b > held[0].b {
		rem = make([]byte, used.b-held[0].b)
		if err := src.ReadRange(ctx, held[0].b, rem); err != nil {
			return d, cost, fmt.Errorf("engine: etag: read bytes [%d,%d) of part %d: %w", held[0].b, used.b, last+1, err)
		}
		cost.ExtraRequests, cost.ExtraBytes = 1, int64(len(rem))
	}
	usedFrom := []piece{{0, header}, seg, {held[0].b, rem}}

	// Cross-checks: my memory over others' used bytes; my used bytes over others' memory.
	for r := 0; r < s.N; r++ {
		if r == s.Index {
			continue
		}
		u, _, _ := usedSpan(l, r, s.N, t)
		for _, h := range held {
			if x := h.and(u); !x.empty() {
				m, err := md5Over(x, mem)
				if err != nil {
					return d, cost, err
				}
				d.Held = append(d.Held, Overlap{s.Index, r, x.a, x.b - x.a, m})
				cost.CrossBytes += x.b - x.a
			}
		}
		if used.empty() {
			continue
		}
		for _, h := range heldSpans(l, r, s.N, tail) {
			if x := h.and(used); !x.empty() {
				m, err := md5Over(x, usedFrom)
				if err != nil {
					return d, cost, err
				}
				d.Used = append(d.Used, Overlap{r, s.Index, x.a, x.b - x.a, m})
				cost.CrossBytes += x.b - x.a
			}
		}
	}
	if used.empty() {
		return d, cost, nil
	}

	n := last - first + 1
	d.MD5 = make([]string, n)
	if workers <= 0 {
		workers = runtime.GOMAXPROCS(0)
	}
	next := make(chan int)
	errs := make([]error, n)
	var wg sync.WaitGroup
	for range min(workers, n) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range next {
				if ctx.Err() == nil {
					a, b := t.part(first + j)
					d.MD5[j], errs[j] = md5Over(span{a, b}, usedFrom)
				}
			}
		}()
	}
	for j := 0; j < n; j++ {
		next <- j
	}
	close(next)
	wg.Wait()
	if err := ctx.Err(); err != nil {
		return d, cost, err
	}
	if err := errors.Join(errs...); err != nil {
		return d, cost, err
	}
	cost.Parts = n
	return d, cost, nil
}

// Combine checks every node's record, nodes[i] being rank i's: each part hashed exactly once,
// every cross-check present on both sides and equal, every header equal to rank 0's, then the
// ETag recomputed. It returns the computed ETag; a mismatch is ErrETagMismatch.
func (t ETag) Combine(nodes []PartDigests) (string, error) {
	sums := make([][]byte, t.Parts)
	type key struct {
		holder, user int
		off, n       int64
	}
	cross := map[key]*[2]string{} // held, used
	put := func(o Overlap, side int, rank int) error {
		k := key{o.Holder, o.User, o.Off, o.Len}
		p := cross[k]
		if p == nil {
			p = &[2]string{}
			cross[k] = p
		}
		if p[side] != "" {
			return fmt.Errorf("engine: etag: rank %d: cross-check %+v given twice", rank, k)
		}
		p[side] = o.MD5
		return nil
	}
	for r, d := range nodes {
		if d.Rank != r {
			return "", fmt.Errorf("engine: etag: record %d is rank %d's", r, d.Rank)
		}
		if d.PartSize != t.PartSize || d.Parts != t.Parts {
			return "", fmt.Errorf("engine: etag: rank %d hashed %d parts of %d bytes; the ETag %s has %d of %d",
				r, d.Parts, d.PartSize, t.Raw, t.Parts, t.PartSize)
		}
		if d.Header != nodes[0].Header {
			return "", fmt.Errorf("%w: rank %d parsed a different header from rank 0's", ErrETagMismatch, r)
		}
		for j, x := range d.MD5 {
			k := d.First + j
			if k < 0 || k >= t.Parts {
				return "", fmt.Errorf("engine: etag: rank %d hashed part %d of %d", r, k+1, t.Parts)
			}
			if sums[k] != nil {
				return "", fmt.Errorf("engine: etag: part %d hashed twice", k+1)
			}
			b, err := hex.DecodeString(x)
			if err != nil || len(b) != md5.Size {
				return "", fmt.Errorf("engine: etag: rank %d part %d: digest %q", r, k+1, x)
			}
			sums[k] = b
		}
		for _, o := range d.Held {
			if o.Holder != r || o.User == r {
				return "", fmt.Errorf("engine: etag: rank %d published a held check for holder %d, user %d", r, o.Holder, o.User)
			}
			if err := put(o, 0, r); err != nil {
				return "", err
			}
		}
		for _, o := range d.Used {
			if o.User != r || o.Holder == r {
				return "", fmt.Errorf("engine: etag: rank %d published a used check for holder %d, user %d", r, o.Holder, o.User)
			}
			if err := put(o, 1, r); err != nil {
				return "", err
			}
		}
	}
	for k, b := range sums {
		if b == nil {
			return "", fmt.Errorf("engine: etag: part %d of %d was not hashed", k+1, t.Parts)
		}
	}
	for k, p := range cross {
		switch {
		case p[0] == "" || p[1] == "":
			return "", fmt.Errorf("engine: etag: cross-check of bytes [%d,%d) between holder rank %d and user rank %d is one-sided (do all nodes load the same tail?)",
				k.off, k.off+k.n, k.holder, k.user)
		case p[0] != p[1]:
			return "", fmt.Errorf("%w: rank %d's copy of bytes [%d,%d) differs from the copy rank %d hashed for the ETag",
				ErrETagMismatch, k.holder, k.off, k.off+k.n, k.user)
		}
	}
	var got [16]byte
	computed := ""
	if t.Multipart {
		got = md5.Sum(bytes.Join(sums, nil))
		computed = hex.EncodeToString(got[:]) + "-" + strconv.Itoa(t.Parts)
	} else {
		copy(got[:], sums[0])
		computed = hex.EncodeToString(got[:])
	}
	if got != t.Sum {
		return computed, fmt.Errorf("%w: computed %s from the loaded bytes, the ETag is %s", ErrETagMismatch, computed, t.Raw)
	}
	return computed, nil
}
