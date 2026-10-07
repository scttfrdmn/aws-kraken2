package main

// The multi-node engine (G3, #24, checkpoint 2): N processes, normally one per instance, each
// started with the same command line and its own rank:
//
//	AK2_ENGINE_N=<n> AK2_ENGINE_RANK=<r>     this node is rank r of n
//	AK2_ENGINE_RENDEZVOUS=<loc>             s3://bucket/prefix (the run prefix) or a local dir
//	AK2_ENGINE_LISTEN=<host>                address to listen on (default 127.0.0.1)
//	AK2_ENGINE_ADVERTISE=<host>             address peers dial (default the listen host)
//	AK2_ENGINE_WINDOW=<blocks>              flow-control window (default 64)
//	AK2_ENGINE_TIMEOUT=<duration>           rendezvous and peer-accept timeout (default 15m)
//	AK2_ENGINE_HASH_URL=<https url>         load the shard from this object by ranged GETs
//	AK2_ENGINE_HASH_ETAG / _SIZE            its ETag (sent as If-Match) and size; required with
//	                                        the URL. hash.k2d need not exist locally then.
//
// Node r loads shard r (its floor-cut slot range plus the tail), serves it over TCP, publishes
// its addresses to the rendezvous, waits for every rank, and connects to every other shard.
// Rank 0 is the sample's emitter. Every node reads the whole input and cuts the same blocks
// (gzip cannot be split, so each decompresses the full stream; the time is the read_s
// counter), but scans and classifies only its own: block b belongs to rank b mod n. Every
// lookup goes to the shard owning its home slot, so all nodes route to each other. A home
// node sends each classified block to the emitter, which writes the outputs in read order
// (to local files, or to one multipart upload per output with parts of at least 8 MiB, in
// read order) and sum-reduces the report counters, then tells every node to finish. No node
// exits until every node has sent its last block, because they all serve shards.
//
// Flow control: the emitter tells every node how far it has written (Progress); a node cuts
// a block of its own only within Window blocks of that point, so the emitter buffers at most
// about Window blocks' results. The block the emitter waits for is always inside the window.

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/classify"
	"github.com/scttfrdmn/aws-kraken2/internal/engine"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
	"github.com/scttfrdmn/aws-kraken2/internal/seqio"
	"github.com/scttfrdmn/aws-kraken2/internal/seqout"
)

type clusterConf struct {
	rank       int
	rendezvous string
	listen     string
	advertise  string
	window     uint64
	timeout    time.Duration
	hashURL    string
	hashETag   string
	hashSize   int64
}

func clusterFromEnv(n int) (*clusterConf, error) {
	rs, ok := os.LookupEnv("AK2_ENGINE_RANK")
	if !ok {
		return nil, nil
	}
	r, err := strconv.Atoi(rs)
	if err != nil || r < 0 || r >= n {
		return nil, fmt.Errorf("AK2_ENGINE_RANK=%q: want 0 to %d", rs, n-1)
	}
	c := &clusterConf{rank: r, rendezvous: os.Getenv("AK2_ENGINE_RENDEZVOUS"), listen: "127.0.0.1",
		window: 64, timeout: 15 * time.Minute}
	if c.rendezvous == "" {
		return nil, fmt.Errorf("AK2_ENGINE_RANK needs AK2_ENGINE_RENDEZVOUS")
	}
	if v := os.Getenv("AK2_ENGINE_LISTEN"); v != "" {
		c.listen = v
	}
	c.advertise = c.listen
	if v := os.Getenv("AK2_ENGINE_ADVERTISE"); v != "" {
		c.advertise = v
	}
	if ip := net.ParseIP(c.advertise); ip != nil && ip.IsUnspecified() {
		return nil, fmt.Errorf("AK2_ENGINE_ADVERTISE: peers cannot dial %s; give this node's address", c.advertise)
	}
	if v := os.Getenv("AK2_ENGINE_WINDOW"); v != "" {
		w, err := strconv.ParseUint(v, 10, 32)
		if err != nil || w < 1 {
			return nil, fmt.Errorf("AK2_ENGINE_WINDOW=%q: want a positive block count", v)
		}
		c.window = w
	}
	if v := os.Getenv("AK2_ENGINE_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return nil, fmt.Errorf("AK2_ENGINE_TIMEOUT=%q: want a duration", v)
		}
		c.timeout = d
	}
	if c.hashURL = os.Getenv("AK2_ENGINE_HASH_URL"); c.hashURL != "" {
		c.hashETag = os.Getenv("AK2_ENGINE_HASH_ETAG")
		sz, err := strconv.ParseInt(os.Getenv("AK2_ENGINE_HASH_SIZE"), 10, 64)
		if c.hashETag == "" || err != nil || sz <= 0 {
			return nil, fmt.Errorf("AK2_ENGINE_HASH_URL needs AK2_ENGINE_HASH_ETAG and AK2_ENGINE_HASH_SIZE")
		}
		c.hashSize = sz
	}
	return c, nil
}

