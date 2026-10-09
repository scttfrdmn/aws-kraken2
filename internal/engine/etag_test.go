package engine

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"errors"
	"fmt"
	"sync/atomic"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
)

// refETag is S3's ETag of img: the plain md5 when partSize is 0, else
// md5(concat(md5(part_i)))-count over partSize-byte parts.
func refETag(img []byte, partSize int) string {
	if partSize == 0 {
		s := md5.Sum(img)
		return hex.EncodeToString(s[:])
	}
	var cat []byte
	n := 0
	for off := 0; off < len(img); off += partSize {
		s := md5.Sum(img[off:min(off+partSize, len(img))])
		cat = append(cat, s[:]...)
		n++
	}
	s := md5.Sum(cat)
	return fmt.Sprintf("%s-%d", hex.EncodeToString(s[:]), n)
}

// countingSource is memSource with request and byte counters.
type countingSource struct {
	memSource
	reqs, bytes atomic.Int64
}

func (c *countingSource) ReadRange(ctx context.Context, off int64, dst []byte) error {
	c.reqs.Add(1)
	c.bytes.Add(int64(len(dst)))
	return c.memSource.ReadRange(ctx, off, dst)
}

// verifyN loads the image src serves as n shards with the given tail, hashes each shard's
// parts of t, and combines them. It returns the combined ETag, the error, and the costs.
func verifyN(t *testing.T, l chash.Layout, src []byte, n int, tail uint64, tag ETag) (string, []ETagCost, error) {
	t.Helper()
	shards, err := loadAll(t, l, src, n, tail)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, s := range shards {
			s.Close()
		}
	}()
	h, err := chash.ParseHeader(src[:chash.HeaderSize])
	if err != nil {
		t.Fatal(err)
	}
	var ds []PartDigests
	var costs []ETagCost
	for _, s := range shards {
		cs := &countingSource{memSource: memSource{src}}
		d, c, err := s.HashParts(context.Background(), tag, HeaderBytes(h), cs, tail, 3)
		if err != nil {
			t.Fatal(err)
		}
		if cs.reqs.Load() != c.ExtraRequests || cs.bytes.Load() != c.ExtraBytes {
			t.Fatalf("shard %d/%d: cost says %d GETs %d bytes, the source saw %d and %d",
				s.Index, n, c.ExtraRequests, c.ExtraBytes, cs.reqs.Load(), cs.bytes.Load())
		}
		if c.ExtraRequests > 1 {
			t.Fatalf("shard %d/%d: %d extra GETs", s.Index, n, c.ExtraRequests)
		}
		if c.ExtraBytes >= tag.PartSize && tag.Multipart {
			t.Fatalf("shard %d/%d: %d extra bytes, part size %d", s.Index, n, c.ExtraBytes, tag.PartSize)
		}
		ds = append(ds, d)
		costs = append(costs, c)
	}
	got, err := tag.Combine(ds)
	return got, costs, err
}

func etagTable(t *testing.T, capacity, keyBits, valueBits uint64, fill float64, seed uint64) (chash.Layout, []uint64, []byte) {
	t.Helper()
	l := layout(t, capacity, keyBits, valueBits)
	cells, _ := synth(t, l, int(float64(capacity)*fill), seed)
	return l, cells, image(l, cells)
}

// TestETagShards: N = 1, 2, 3 (and more) over 4- and 5-byte cells, multipart ETags with part
// sizes that do and do not align with cells or shard boundaries, and single-part ETags. The
// combined ETag must equal S3's computed over the image, so every part is hashed exactly once
// and the overlap tails (and the last shard's wrapped tail) are not double counted.
func TestETagShards(t *testing.T) {
	for _, tc := range []struct {
		name        string
		cap, kb, vb uint64
		fill        float64
		parts       []int // 0 = single part
	}{
		{"32-bit", 3001, 12, 20, 0.7, []int{0, 1000, 777, 4096, 12036, 12037, 64, 5}},
		{"40-bit", 2003, 16, 24, 0.7, []int{0, 1000, 333, 10047, 4}},
	} {
		l, cells, img := etagTable(t, tc.cap, tc.kb, tc.vb, tc.fill, 7)
		for _, n := range []int{1, 2, 3, 4, 7} {
			tail := neededTail(l, cells, n)
			for _, ps := range tc.parts {
				want := refETag(img, ps)
				// Part sizes below 1 MiB are given, as etagcheck.py's --part-bytes.
				tag, err := ParseETagParts(want, int64(len(img)), int64(ps))
				if err != nil {
					t.Fatal(err)
				}
				got, costs, err := verifyN(t, l, img, n, tail, tag)
				if err != nil || got != want {
					t.Fatalf("%s N=%d tail=%d part=%d: got %q, %v; want %s", tc.name, n, tail, ps, got, err, want)
				}
				hashed := 0
				for _, c := range costs {
					hashed += c.Parts
				}
				if hashed != tag.Parts {
					t.Fatalf("%s N=%d part=%d: %d parts hashed of %d", tc.name, n, ps, hashed, tag.Parts)
				}
			}
		}
	}
}

