package main

// The sharded engine (G3, issue #24; internal/engine), selected by environment so the command
// line stays upstream's:
//
//	AK2_ENGINE_N=<n>            shard the table n ways (n >= 1); unset = the plain resident table
//	AK2_ENGINE_TRANSPORT=local  shards called in-process (default)
//	                    =tcp    each shard behind its own loopback TCP server
//	AK2_ENGINE_TAIL=<cells>     overlap tail per shard (default engine.DefaultTail, 302)
//
// Every lookup of an input block is routed to the shard owning its home slot, and the values
// come back to the worker that scanned the block, which then classifies its reads exactly as
// the plain path does. --memory-mapping does not apply: shards are always resident.
// With AK2_TIMINGS=1 the engine adds phase lines (shard loads) and ak2-engine counter lines.

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/engine"
	"github.com/scttfrdmn/aws-kraken2/internal/objstore"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

type engineConf struct {
	n         int
	transport string
	tail      uint64
	cluster   *clusterConf // multi-node (AK2_ENGINE_RANK; cluster.go); nil = in-process
	cohort    bool         // AK2_COHORT: control sessions per block-striped sample (cohort.go)
}

// engineFromEnv returns nil when AK2_ENGINE_N is unset.
func engineFromEnv(lookup func(string) (string, bool)) (*engineConf, error) {
	getenv := func(k string) string { v, _ := lookup(k); return v }
	ns, ok := lookup("AK2_ENGINE_N")
	if !ok {
		return nil, nil
	}
	n, err := strconv.Atoi(ns)
	if err != nil || n < 1 || n > 1<<16 {
		return nil, fmt.Errorf("AK2_ENGINE_N=%q: want an integer from 1 to 65536", ns)
	}
	c := &engineConf{n: n, transport: "local", tail: engine.DefaultTail}
	if t := getenv("AK2_ENGINE_TRANSPORT"); t != "" {
		if t != "local" && t != "tcp" {
			return nil, fmt.Errorf("AK2_ENGINE_TRANSPORT=%q: want local or tcp", t)
		}
		c.transport = t
	}
	if ts, ok := lookup("AK2_ENGINE_TAIL"); ok {
		v, err := strconv.ParseUint(ts, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("AK2_ENGINE_TAIL=%q: want a cell count", ts)
		}
		c.tail = v
	}
	if c.cluster, err = clusterFromEnv(n, lookup); err != nil {
		return nil, err
	}
	_, c.cohort = lookup("AK2_COHORT")
	return c, nil
}

// engineIndex is the sharded table and its router.
type engineIndex struct {
	conf    *engineConf
	shards  []*engine.Shard
	stats   []*engine.ShardStats
	servers []*engine.Server
	tcp     []*engine.TCPClient
	router  *engine.Router
	node    *node // multi-node only

	rvRequests int64
	// The node's shard load: seconds, and the source's request counters (ranged GETs or preads,
	// including the table id's samples, which are read after the load).
	loadS                                float64
	loadRequests, loadRetries, loadBytes int64

	scanNs, lookupNs, classifyNs atomic.Int64
}

func loadEngine(path string, conf *engineConf, readThreads, threads int) (*engineIndex, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	ctx := context.Background()
	src := &rangeread.FileSource{F: f}
	_, l, err := engine.ReadLayout(ctx, src, st.Size())
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	e := &engineIndex{conf: conf}
	fill := engine.RangeFiller{Src: src, Workers: readThreads}
	for i := 0; i < conf.n; i++ {
		p := phase("shard-load-" + strconv.Itoa(i))
		s, err := engine.LoadShard(ctx, l, i, conf.n, conf.tail, fill)
		if err != nil {
			e.close()
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		p.end()
		e.shards = append(e.shards, s)
	}
	clients := make([]engine.Client, conf.n)
	switch conf.transport {
	case "local":
		for i, s := range e.shards {
			ss := &engine.ShardStats{}
			e.stats = append(e.stats, ss)
			clients[i] = engine.LocalClient{S: s, Stats: ss}
		}
	case "tcp":
		var tok [8]byte
		_, _ = rand.Read(tok[:])
		run := binary.LittleEndian.Uint64(tok[:])
		id, err := engine.TableID(ctx, src, st.Size(), "")
		if err != nil {
			e.close()
			return nil, err
		}
		for i, s := range e.shards {
			s.ID = id
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				e.close()
				return nil, fmt.Errorf("engine: listen: %w", err)
			}
			srv := &engine.Server{Shard: s, Run: run}
			go srv.Serve(ln)
			e.servers = append(e.servers, srv)
			e.stats = append(e.stats, &srv.Stats)
			c, err := engine.DialTCP(ln.Addr().String(), i, conf.n, l.Capacity, run, id, threads, 0)
			if err != nil {
				e.close()
				return nil, err
			}
			e.tcp = append(e.tcp, c)
			clients[i] = c
		}
	}
	e.router = engine.NewRouter(l.Capacity, clients)
	return e, nil
}