// dbFiles are the database files the wrapper and classify require: hash.k2d is not required
// locally when a multi-node run loads its shard from AK2_ENGINE_HASH_URL.
func dbFiles() []string {
	if remoteHash() {
		return []string{"taxo.k2d", "opts.k2d"}
	}
	return []string{"taxo.k2d", "hash.k2d", "opts.k2d"}
}

// remoteHash reports whether the shard comes from AK2_ENGINE_HASH_URL (hash.k2d need not be
// present locally).
func remoteHash() bool {
	_, n := os.LookupEnv("AK2_ENGINE_RANK")
	return n && os.Getenv("AK2_ENGINE_HASH_URL") != ""
}

// ctlConn is one emitter-protocol connection.
type ctlConn struct {
	c   net.Conn
	br  *bufio.Reader
	wmu sync.Mutex
	bw  *bufio.Writer
}

func newCtl(c net.Conn) *ctlConn {
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	return &ctlConn{c: c, br: bufio.NewReaderSize(c, 1<<20), bw: bufio.NewWriterSize(c, 1<<20)}
}

func (k *ctlConn) send(b []byte) error {
	k.wmu.Lock()
	defer k.wmu.Unlock()
	_ = k.c.SetWriteDeadline(time.Now().Add(engine.DefaultWriteTimeout))
	if _, err := k.bw.Write(b); err != nil {
		return err
	}
	return k.bw.Flush()
}

type bkey struct {
	file uint32
	seq  uint64
}

// inbox is the emitter's store of classified blocks, local and remote.
type inbox struct {
	mu     sync.Mutex
	cond   *sync.Cond
	m      map[bkey]*result
	total  map[uint32]uint64 // blocks per input, once the emitter's own cut is done
	done   map[int]*engine.Done
	lost   map[int]error
	failed func() bool
}

func newInbox(failed func() bool) *inbox {
	b := &inbox{m: map[bkey]*result{}, total: map[uint32]uint64{}, done: map[int]*engine.Done{},
		lost: map[int]error{}, failed: failed}
	b.cond = sync.NewCond(&b.mu)
	return b
}

func (b *inbox) put(k bkey, r *result) {
	b.mu.Lock()
	b.m[k] = r
	b.mu.Unlock()
	b.cond.Broadcast()
}

func (b *inbox) setTotal(f uint32, n uint64) {
	b.mu.Lock()
	b.total[f] = n
	b.mu.Unlock()
	b.cond.Broadcast()
}

func (b *inbox) wake() { b.cond.Broadcast() }

// take waits for block k, whose home is rank home. ok is false once k is past the input's last
// block.
func (b *inbox) take(k bkey, home int) (r *result, ok bool, err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for {
		if r := b.m[k]; r != nil {
			delete(b.m, k)
			return r, true, nil
		}
		if t, known := b.total[k.file]; known && k.seq >= t {
			return nil, false, nil
		}
		if b.failed() {
			return nil, false, errAborted
		}
		if e := b.lost[home]; e != nil {
			return nil, false, fmt.Errorf("lost rank %d before block %d of input %d: %w", home, k.seq, k.file, e)
		}
		if d := b.done[home]; d != nil {
			return nil, false, fmt.Errorf("rank %d ended (status %d) without block %d of input %d", home, d.Status, k.seq, k.file)
		}
		b.cond.Wait()
	}
}

// node is this process's part of a multi-node run.
type node struct {
	rank, n int
	window  uint64
	emitter bool
	timeout time.Duration
	box     *inbox     // emitter
	peers   []*ctlConn // emitter: by rank, nil at its own
	up      *ctlConn   // home node: to the emitter
	finish  chan int32 // home node: the emitter's Finish status (-1: lost the emitter)

	pmu     sync.Mutex
	pcond   *sync.Cond
	pfile   uint32
	pnext   uint64
	stopped bool

	file    uint32      // the current input's index (processFilesCluster calls, in order)
	aborted atomic.Bool // a block failed here (runner.fail)

	// Counters (AK2_TIMINGS=1).
	readNs, windowNs, takeNs, emitNs, sendNs atomic.Int64
	cut, mine, sentBytes                     atomic.Int64
}