// TestETagInferred: a multipart ETag with 1 MiB parts, inferred as etagcheck.py does, at N = 1,
// 2 and 3; the last shard's tail wraps to slot 0.
func TestETagInferred(t *testing.T) {
	l, cells, img := etagTable(t, 1<<20+4099, 12, 20, 0.7, 11)
	want := refETag(img, 1<<20)
	tag, err := ParseETag(`"`+want+`"`, int64(len(img)))
	if err != nil || tag.PartSize != 1<<20 || tag.Parts != 5 {
		t.Fatalf("ParseETag(%s) = %+v, %v", want, tag, err)
	}
	for _, n := range []int{1, 2, 3} {
		tail := max(neededTail(l, cells, n), 1)
		if n > 1 {
			lo, _ := Cut(n-1, n, l.Capacity)
			// It owns [lo, C) and holds tail cells past C−1, from slot 0: unless the tail makes
			// it Full (tail >= lo), its held cells wrap.
			if tail >= lo {
				t.Fatalf("N=%d: the last shard holds the whole table, no wrap", n)
			}
		}
		got, costs, err := verifyN(t, l, img, n, tail, tag)
		if err != nil || got != want {
			t.Fatalf("N=%d: got %q, %v; want %s", n, got, err, want)
		}
		if n > 1 && costs[n-1].ExtraRequests != 0 {
			t.Fatalf("N=%d: the last shard fetched %d bytes", n, costs[n-1].ExtraBytes)
		}
	}
}

// TestETagCorruption: one byte changed in the object (the header, a shard boundary's tail,
// bytes fetched past a shard, the last byte) fails the check at every N, single- and multipart.
func TestETagCorruption(t *testing.T) {
	l, cells, img := etagTable(t, 3001, 12, 20, 0.7, 3)
	for _, ps := range []int{0, 1000, 4096} {
		want := refETag(img, ps)
		tag, err := ParseETagParts(want, int64(len(img)), int64(ps))
		if err != nil {
			t.Fatal(err)
		}
		for _, n := range []int{1, 2, 3} {
			tail := neededTail(l, cells, n)
			_, hi := Cut(0, n, l.Capacity)
			// Byte 3 of a cell holds key bits only (20 value bits), so the flip leaves empty
			// cells empty and the tail check passes; header byte 8 is the low byte of the size.
			cell3 := func(off int) int { return chash.HeaderSize + (off-chash.HeaderSize)/4*4 + 3 }
			offs := []int{8, cell3(chash.HeaderSize + int(hi)*4), cell3(chash.HeaderSize + int(hi+1)*4),
				cell3(len(img) / 2), len(img) - 1}
			for _, off := range offs {
				if off >= len(img) {
					continue
				}
				bad := append([]byte(nil), img...)
				bad[off] ^= 0x01
				_, _, err := verifyN(t, l, bad, n, tail, tag)
				if !errors.Is(err, ErrETagMismatch) {
					t.Fatalf("part=%d N=%d byte %d corrupted: %v", ps, n, off, err)
				}
			}
		}
	}
}

