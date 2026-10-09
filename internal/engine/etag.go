package engine

// ETag verification of the sharded load (#49, AK2_ENGINE_VERIFY_ETAG). An S3 ETag of an object
// uploaded in one part is the md5 of its bytes; of a multipart upload, md5(concat(md5(part_i)))
// followed by "-" and the part count. The part size is not stored, so it is inferred as
// scripts/lib/etagcheck.py does: the smallest power-of-two MiB size (1 MiB to 4 GiB) whose part
// count for the object's size equals the ETag's.
//
// Each node hashes every part that starts in its byte range, by file offset: node i of n owns
// the bytes of its owned slots, [H+Lo·cb, H+Hi·cb), with node 0's range starting at byte 0 (the
// header) and node n−1's ending at the object's size. These ranges partition the object, so each
// part is hashed by exactly one node. A part's bytes come from the shard's first (unwrapped)
// segment, the header, and, for the node's last part only, one extra ranged GET of what lies past
// the segment. The tail's bytes are read through file offsets like any others and so are never
// hashed twice; the wrapped part of the last shard's tail lies past the object's end and is
// never read for the ETag at all. Rank 0 (and, so that every node fails at once, every node)
// combines the digests from the rendezvous records and compares the result with the ETag before
// any sample is classified.

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

// ErrETagMismatch is the verifier's error when the loaded bytes do not give the ETag.
var ErrETagMismatch = errors.New("engine: hash.k2d does not match its ETag")

// ParseETag parses etag (quotes allowed) for an object of size bytes and infers its part size.
func ParseETag(etag string, size int64) (ETag, error) { return ParseETagParts(etag, size, 0) }