func (nd *node) mineBlock(seq uint64) bool { return seq%uint64(nd.n) == uint64(nd.rank) }
func (nd *node) home(seq uint64) int       { return int(seq % uint64(nd.n)) }

// waitWindow blocks until block seq of input f is within the window of the emitter's
// position. It returns false once the run is stopping.
func (nd *node) waitWindow(f uint32, seq uint64) bool {
	t := time.Now()
	nd.pmu.Lock()
	defer nd.pmu.Unlock()
	for !nd.stopped && !(nd.pfile > f || (nd.pfile == f && seq < nd.pnext+nd.window)) {
		nd.pcond.Wait()
	}
	nd.windowNs.Add(int64(time.Since(t)))
	return !nd.stopped
}

func (nd *node) setProgress(f uint32, next uint64) {
	nd.pmu.Lock()
	nd.pfile, nd.pnext = f, next
	nd.pmu.Unlock()
	nd.pcond.Broadcast()
	if !nd.emitter {
		return
	}
	b := engine.AppendProgress(nil, engine.Progress{File: f, Next: next})
	for _, p := range nd.peers {
		if p != nil {
			_ = p.send(b) // a lost peer is noticed by its reader
		}
	}
}

func (nd *node) stop() {
	nd.pmu.Lock()
	nd.stopped = true
	nd.pmu.Unlock()
	nd.pcond.Broadcast()
}

// startNode connects this node to the run: rendezvous, shard clients, and the emitter
// connections.
func startNode(ctx context.Context, cc *clusterConf, n int, sh *engine.Shard, srv *engine.Server,
	shardLn net.Listener, rv *engine.Rendezvous, loadS float64, threads int) (*node, *engine.Router, []*engine.TCPClient, error) {
	nd := &node{rank: cc.rank, n: n, window: cc.window, emitter: cc.rank == 0, timeout: cc.timeout,
		finish: make(chan int32, 1)}
	nd.pcond = sync.NewCond(&nd.pmu)
	var emitLn net.Listener
	if nd.emitter {
		var err error
		if emitLn, err = net.Listen("tcp", net.JoinHostPort(cc.listen, "0")); err != nil {
			return nil, nil, nil, fmt.Errorf("engine: emitter listen: %w", err)
		}
		defer emitLn.Close()
	}
	port := func(ln net.Listener) string { return strconv.Itoa(ln.Addr().(*net.TCPAddr).Port) }
	me := engine.Peer{Rank: cc.rank, N: n, Shard: net.JoinHostPort(cc.advertise, port(shardLn)), PID: os.Getpid(), LoadS: loadS}
	me.Host, _ = os.Hostname()
	if emitLn != nil {
		me.Emit = net.JoinHostPort(cc.advertise, port(emitLn))
	}
	wctx, cancel := context.WithTimeout(ctx, cc.timeout)
	defer cancel()
	pr := phase("rendezvous")
	if err := rv.Publish(wctx, me); err != nil {
		return nil, nil, nil, fmt.Errorf("engine: rendezvous publish: %w", err)
	}
	peers, err := rv.Wait(wctx, n)
	if err != nil {
		return nil, nil, nil, err
	}
	pr.end()
	pc := phase("connect")
	clients := make([]engine.Client, n)
	var tcps []*engine.TCPClient
	for i, p := range peers {
		if i == cc.rank {
			clients[i] = engine.LocalClient{S: sh, Stats: &srv.Stats}
			continue
		}
		c, err := engine.DialTCP(p.Shard, i, n, sh.Layout.Capacity, rv.Token(), sh.ID, threads, 0)
		if err != nil {
			for _, t := range tcps {
				t.Close()
			}
			return nil, nil, nil, err
		}
		tcps = append(tcps, c)
		clients[i] = c
	}
	router := engine.NewRouter(sh.Layout.Capacity, clients)
	if nd.emitter {
		nd.box = newInbox(nd.aborted.Load)
		nd.peers = make([]*ctlConn, n)
		if tl, ok := emitLn.(*net.TCPListener); ok {
			_ = tl.SetDeadline(time.Now().Add(cc.timeout))
		}
		for got := 0; got < n-1; {
			c, err := emitLn.Accept()
			if err != nil {
				return nil, nil, nil, fmt.Errorf("engine: emitter: %d of %d nodes connected: %w", got, n-1, err)
			}
			_ = c.SetDeadline(time.Now().Add(engine.HelloTimeout))
			rank, err := engine.AcceptControl(c, n, rv.Token())
			if err != nil || nd.peers[rank] != nil || rank == 0 {
				c.Close()
				continue
			}
			_ = c.SetDeadline(time.Time{})
			nd.peers[rank] = newCtl(c)
			got++
		}
		for rank, p := range nd.peers {
			if p != nil {
				go nd.readPeer(rank, p)
			}
		}
	} else {
		c, err := net.DialTimeout("tcp", peers[0].Emit, engine.HelloTimeout)
		if err != nil {
			return nil, nil, nil, fmt.Errorf("engine: dial emitter %s: %w", peers[0].Emit, err)
		}
		_ = c.SetDeadline(time.Now().Add(engine.HelloTimeout))
		if err := engine.HelloControl(c, cc.rank, n, rv.Token()); err != nil {
			c.Close()
			return nil, nil, nil, err
		}
		_ = c.SetDeadline(time.Time{})
		nd.up = newCtl(c)
		go nd.readEmitter()
	}
	pc.end()
	return nd, router, tcps, nil
}

