package engine

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"math/rand/v2"
	"net"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

// memSource is a rangeread.Source over an image in memory.
type memSource struct{ b []byte }

func (m memSource) ReadRange(_ context.Context, off int64, dst []byte) error {
	if off < 0 || off+int64(len(dst)) > int64(len(m.b)) {
		return errors.New("memSource: out of range")
	}
	copy(dst, m.b[off:])
	return nil
}

// cellOf encodes a cell (upstream's Cell::populate) for 4- or 5-byte layouts.
func cellOf(l chash.Layout, compacted uint64, val uint32) uint64 {
	vm := uint32(1)<<l.ValueBits - 1
	if l.CellBytes == 4 {
		return uint64(uint32(compacted<<l.ValueBits) | val)
	}
	aBits := 32 - l.ValueBits
	b := uint64(uint8(compacted >> aBits))
	a := uint32((compacted&(uint64(1)<<aBits-1))<<l.ValueBits) | (val & vm)
	return uint64(a) | b<<32
}

// image serialises cells into a hash.k2d image.
func image(l chash.Layout, cells []uint64) []byte {
	img := make([]byte, chash.HeaderSize+len(cells)*l.CellBytes)
	var size uint64
	vm := uint64(1)<<l.ValueBits - 1
	for _, c := range cells {
		if c&vm != 0 {
			size++
		}
	}
	le := binary.LittleEndian
	le.PutUint64(img[0:], uint64(len(cells)))
	le.PutUint64(img[8:], size)
	le.PutUint64(img[16:], uint64(l.KeyBits))
	le.PutUint64(img[24:], uint64(l.ValueBits))
	var tmp [8]byte
	for i, c := range cells {
		le.PutUint64(tmp[:], c)
		copy(img[chash.HeaderSize+i*l.CellBytes:], tmp[:l.CellBytes])
	}
	return img
}