// ParseETagParts is ParseETag with the part size given (etagcheck.py's --part-bytes) when
// partBytes > 0, and inferred otherwise.
func ParseETagParts(etag string, size, partBytes int64) (ETag, error) {
	t := ETag{Raw: strings.Trim(strings.TrimSpace(etag), `"`), Size: size}
	if size <= 0 {
		return t, fmt.Errorf("engine: ETag %q: object size %d", t.Raw, size)
	}
	hexSum, count, multi := strings.Cut(t.Raw, "-")
	b, err := hex.DecodeString(hexSum)
	if err != nil || len(b) != md5.Size {
		return t, fmt.Errorf("engine: ETag %q: not an md5 ETag", t.Raw)
	}
	copy(t.Sum[:], b)
	if !multi {
		t.Parts, t.PartSize = 1, size
		return t, nil
	}
	t.Multipart = true
	if t.Parts, err = strconv.Atoi(count); err != nil || t.Parts < 1 || t.Parts > 10000 {
		return t, fmt.Errorf("engine: ETag %q: part count %q", t.Raw, count)
	}
	if partBytes > 0 {
		if (size+partBytes-1)/partBytes != int64(t.Parts) {
			return t, fmt.Errorf("engine: ETag %q: %d-byte parts of %d bytes are not %d parts", t.Raw, partBytes, size, t.Parts)
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
	return t, fmt.Errorf("engine: ETag %q: cannot infer a power-of-two MiB part size giving %d parts of %d bytes",
		t.Raw, t.Parts, size)
}

// part returns part k's bytes [a, b).
func (t ETag) part(k int) (a, b int64) {
	a = int64(k) * t.PartSize
	return a, min(a+t.PartSize, t.Size)
}

// PartDigests are the md5s of the consecutive parts First, First+1, … that one node hashed:
// its rendezvous record's etag_parts. PartSize and Parts restate the layout the node inferred.
type PartDigests struct {
	PartSize int64    `json:"part_bytes"`
	Parts    int      `json:"parts"`
	First    int      `json:"first"`
	MD5      []string `json:"md5"` // hex, part First+j at j
}

// ETagCost is one node's verification work: parts hashed, and the extra ranged GETs and bytes
// (beyond its shard) it read for them.
type ETagCost struct {
	Parts         int
	ExtraRequests int64
	ExtraBytes    int64
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

// HashParts computes the md5 of every part of t that starts in the shard's byte range
// (ByteRange), from the shard's cells, header (the object's first 32 bytes), and one ranged
// GET through src of whatever the node's last part has past the shard's cells. workers <= 0
// uses GOMAXPROCS goroutines.
func (s *Shard) HashParts(ctx context.Context, t ETag, header []byte, src rangeread.Source, workers int) (PartDigests, ETagCost, error) {
	d := PartDigests{PartSize: t.PartSize, Parts: t.Parts}
	var cost ETagCost
	if len(header) != chash.HeaderSize {
		return d, cost, fmt.Errorf("engine: etag: %d header bytes", len(header))
	}
	cb := int64(s.Layout.CellBytes)
	c := s.Layout.Capacity
	if want := chash.HeaderSize + int64(c)*cb; want != t.Size {
		return d, cost, fmt.Errorf("engine: etag: object is %d bytes, the table %d", t.Size, want)
	}
	start, end := ByteRange(s.Layout, s.Index, s.N, t.Size)
	// The parts that start in [start, end).
	first := int((start + t.PartSize - 1) / t.PartSize)
	last := int((end - 1) / t.PartSize) // inclusive; < first when none starts here
	d.First = first
	if end <= start || last < first {
		d.MD5 = []string{}
		return d, cost, nil
	}
	// The shard's first segment: global cells [Lo, Lo+min(Len, C−Lo)), unwrapped.
	cells := s.region.Bytes()
	segOff := chash.HeaderSize + int64(s.Lo)*cb
	segEnd := segOff + int64(min(s.Len, c-s.Lo))*cb
	seg := cells[:segEnd-segOff]
	// What the last part has past the segment: one ranged GET.
	_, lastEnd := t.part(last)
	var rem []byte
	if lastEnd > segEnd {
		rem = make([]byte, lastEnd-segEnd)
		if err := src.ReadRange(ctx, segEnd, rem); err != nil {
			return d, cost, fmt.Errorf("engine: etag: read bytes [%d,%d) of part %d: %w", segEnd, lastEnd, last+1, err)
		}
		cost.ExtraRequests, cost.ExtraBytes = 1, int64(len(rem))
	}
	piece := func(a, b, off int64, src []byte) []byte { // [a,b) ∩ [off, off+len(src))
		lo, hi := max(a, off), min(b, off+int64(len(src)))
		if lo >= hi {
			return nil
		}
		return src[lo-off : hi-off]
	}
	hashPart := func(k int) (string, error) {
		a, b := t.part(k)
		h := md5.New()
		var got int64
		for _, p := range [][]byte{piece(a, b, 0, header), piece(a, b, segOff, seg), piece(a, b, segEnd, rem)} {
			h.Write(p)
			got += int64(len(p))
		}
		if got != b-a { // the three pieces are disjoint and in file order; anything else is a bug
			return "", fmt.Errorf("engine: etag: part %d [%d,%d): shard %d/%d covers %d bytes", k+1, a, b, s.Index, s.N, got)
		}
		return hex.EncodeToString(h.Sum(nil)), nil
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
					d.MD5[j], errs[j] = hashPart(first + j)
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

// Combine assembles every node's digests (one PartDigests per node, in any order) and checks
// them against t: each part hashed exactly once, then the ETag recomputed. It returns the
// computed ETag; a mismatch is ErrETagMismatch.
func (t ETag) Combine(nodes []PartDigests) (string, error) {
	sums := make([][]byte, t.Parts)
	for r, d := range nodes {
		if d.PartSize != t.PartSize || d.Parts != t.Parts {
			return "", fmt.Errorf("engine: etag: node %d hashed %d parts of %d bytes; the ETag %s has %d of %d",
				r, d.Parts, d.PartSize, t.Raw, t.Parts, t.PartSize)
		}
		for j, x := range d.MD5 {
			k := d.First + j
			if k < 0 || k >= t.Parts {
				return "", fmt.Errorf("engine: etag: node %d hashed part %d of %d", r, k+1, t.Parts)
			}
			if sums[k] != nil {
				return "", fmt.Errorf("engine: etag: part %d hashed twice", k+1)
			}
			b, err := hex.DecodeString(x)
			if err != nil || len(b) != md5.Size {
				return "", fmt.Errorf("engine: etag: node %d part %d: digest %q", r, k+1, x)
			}
			sums[k] = b
		}
	}
	for k, b := range sums {
		if b == nil {
			return "", fmt.Errorf("engine: etag: part %d of %d was not hashed", k+1, t.Parts)
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