// TestETagCombineCoverage: a missing or twice-hashed part, a one-sided or differing cross-check,
// or a different header is an error, not a pass.
func TestETagCombineCoverage(t *testing.T) {
	tag := ETag{Multipart: true, Parts: 3, PartSize: 10, Size: 25}
	zero := hex.EncodeToString(make([]byte, 16))
	d := func(rank, first, n int) PartDigests {
		p := PartDigests{Rank: rank, PartSize: 10, Parts: 3, First: first, Header: "h"}
		for range n {
			p.MD5 = append(p.MD5, zero)
		}
		return p
	}
	for _, ds := range [][]PartDigests{{d(0, 0, 1), d(1, 2, 1)}, {d(0, 0, 2), d(1, 1, 2)}, {d(0, 0, 4)}, {d(1, 0, 3)}} {
		if _, err := tag.Combine(ds); err == nil || errors.Is(err, ErrETagMismatch) {
			t.Fatalf("%+v: %v", ds, err)
		}
	}
	if _, err := tag.Combine([]PartDigests{d(0, 0, 3)}); !errors.Is(err, ErrETagMismatch) {
		t.Fatalf("full coverage of wrong digests: %v", err)
	}
	a, b := d(0, 0, 2), d(1, 2, 1)
	b.Held = []Overlap{{Holder: 1, User: 0, Off: 15, Len: 5, MD5: "x"}}
	if _, err := tag.Combine([]PartDigests{a, b}); err == nil || errors.Is(err, ErrETagMismatch) {
		t.Fatalf("one-sided cross-check: %v", err)
	}
	a.Used = []Overlap{{Holder: 1, User: 0, Off: 15, Len: 5, MD5: "y"}}
	if _, err := tag.Combine([]PartDigests{a, b}); !errors.Is(err, ErrETagMismatch) {
		t.Fatalf("differing cross-check: %v", err)
	}
	b.Held[0].MD5, b.Header = "y", "other"
	if _, err := tag.Combine([]PartDigests{a, b}); !errors.Is(err, ErrETagMismatch) {
		t.Fatalf("different header: %v", err)
	}
}

// memCheck loads src as n shards, hashes them all once, then for every byte position (stride
// apart) of every shard's memory flips that byte in memory only, re-hashes that shard, and
// requires Combine to fail with ErrETagMismatch: every byte any node holds is covered.
func memCheck(t *testing.T, l chash.Layout, img []byte, n int, tail uint64, tag ETag, stride int) {
	t.Helper()
	shards, err := loadAll(t, l, img, n, tail)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, s := range shards {
			s.Close()
		}
	}()
	h, _ := chash.ParseHeader(img[:chash.HeaderSize])
	hdr := HeaderBytes(h)
	src := memSource{img}
	ctx := context.Background()
	ds := make([]PartDigests, n)
	for i, s := range shards {
		if ds[i], _, err = s.HashParts(ctx, tag, hdr, src, tail, 2); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tag.Combine(ds); err != nil {
		t.Fatalf("N=%d pristine: %v", n, err)
	}
	for i, s := range shards {
		mem := s.region.Bytes()
		for j := 0; j < len(mem); j += stride {
			mem[j] ^= 0x10
			d, _, err := s.HashParts(ctx, tag, hdr, src, tail, 2)
			mem[j] ^= 0x10
			if err != nil {
				t.Fatal(err)
			}
			bad := append([]PartDigests(nil), ds...)
			bad[i] = d
			if _, err := tag.Combine(bad); !errors.Is(err, ErrETagMismatch) {
				t.Fatalf("N=%d part=%d tail=%d: byte %d of shard %d's memory (cells from %d, %d held) flipped: %v",
					n, tag.PartSize, tail, j, i, s.Lo, s.Len, err)
			}
		}
	}
}