func layout(t testing.TB, capacity, keyBits, valueBits uint64) chash.Layout {
	t.Helper()
	l, err := chash.Header{Capacity: capacity, KeyBits: keyBits, ValueBits: valueBits}.Layout()
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// synth inserts n random keys by linear probing (upstream's CompareAndSet with
// -DLINEAR_PROBING) and returns the cells and the keys.
func synth(t testing.TB, l chash.Layout, n int, seed uint64) ([]uint64, []uint64) {
	t.Helper()
	cells := make([]uint64, l.Capacity)
	r := rand.New(rand.NewPCG(seed, 7))
	vm := uint64(1)<<l.ValueBits - 1
	var keys []uint64
	for range n {
		key := r.Uint64() >> 1
		val := uint32(r.Uint64N(vm)) + 1
		hc := chash.MurmurHash3(key)
		ck := hc >> (64 - l.KeyBits)
		idx := hc % l.Capacity
		first := idx
		for {
			k, v := l.Decode(cells[idx])
			if v == 0 || k == ck {
				cells[idx] = cellOf(l, ck, val)
				break
			}
			idx = (idx + 1) % l.Capacity
			if idx == first {
				t.Fatal("synthetic table full")
			}
		}
		keys = append(keys, key)
	}
	return cells, keys
}

// neededTail is G0c's tail for shard count n (docs/g0c.md): the maximum over the shards'
// end boundaries b of 0 if slot b−1 is empty, else the occupied cells from b on plus the
// empty one that stops a miss.
func neededTail(l chash.Layout, cells []uint64, n int) uint64 {
	c := l.Capacity
	occ := func(i uint64) bool { _, v := l.Decode(cells[i%c]); return v != 0 }
	var worst uint64
	for i := 0; i < n; i++ {
		lo, b := Cut(i, n, c)
		if b == lo || !occ(b-1) {
			continue
		}
		var run uint64
		for run < c && occ(b+run) {
			run++
		}
		worst = max(worst, run+1)
	}
	return worst
}

func loadAll(t testing.TB, l chash.Layout, img []byte, n int, tail uint64) ([]*Shard, error) {
	t.Helper()
	var out []*Shard
	for i := 0; i < n; i++ {
		s, err := LoadShard(context.Background(), l, i, n, tail, RangeFiller{Src: memSource{img}, Chunk: 13, Workers: 3})
		if err != nil {
			for _, s := range out {
				s.Close()
			}
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

func localRouter(shards []*Shard) *Router {
	cl := make([]Client, len(shards))
	for i, s := range shards {
		cl[i] = LocalClient{S: s}
	}
	return NewRouter(shards[0].Layout.Capacity, cl)
}

// checkRouter compares every key (and a set of misses) through r with chash.Table.Get.
func checkRouter(t *testing.T, r *Router, tab *chash.Table, keys []uint64, seed uint64) {
	t.Helper()
	q := append([]uint64(nil), keys...)
	rng := rand.New(rand.NewPCG(seed, 99))
	for range len(keys) + 64 {
		q = append(q, rng.Uint64())
	}
	rng.Shuffle(len(q), func(i, j int) { q[i], q[j] = q[j], q[i] })
	var s RouteScratch
	for start := 0; start < len(q); start += 97 { // several calls, reusing the scratch
		part := q[start:min(start+97, len(q))]
		got, err := r.Lookup(part, nil, &s)
		if err != nil {
			t.Fatal(err)
		}
		for i, k := range part {
			if want, _ := tab.Get(k); got[i] != want {
				t.Fatalf("N=%d key %x: router %d, table %d", r.N, k, got[i], want)
			}
		}
	}
}

func TestCutOwner(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	cs := []uint64{1, 2, 3, 7, 10, 64, 1000, 297272917942, 1<<63 + 12345}
	for _, c := range cs {
		for _, n := range []int{1, 2, 3, 4, 5, 7, 8, 13, 16, 64} {
			var prev uint64
			for i := 0; i < n; i++ {
				lo, hi := Cut(i, n, c)
				if lo != prev || hi < lo {
					t.Fatalf("C=%d N=%d shard %d: [%d,%d) after %d", c, n, i, lo, hi, prev)
				}
				prev = hi
			}
			if prev != c {
				t.Fatalf("C=%d N=%d: cuts end at %d", c, n, prev)
			}
			check := func(s uint64) {
				o := Owner(s, n, c)
				lo, hi := Cut(o, n, c)
				if o < 0 || o >= n || s < lo || s >= hi {
					t.Fatalf("C=%d N=%d: Owner(%d) = %d owning [%d,%d)", c, n, s, o, lo, hi)
				}
			}
			for i := 0; i < n; i++ { // every boundary and its neighbours
				lo, hi := Cut(i, n, c)
				for _, s := range []uint64{lo, lo + 1, hi - 1, hi} {
					if s < c && (s >= lo || lo == 0) {
						check(s)
					}
				}
			}
			for range 200 {
				check(rng.Uint64N(c))
			}
		}
	}
}

// TestShardsMatchTable: on random linear-probed tables, 32- and 40-bit, at a high load so long
// runs and a wrapped run occur, the sharded lookup equals the whole table's for every N, with
// exactly the tail G0c's definition gives; one cell less is refused at load.
func TestShardsMatchTable(t *testing.T) {
	var cells40, longTails, wrapped int
	defer func() {
		// The cases must reach what they are for (Law 4).
		if cells40 == 0 || longTails == 0 || wrapped == 0 {
			t.Errorf("coverage: 40-bit cases %d, tails >= 8 cells %d, wrapped last-shard runs %d", cells40, longTails, wrapped)
		}
	}()
	for _, tc := range []struct {
		c, kb, vb uint64
		n         int
	}{
		{1009, 22, 10, 900}, {4096, 20, 12, 3600}, {2003, 30, 10, 1700}, {777, 25, 15, 700},
	} {
		l := layout(t, tc.c, tc.kb, tc.vb)
		if l.CellBytes == 5 {
			cells40++
		}
		for seed := uint64(0); seed < 3; seed++ {
			cells, keys := synth(t, l, tc.n, seed)
			img := image(l, cells)
			tab, err := chash.FromBytes(img, chash.Linear)
			if err != nil {
				t.Fatal(err)
			}
			for _, n := range []int{1, 2, 3, 4, 5, 7, 8, 16} {
				tail := neededTail(l, cells, n)
				if tail >= 8 {
					longTails++
				}
				if _, v0 := l.Decode(cells[0]); v0 != 0 {
					if _, vl := l.Decode(cells[l.Capacity-1]); vl != 0 && n > 1 {
						wrapped++
					}
				}
				shards, err := loadAll(t, l, img, n, tail)
				if err != nil {
					t.Fatalf("C=%d cells=%d N=%d tail %d: %v", tc.c, l.CellBytes, n, tail, err)
				}
				checkRouter(t, localRouter(shards), tab, keys, seed)
				for _, s := range shards {
					s.Close()
				}
				if n > 1 && tail > 0 {
					if _, err := loadAll(t, l, img, n, tail-1); !errors.Is(err, ErrTailTooShort) {
						t.Fatalf("C=%d N=%d tail %d-1: err %v, want ErrTailTooShort", tc.c, n, tail, err)
					}
				}
			}
		}
	}
}

// handTable builds a 32-bit table of capacity c whose occupied cells are listed; each holds a
// distinct compacted key that no lookup below matches, unless it is in keyed.
func handTable(t *testing.T, c uint64, occupied []uint64) (chash.Layout, []uint64) {
	l := layout(t, c, 22, 10)
	cells := make([]uint64, c)
	for i, s := range occupied {
		cells[s] = cellOf(l, uint64(0x3fff00+i), uint32(i+1))
	}
	return l, cells
}

// keyWithSlot finds a key whose home slot is s.
func keyWithSlot(c, s uint64) uint64 {
	for k := uint64(1); ; k++ {
		if chash.MurmurHash3(k)%c == s {
			return k
		}
	}
}

// TestBoundaryAndWrap: probes that end exactly at a shard boundary, that cross it into the
// tail, and that wrap from the last slot to slot 0 in the last shard's tail.
func TestBoundaryAndWrap(t *testing.T) {
	const c = 40 // N=2: [0,20) [20,40); N=4: [0,10) [10,20) [20,30) [30,40)
	// Run 15..19 ends at the N=2 boundary: slot 19 occupied, 20 empty. A miss from 15 reads
	// 15..20, one cell past the boundary: tail 1, and tail 0 is refused.
	// Run 36..39,0..2 wraps: a miss from 36 reads 36..39 and 0..3 (tail 4 for the last shard).
	// Slot 9 is empty, so shard 0 of N=4 needs no tail (a probe ending exactly at its last slot).
	occ := []uint64{15, 16, 17, 18, 19, 36, 37, 38, 39, 0, 1, 2, 5, 6, 7, 8}
	l, cells := handTable(t, c, occ)
	img := image(l, cells)
	tab, err := chash.FromBytes(img, chash.Linear)
	if err != nil {
		t.Fatal(err)
	}
	if got := neededTail(l, cells, 2); got != 4 {
		t.Fatalf("N=2 needed tail %d, want 4 (the wrap)", got)
	}
	var keys []uint64
	for s := uint64(0); s < c; s++ {
		keys = append(keys, keyWithSlot(c, s))
	}
	for _, n := range []int{1, 2, 3, 4, 8} {
		tail := neededTail(l, cells, n)
		shards, err := loadAll(t, l, img, n, tail)
		if err != nil {
			t.Fatalf("N=%d tail %d: %v", n, tail, err)
		}
		checkRouter(t, localRouter(shards), tab, keys, 5)
		if n == 2 && (shards[0].TailProbes.Load() == 0 || shards[1].WrapProbes.Load() == 0 || shards[0].WrapProbes.Load() != 0) {
			t.Fatalf("N=2 tail probes: shard 0 %d (wrapped %d), shard 1 wrapped %d", shards[0].TailProbes.Load(),
				shards[0].WrapProbes.Load(), shards[1].WrapProbes.Load())
		}
		if n == 4 && shards[0].Empty != 9 {
			t.Fatalf("N=4 shard 0: first empty at local %d, want 9 (its own last slot)", shards[0].Empty)
		}
		for _, s := range shards {
			s.Close()
		}
	}
	// The boundary run alone: shard 0 of N=2 needs exactly one tail cell.
	l, cells = handTable(t, c, []uint64{15, 16, 17, 18, 19})
	img = image(l, cells)
	if _, err := LoadShard(context.Background(), l, 0, 2, 0, RangeFiller{Src: memSource{img}}); !errors.Is(err, ErrTailTooShort) {
		t.Fatalf("tail 0 past an occupied boundary slot: %v", err)
	}
	s, err := LoadShard(context.Background(), l, 0, 2, 1, RangeFiller{Src: memSource{img}})
	if err != nil {
		t.Fatal(err)
	}
	if s.Empty != 20 || s.Len != 21 {
		t.Fatalf("shard 0: empty at %d of %d, want 20 of 21", s.Empty, s.Len)
	}
	var v [1]uint32
	if err := s.LookupBatch([]uint64{chash.MurmurHash3(keyWithSlot(c, 15))}, v[:]); err != nil || v[0] != 0 {
		t.Fatalf("miss from slot 15: %d, %v", v[0], err)
	}
	// A slot the shard does not own is an error, not a lookup.
	if err := s.LookupBatch([]uint64{chash.MurmurHash3(keyWithSlot(c, 25))}, v[:]); err == nil {
		t.Fatal("shard 0 answered for slot 25")
	}
	s.Close()
}

// TestFullTable: with no empty cell a probe stops on the full wrap (N=1, or a tail reaching
// the whole table), and a partial shard cannot be verified.
func TestFullTable(t *testing.T) {
	const c = 12
	var all []uint64
	for s := uint64(0); s < c; s++ {
		all = append(all, s)
	}
	l, cells := handTable(t, c, all)
	img := image(l, cells)
	tab, err := chash.FromBytes(img, chash.Linear)
	if err != nil {
		t.Fatal(err)
	}
	var keys []uint64
	for s := uint64(0); s < c; s++ {
		keys = append(keys, keyWithSlot(c, s))
	}
	sh, err := loadAll(t, l, img, 1, 0)
	if err != nil {
		t.Fatal(err)
	}
	checkRouter(t, localRouter(sh), tab, keys, 1)
	if _, err := loadAll(t, l, img, 3, 5); !errors.Is(err, ErrTailTooShort) {
		t.Fatalf("N=3 on a full table: %v", err)
	}
	// A tail as long as the rest of the table makes each shard hold all of it.
	sh, err = loadAll(t, l, img, 3, c)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range sh {
		if !s.Full {
			t.Fatalf("shard %d not full", s.Index)
		}
	}
	checkRouter(t, localRouter(sh), tab, keys, 2)
}

func TestFillCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	l := layout(t, 1000, 22, 10)
	img := image(l, make([]uint64, 1000))
	_, err := LoadShard(ctx, l, 0, 2, 10, RangeFiller{Src: ctxSource{memSource{img}}, Chunk: 16})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled load: %v", err)
	}
}

type ctxSource struct{ memSource }

func (s ctxSource) ReadRange(ctx context.Context, off int64, dst []byte) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return s.memSource.ReadRange(ctx, off, dst)
}

func TestReadLayout(t *testing.T) {
	l := layout(t, 100, 22, 10)
	img := image(l, make([]uint64, 100))
	if _, got, err := ReadLayout(context.Background(), memSource{img}, int64(len(img))); err != nil || got != l {
		t.Fatalf("layout %+v, %v", got, err)
	}
	if _, _, err := ReadLayout(context.Background(), memSource{img}, int64(len(img))+1); err == nil {
		t.Fatal("size mismatch accepted")
	}
}

// TestTCP: the same lookups over loopback TCP, and hellos that do not match are refused.
func TestTCP(t *testing.T) {
	l := layout(t, 4096, 20, 12)
	cells, keys := synth(t, l, 3500, 11)
	img := image(l, cells)
	tab, err := chash.FromBytes(img, chash.Linear)
	if err != nil {
		t.Fatal(err)
	}
	const n, run = 3, 0xfeed
	shards, err := loadAll(t, l, img, n, neededTail(l, cells, n))
	if err != nil {
		t.Fatal(err)
	}
	var servers []*Server
	var clients []Client
	var addrs []string
	for _, s := range shards {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		srv := &Server{Shard: s, Run: run}
		go srv.Serve(ln)
		servers = append(servers, srv)
		addrs = append(addrs, ln.Addr().String())
	}
	for i, a := range addrs {
		c, err := DialTCP(a, i, n, l.Capacity, run, 4)
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		clients = append(clients, c)
	}
	r := NewRouter(l.Capacity, clients)
	checkRouter(t, r, tab, keys, 3)
	var got int64
	for _, s := range servers {
		got += s.Stats.Keys.Load()
	}
	if got != r.Stats.Keys.Load() {
		t.Fatalf("servers saw %d keys, router sent %d", got, r.Stats.Keys.Load())
	}
	for _, bad := range []struct {
		shard, n int
		cap, run uint64
	}{{1, n, l.Capacity, run}, {0, 4, l.Capacity, run}, {0, n, l.Capacity + 1, run}, {0, n, l.Capacity, run + 1}} {
		if _, err := DialTCP(addrs[0], bad.shard, bad.n, bad.cap, bad.run, 1); err == nil {
			t.Fatalf("hello %+v accepted by shard 0", bad)
		}
	}
	// A key the server does not own fails the call with the server's message.
	var v [1]uint32
	err = clients[0].Lookup([]uint64{chash.MurmurHash3(keyWithSlot(l.Capacity, l.Capacity-1))}, v[:])
	if err == nil || !bytes.Contains([]byte(err.Error()), []byte("asked for slot")) {
		t.Fatalf("misrouted key: %v", err)
	}
	for _, s := range servers {
		s.Close()
	}
	for _, s := range shards {
		s.Close()
	}
}

var _ rangeread.Source = memSource{}