// readPeer is the emitter's reader for one home node.
func (nd *node) readPeer(rank int, k *ctlConn) {
	for {
		f, err := engine.ReadFrame(k.br)
		if err != nil {
			nd.box.mu.Lock()
			if nd.box.done[rank] == nil {
				nd.box.lost[rank] = err
			}
			nd.box.mu.Unlock()
			nd.box.wake()
			return
		}
		switch f.Type {
		case engine.MsgResult:
			x := f.Result
			res := &result{seq: x.Seq, kraken: x.Streams[engine.StreamKraken],
				batch: seqout.Batch{C1: x.Streams[engine.StreamC1], C2: x.Streams[engine.StreamC2],
					U1: x.Streams[engine.StreamU1], U2: x.Streams[engine.StreamU2]},
				st:    stats{sequences: x.Sequences, bases: x.Bases, classified: x.Classified},
				fault: seqio.Fault{Count: int(x.FaultCount), First: x.FaultFirst}}
			if x.Err != "" {
				res.err = fmt.Errorf("rank %d: %s", rank, x.Err)
			}
			nd.box.put(bkey{x.File, x.Seq}, res)
		case engine.MsgDone:
			nd.box.mu.Lock()
			nd.box.done[rank] = f.Done
			nd.box.mu.Unlock()
			nd.box.wake()
		}
	}
}

// readEmitter is a home node's reader for the emitter's frames.
func (nd *node) readEmitter() {
	for {
		f, err := engine.ReadFrame(nd.up.br)
		if err != nil {
			nd.stop()
			select {
			case nd.finish <- -1:
			default:
			}
			return
		}
		switch f.Type {
		case engine.MsgProgress:
			nd.pmu.Lock()
			nd.pfile, nd.pnext = f.Progress.File, f.Progress.Next
			nd.pmu.Unlock()
			nd.pcond.Broadcast()
		case engine.MsgFinish:
			nd.stop()
			nd.finish <- f.Status
			return
		}
	}
}

// sendResult ships one classified block to the emitter.
func (nd *node) sendResult(file uint32, res *result) error {
	t := time.Now()
	x := &engine.BlockResult{File: file, Seq: res.seq, Sequences: res.st.sequences, Bases: res.st.bases,
		Classified: res.st.classified, FaultCount: uint32(res.fault.Count), FaultFirst: res.fault.First}
	if res.err != nil {
		x.Err = res.err.Error()
	}
	x.Streams = [engine.NumStreams][]byte{res.kraken, res.batch.C1, res.batch.C2, res.batch.U1, res.batch.U2}
	b := engine.AppendResult(nil, x)
	putBuf(res.kraken)
	err := nd.up.send(b)
	nd.sentBytes.Add(int64(len(b)))
	nd.sendNs.Add(int64(time.Since(t)))
	return err
}