func (e *engineIndex) close() {
	for _, c := range e.tcp {
		c.Close()
	}
	for _, s := range e.servers {
		s.Close()
	}
	for _, s := range e.shards {
		s.Close()
	}
}

// report writes the engine's counters (AK2_TIMINGS=1 only), one tab-separated line each:
//
//	ak2-engine shard <i> n <n> lo <lo> hi <hi> tail <cells> full <bool> empty_at <local> keys <n> batches <n> probe_s <s> tail_probes <n> wrap_probes <n>
//	ak2-engine route calls <n> keys <n> batches <n> route_s <s> wait_s <s> gather_s <s>
//	ak2-engine worker scan_s <s> lookup_s <s> classify_s <s>
//
// Seconds are summed over the goroutines doing the work (CPU-ish time, not wall).
func (e *engineIndex) report() {
	if !timingsOn {
		return
	}
	sec := func(ns int64) float64 { return time.Duration(ns).Seconds() }
	for i, s := range e.shards {
		st := e.stats[i]
		fmt.Fprintf(os.Stderr, "ak2-engine\tshard\t%d\tn\t%d\tlo\t%d\thi\t%d\ttail\t%d\tfull\t%t\tempty_at\t%d\tkeys\t%d\tbatches\t%d\tprobe_s\t%.6f\ttail_probes\t%d\twrap_probes\t%d\n",
			i, s.N, s.Lo, s.Hi, s.Tail, s.Full, s.Empty, st.Keys.Load(), st.Batches.Load(), sec(st.ProbeNs.Load()),
			s.TailProbes.Load(), s.WrapProbes.Load())
	}
	// Requests, for the run's accounting (ak2_req): every rendezvous request of the process, and
	// the S3 requests by client (rendezvous included, the shard load's ranged GETs not: those are
	// the load line's).
	fmt.Fprintf(os.Stderr, "ak2-engine\trendezvous\tputs\t%d\tgets\t%d\n", engine.RendezvousPuts.Load(), engine.RendezvousGets.Load())
	fmt.Fprintf(os.Stderr, "ak2-engine\ts3\tclient\tsdk\t%s\n", objstore.SDKCounts.Line())
	fmt.Fprintf(os.Stderr, "ak2-engine\ts3\tclient\tcli\t%s\n", objstore.CLICounts.Line())
	if e.node != nil {
		e.node.report()
	}
	multi := e.conf.cluster != nil
	if multi { // a node's own shard load (the in-process engine prints shard-load phases only)
		fmt.Fprintf(os.Stderr, "ak2-engine\tload\tseconds\t%.6f\trequests\t%d\tretries\t%d\tbytes\t%d\n",
			e.loadS, e.loadRequests, e.loadRetries, e.loadBytes)
	}
	r := &e.router.Stats
	transport := e.conf.transport
	if multi {
		transport = "nodes" // own shard in-process, every other shard over TCP
	}
	fmt.Fprintf(os.Stderr, "ak2-engine\troute\ttransport\t%s\tcalls\t%d\tkeys\t%d\tbatches\t%d\troute_s\t%.6f\twait_s\t%.6f\tgather_s\t%.6f\n",
		transport, r.Calls.Load(), r.Keys.Load(), r.Batches.Load(), sec(r.RouteNs.Load()), sec(r.WaitNs.Load()), sec(r.GatherNs.Load()))
	fmt.Fprintf(os.Stderr, "ak2-engine\tworker\tscan_s\t%.6f\tlookup_s\t%.6f\tclassify_s\t%.6f\n",
		sec(e.scanNs.Load()), sec(e.lookupNs.Load()), sec(e.classifyNs.Load()))
}
