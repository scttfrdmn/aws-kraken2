package engine

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
)

// Router sends each lookup to the shard that owns its home slot and gathers the values back in
// the caller's order. It holds no lock: each caller brings its own RouteScratch, and the
// clients are safe for concurrent use.
type Router struct {
	N        int
	Capacity uint64
	Clients  []Client // Clients[i] reaches shard i

	Stats RouteStats
}

// RouteStats are a router's counters, summed over callers.
type RouteStats struct {
	Calls     atomic.Int64 // Lookup calls (one per input block)
	Keys      atomic.Int64
	Batches   atomic.Int64 // per-shard batches sent
	RouteNs   atomic.Int64 // hashing and partitioning by owner
	WaitNs    atomic.Int64 // from the first send to the last reply
	GatherNs  atomic.Int64 // putting values back in key order
	KeysTo    []atomic.Int64
	BatchesTo []atomic.Int64
}

// NewRouter returns a router over clients (one per shard).
func NewRouter(capacity uint64, clients []Client) *Router {
	r := &Router{N: len(clients), Capacity: capacity, Clients: clients}
	r.Stats.KeysTo = make([]atomic.Int64, len(clients))
	r.Stats.BatchesTo = make([]atomic.Int64, len(clients))
	return r
}

// RouteScratch is one caller's scratch. The zero value is ready.
type RouteScratch struct {
	own  []uint16
	req  [][]uint64
	resp [][]uint32
	cur  []int
	errs []error
}

// Lookup appends to vals the stored value (0 on a miss) of each key, in order: upstream Get's
// result, computed by the owning shards.
func (r *Router) Lookup(keys []uint64, vals []uint32, s *RouteScratch) ([]uint32, error) {
	r.Stats.Calls.Add(1)
	r.Stats.Keys.Add(int64(len(keys)))
	t0 := time.Now()
	n := r.N
	if len(s.req) != n {
		s.req = make([][]uint64, n)
		s.resp = make([][]uint32, n)
		s.cur = make([]int, n)
		s.errs = make([]error, n)
	}
	for i := range s.req {
		s.req[i] = s.req[i][:0]
		s.cur[i] = 0
		s.errs[i] = nil
	}
	if cap(s.own) < len(keys) {
		s.own = make([]uint16, len(keys), 2*len(keys))
	}
	own := s.own[:len(keys)]
	c := r.Capacity
	for i, k := range keys {
		hc := chash.MurmurHash3(k)
		o := 0
		if n > 1 {
			o = Owner(hc%c, n, c)
		}
		own[i] = uint16(o)
		s.req[o] = append(s.req[o], hc)
	}
	t1 := time.Now()
	r.Stats.RouteNs.Add(int64(t1.Sub(t0)))
	var wg sync.WaitGroup
	for o := range s.req {
		m := len(s.req[o])
		if m == 0 {
			continue
		}
		if cap(s.resp[o]) < m {
			s.resp[o] = make([]uint32, m, 2*m)
		}
		s.resp[o] = s.resp[o][:m]
		r.Stats.Batches.Add(1)
		r.Stats.BatchesTo[o].Add(1)
		r.Stats.KeysTo[o].Add(int64(m))
		wg.Add(1)
		go func() {
			defer wg.Done()
			s.errs[o] = r.Clients[o].Lookup(s.req[o], s.resp[o])
		}()
	}
	wg.Wait()
	t2 := time.Now()
	r.Stats.WaitNs.Add(int64(t2.Sub(t1)))
	for o, err := range s.errs {
		if err != nil {
			return vals, fmt.Errorf("engine: shard %d: %w", o, err)
		}
	}
	for _, o := range own {
		vals = append(vals, s.resp[o][s.cur[o]])
		s.cur[o]++
	}
	r.Stats.GatherNs.Add(int64(time.Since(t2)))
	return vals, nil
}