// processFilesCluster is processFiles on a node of a multi-node run.
func (r *runner) processFilesCluster(name1, name2 string) int {
	nd := r.node
	f := nd.file
	nd.file++
	in, st := r.open(name1, name2, nd.emitter)
	defer in.close()
	if st != 0 {
		return st
	}
	if nd.emitter {
		nd.setProgress(f, 0)
	}
	printing := r.out.printingSequences
	if !nd.emitter {
		c := r.c
		printing = (c.classifiedOut != nil && *c.classifiedOut != "") || (c.unclassifiedOut != nil && *c.unclassifiedOut != "")
	}
	jobs := make(chan job, len(r.workers))
	// Every node cuts every block (the same cut everywhere) and keeps its own.
	go func() {
		defer close(jobs)
		seq := uint64(0)
		for ; !r.failed.Load(); seq++ {
			t := time.Now()
			j, ok := in.next(seq)
			nd.readNs.Add(int64(time.Since(t)))
			if !ok {
				break
			}
			nd.cut.Add(1)
			if !nd.mineBlock(seq) {
				continue
			}
			nd.mine.Add(1)
			if !nd.waitWindow(f, seq) {
				return
			}
			jobs <- j
		}
		if nd.emitter {
			nd.box.setTotal(f, seq)
		}
	}()
	var wg sync.WaitGroup
	for _, ws := range r.workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := range jobs {
				res := r.work(ws, j, printing)
				if nd.emitter {
					nd.box.put(bkey{f, res.seq}, res)
				} else if err := nd.sendResult(f, res); err != nil {
					r.fail(fmt.Errorf("engine: send block %d to the emitter: %w", res.seq, err))
				}
			}
		}()
	}
	var fault seqio.Fault
	if !nd.emitter {
		wg.Wait()
		if err := r.failure(); err != nil {
			return classifyErr(exitFailure, "%v", err)
		}
		if nd.stopped {
			return classifyErr(exitFailure, "engine: the emitter ended the run")
		}
		return r.finishInput(in, fault, false)
	}
	for next := uint64(0); ; next++ {
		t := time.Now()
		p, ok, err := nd.box.take(bkey{f, next}, nd.home(next))
		nd.takeNs.Add(int64(time.Since(t)))
		if err != nil {
			if err != errAborted {
				r.fail(fmt.Errorf("engine: %w", err))
			}
			break
		}
		if !ok {
			break
		}
		if p.err != nil {
			r.fail(p.err)
			break
		}
		t = time.Now()
		r.emitResult(p, &fault)
		nd.emitNs.Add(int64(time.Since(t)))
		nd.setProgress(f, next+1)
	}
	if r.failed.Load() {
		nd.stop() // unblock the producer
	}
	wg.Wait()
	if err := r.out.flush(); err != nil {
		return classifyErr(exIOErr, "%v", err)
	}
	if err := r.failure(); err != nil {
		return classifyErr(exitFailure, "%v", err)
	}
	return r.finishInput(in, fault, true)
}

// endRun is a node's end of the run, whatever its status. A home node sends Done (with its
// counters) and waits for the emitter's Finish. The emitter, if its own status is 0, waits for
// every node's Done and returns their counters for the report; it always sends Finish, so no
// node is left serving a shard nobody needs or waiting for one.
func (nd *node) endRun(status int, counts map[uint64]*classify.TaxonCount) (map[uint64]*classify.TaxonCount, int, error) {
	if !nd.emitter {
		d := &engine.Done{Status: int32(status)}
		for t, c := range counts {
			d.Counts = append(d.Counts, engine.Count{Taxon: t, Reads: c.Reads, Kmers: c.Kmers})
		}
		if err := nd.up.send(engine.AppendDone(nil, d)); err != nil && status == 0 {
			return nil, exitFailure, fmt.Errorf("engine: send Done to the emitter: %w", err)
		}
		pb := phase("barrier")
		var fin int32
		select {
		case fin = <-nd.finish:
		case <-time.After(nd.timeout):
			fin = -2
		}
		pb.end()
		nd.up.c.Close()
		switch {
		case status != 0:
			return nil, status, nil
		case fin == -1:
			return nil, exitFailure, fmt.Errorf("engine: lost the emitter before it finished the run")
		case fin == -2:
			return nil, exitFailure, fmt.Errorf("engine: no Finish from the emitter within %s", nd.timeout)
		}
		return nil, status, nil
	}
	defer nd.broadcastFinish(int32(status))
	if status != 0 {
		return nil, status, nil
	}
	pb := phase("barrier")
	defer pb.end()
	deadline := time.Now().Add(nd.timeout)
	timer := time.AfterFunc(nd.timeout, nd.box.wake)
	defer timer.Stop()
	b := nd.box
	b.mu.Lock()
	defer b.mu.Unlock()
	merged := counts
	for rank := 1; rank < nd.n; rank++ {
		for b.done[rank] == nil && b.lost[rank] == nil && time.Now().Before(deadline) {
			b.cond.Wait()
		}
		d := b.done[rank]
		switch {
		case d == nil && b.lost[rank] != nil:
			return nil, exitFailure, fmt.Errorf("engine: lost rank %d before its Done: %w", rank, b.lost[rank])
		case d == nil:
			return nil, exitFailure, fmt.Errorf("engine: no Done from rank %d within %s", rank, nd.timeout)
		case d.Status != 0:
			return nil, exitFailure, fmt.Errorf("engine: rank %d ended with status %d", rank, d.Status)
		}
		for _, c := range d.Counts { // the sum-reduce, zero-read taxa included
			m := merged[c.Taxon]
			if m == nil {
				m = &classify.TaxonCount{}
				merged[c.Taxon] = m
			}
			m.Reads += c.Reads
			m.Kmers += c.Kmers
		}
	}
	return merged, 0, nil
}