// TestETagMemoryCorruption: a byte flipped in any shard's memory (owned cells, the head of its
// range that the previous node's last part covers, its overlap tail, the last shard's wrapped
// tail) fails the check, though the object itself is intact. The first case is the review's
// (#49): N = 2, 32-bit cells, 1000-byte parts, file offset 6035 in shard 1's own range.
func TestETagMemoryCorruption(t *testing.T) {
	l, cells, img := etagTable(t, 3001, 12, 20, 0.7, 7)
	tagOf := func(ps int) ETag {
		tag, err := ParseETagParts(refETag(img, ps), int64(len(img)), int64(ps))
		if err != nil {
			t.Fatal(err)
		}
		return tag
	}
	// The review's case, explicitly.
	{
		tail := neededTail(l, cells, 2)
		tag := tagOf(1000)
		shards, err := loadAll(t, l, img, 2, tail)
		if err != nil {
			t.Fatal(err)
		}
		h, _ := chash.ParseHeader(img[:chash.HeaderSize])
		var ds []PartDigests
		for _, s := range shards {
			if s.Index == 1 {
				off := int64(6035) - (chash.HeaderSize + int64(s.Lo)*4)
				if off < 0 {
					t.Fatalf("offset 6035 is not in shard 1 (cells from %d)", s.Lo)
				}
				s.region.Bytes()[off] ^= 0x01
			}
			d, _, err := s.HashParts(context.Background(), tag, HeaderBytes(h), memSource{img}, tail, 2)
			if err != nil {
				t.Fatal(err)
			}
			ds = append(ds, d)
			s.Close()
		}
		if _, err := tag.Combine(ds); !errors.Is(err, ErrETagMismatch) {
			t.Fatalf("review case (N=2, 1000-byte parts, offset 6035 in shard 1's memory): %v", err)
		}
	}
	// Each shard's tail, explicitly: the last byte it holds is its overlap tail's last cell (for
	// the last shard, its wrapped tail's, at the start of the table).
	for _, n := range []int{2, 3} {
		tail := neededTail(l, cells, n) + 3
		tag := tagOf(1000)
		h, _ := chash.ParseHeader(img[:chash.HeaderSize])
		for victim := 0; victim < n; victim++ {
			shards, err := loadAll(t, l, img, n, tail)
			if err != nil {
				t.Fatal(err)
			}
			var ds []PartDigests
			for _, s := range shards {
				if s.Index == victim {
					if s.Full || s.Tail == 0 {
						t.Fatalf("N=%d shard %d has no tail", n, victim)
					}
					mem := s.region.Bytes()
					mem[len(mem)-1] ^= 0x01
				}
				d, _, err := s.HashParts(context.Background(), tag, HeaderBytes(h), memSource{img}, tail, 2)
				if err != nil {
					t.Fatal(err)
				}
				ds = append(ds, d)
				s.Close()
			}
			if _, err := tag.Combine(ds); !errors.Is(err, ErrETagMismatch) {
				t.Fatalf("N=%d: shard %d's last tail cell flipped: %v", n, victim, err)
			}
		}
	}
	for _, n := range []int{2, 3, 4} {
		tail := neededTail(l, cells, n) + 3 // a few cells more, so the tails are not all empty
		for _, ps := range []int{1000, 4096, 777} {
			memCheck(t, l, img, n, tail, tagOf(ps), 1)
		}
		memCheck(t, l, img, n, tail, tagOf(0), 5)
	}
	// Full shards at N > 1: a tail that covers the whole table.
	memCheck(t, l, img, 3, 3001, tagOf(1000), 7)
}

func TestParseETag(t *testing.T) {
	const roda = 1189091671800 // RODA v205 hash.k2d
	tag, err := ParseETag(`"f80959f9556b50d76b3e744afdd3b22a-8860"`, roda)
	if err != nil || tag.PartSize != 128<<20 || tag.Parts != 8860 || !tag.Multipart {
		t.Fatalf("RODA: %+v, %v", tag, err)
	}
	for _, bad := range []string{"", "xyz", "f80959f9556b50d76b3e744afdd3b22a-0", "f80959f9556b50d76b3e744afdd3b22a-3"} {
		if _, err := ParseETag(bad, roda); !errors.Is(err, ErrETagFormat) {
			t.Fatalf("%q: %v", bad, err)
		}
	}
	if _, err := ParseETagParts("f80959f9556b50d76b3e744afdd3b22a-8860", roda, 64<<20); !errors.Is(err, ErrETagFormat) {
		t.Fatalf("wrong given part size: %v", err)
	}
	if tag, err := ParseETagParts("f80959f9556b50d76b3e744afdd3b22a-8860", roda, 134217728); err != nil || tag.PartSize != 128<<20 {
		t.Fatalf("given part size: %+v, %v", tag, err)
	}
	if tag, err := ParseETag("f80959f9556b50d76b3e744afdd3b22a", 100); err != nil || tag.Parts != 1 || tag.PartSize != 100 {
		t.Fatalf("single part: %+v, %v", tag, err)
	}
}