func (nd *node) broadcastFinish(status int32) {
	b := engine.AppendFinish(nil, status)
	for _, p := range nd.peers {
		if p != nil {
			_ = p.send(b)
			p.c.Close()
		}
	}
}

// report writes the node's counters (AK2_TIMINGS=1):
//
//	ak2-engine node rank <r> n <n> emitter <bool> blocks_cut <n> blocks_mine <n> read_s <s>
//	           window_wait_s <s> send_s <s> sent_bytes <n> emit_wait_s <s> emit_s <s>
//
// read_s is the producer's time cutting blocks, decompression included: the gunzip cap.
func (nd *node) report() {
	if !timingsOn {
		return
	}
	sec := func(v *atomic.Int64) float64 { return time.Duration(v.Load()).Seconds() }
	fmt.Fprintf(os.Stderr, "ak2-engine\tnode\trank\t%d\tn\t%d\temitter\t%t\tblocks_cut\t%d\tblocks_mine\t%d\tread_s\t%.6f\twindow_wait_s\t%.6f\tsend_s\t%.6f\tsent_bytes\t%d\temit_wait_s\t%.6f\temit_s\t%.6f\n",
		nd.rank, nd.n, nd.emitter, nd.cut.Load(), nd.mine.Load(), sec(&nd.readNs), sec(&nd.windowNs),
		sec(&nd.sendNs), nd.sentBytes.Load(), sec(&nd.takeNs), sec(&nd.emitNs))
}

// loadNode loads this node's shard and joins the run.
func loadNode(path string, conf *engineConf, readThreads, threads int) (*engineIndex, error) {
	cc := conf.cluster
	ctx := context.Background()
	var src rangeread.Source
	var size int64
	declared := ""
	if cc.hashURL != "" {
		src = &rangeread.HTTPSource{URL: cc.hashURL, ETag: cc.hashETag, Size: cc.hashSize,
			Client: rangeread.NewHTTPClient(readThreads)}
		size, declared = cc.hashSize, cc.hashETag
	} else {
		f, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		st, err := f.Stat()
		if err != nil {
			return nil, err
		}
		src, size = &rangeread.FileSource{F: f}, st.Size()
	}
	_, l, err := engine.ReadLayout(ctx, src, size)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	rv, err := engine.NewRendezvous(cc.rendezvous)
	if err != nil {
		return nil, err
	}
	p := phase("shard-load-" + strconv.Itoa(cc.rank))
	t0 := time.Now()
	sh, err := engine.LoadShard(ctx, l, cc.rank, conf.n, conf.tail, engine.RangeFiller{Src: src, Workers: readThreads})
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	loadS := time.Since(t0).Seconds()
	p.end()
	e := &engineIndex{conf: conf, shards: []*engine.Shard{sh}}
	if sh.ID, err = engine.TableID(ctx, src, size, declared); err != nil {
		e.close()
		return nil, err
	}
	ln, err := net.Listen("tcp", net.JoinHostPort(cc.listen, "0"))
	if err != nil {
		e.close()
		return nil, fmt.Errorf("engine: listen: %w", err)
	}
	srv := &engine.Server{Shard: sh, Run: rv.Token()}
	go srv.Serve(ln)
	e.servers = append(e.servers, srv)
	e.stats = append(e.stats, &srv.Stats)
	nd, router, tcps, err := startNode(ctx, cc, conf.n, sh, srv, ln, rv, loadS, threads)
	if err != nil {
		e.close()
		return nil, err
	}
	e.node, e.router, e.tcp = nd, router, tcps
	e.rvRequests = rv.Requests
	return e, nil
}
