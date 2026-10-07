package engine

// Transport: how a lookup batch reaches the shard that owns it.
//
// A batch is a list of hashed keys hc = MurmurHash3(minimizer) for one owner shard. hc carries
// both the home slot (hc % C) and the compacted key (hc >> (64 − key_bits)); the reply is the
// value for each, in the same order, so a key's position in the batch is its (read, position)
// tag and nothing else needs to travel.
//
// LocalClient calls the shard directly (one process, N shards). TCPClient talks to a Server
// over plain TCP with length-prefixed little-endian frames:
//
//	hello    client → server  magic "AK2E" u32, version u32, shard u32, n u32, capacity u64, run u64
//	         server → client  magic u32, version u32, status u32, shard u32, n u32, capacity u64,
//	                          lo u64, hi u64      (status 0 = accepted)
//	lookup   client → server  op u32 (1), count u32, count × hc u64
//	         server → client  status u32, count u32, then count × value u32 (status 0)
//	                          or a message of count bytes (status ≠ 0)
//
// The hello makes a misrouted connection (wrong shard, shard count, table or run) an error on
// both sides. A connection carries one batch at a time; a client keeps a pool of them.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

// Client resolves one batch for one shard: vals[i] is the value for hcs[i].
type Client interface {
	Lookup(hcs []uint64, vals []uint32) error
}

// ShardStats are a shard's server-side counters.
type ShardStats struct {
	Batches atomic.Int64
	Keys    atomic.Int64
	ProbeNs atomic.Int64 // time inside Shard.LookupBatch
}

// LocalClient serves batches from a shard in the same process.
type LocalClient struct {
	S     *Shard
	Stats *ShardStats
}

// Lookup implements Client.
func (c LocalClient) Lookup(hcs []uint64, vals []uint32) error {
	t := time.Now()
	err := c.S.LookupBatch(hcs, vals)
	if c.Stats != nil {
		c.Stats.ProbeNs.Add(int64(time.Since(t)))
		c.Stats.Batches.Add(1)
		c.Stats.Keys.Add(int64(len(hcs)))
	}
	return err
}

const (
	protoMagic   = 0x45324b41 // "AK2E" little-endian
	protoVersion = 1
	opLookup     = 1
	maxBatch     = 1 << 28 // keys per frame
)

// Server serves one shard's lookups over TCP.
type Server struct {
	Shard *Shard
	Run   uint64 // run token every client must present
	Stats ShardStats

	ln    net.Listener
	wg    sync.WaitGroup
	mu    sync.Mutex
	conns map[net.Conn]struct{}
	done  atomic.Bool
}

// Serve accepts connections on ln until Close. It returns once the listener is closed.
func (s *Server) Serve(ln net.Listener) {
	s.mu.Lock()
	s.ln = ln
	s.conns = map[net.Conn]struct{}{}
	s.mu.Unlock()
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		if s.done.Load() {
			s.mu.Unlock()
			c.Close()
			return
		}
		s.conns[c] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go func() {
			defer s.wg.Done()
			s.handle(c)
			s.mu.Lock()
			delete(s.conns, c)
			s.mu.Unlock()
			c.Close()
		}()
	}
}

// Close stops the listener and every connection, and waits for their handlers.
func (s *Server) Close() error {
	s.done.Store(true)
	s.mu.Lock()
	var err error
	if s.ln != nil {
		err = s.ln.Close()
	}
	for c := range s.conns {
		c.Close()
	}
	s.mu.Unlock()
	s.wg.Wait()
	return err
}

func (s *Server) handle(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	var hb [32]byte
	if _, err := io.ReadFull(c, hb[:]); err != nil {
		return
	}
	le := binary.LittleEndian
	sh := s.Shard
	status := uint32(0)
	switch {
	case le.Uint32(hb[0:]) != protoMagic || le.Uint32(hb[4:]) != protoVersion:
		status = 1
	case int(le.Uint32(hb[8:])) != sh.Index || int(le.Uint32(hb[12:])) != sh.N:
		status = 2
	case le.Uint64(hb[16:]) != sh.Layout.Capacity:
		status = 3
	case le.Uint64(hb[24:]) != s.Run:
		status = 4
	}
	var rb [44]byte
	le.PutUint32(rb[0:], protoMagic)
	le.PutUint32(rb[4:], protoVersion)
	le.PutUint32(rb[8:], status)
	le.PutUint32(rb[12:], uint32(sh.Index))
	le.PutUint32(rb[16:], uint32(sh.N))
	le.PutUint64(rb[20:], sh.Layout.Capacity)
	le.PutUint64(rb[28:], sh.Lo)
	le.PutUint64(rb[36:], sh.Hi)
	if _, err := c.Write(rb[:]); err != nil || status != 0 {
		return
	}
	var hcs []uint64
	var vals []uint32
	var fh [8]byte
	for {
		if _, err := io.ReadFull(c, fh[:]); err != nil {
			return
		}
		op, n := le.Uint32(fh[0:]), le.Uint32(fh[4:])
		if op != opLookup || n > maxBatch {
			writeErr(c, fmt.Sprintf("engine: bad frame op %d count %d", op, n))
			return
		}
		if cap(hcs) < int(n) {
			hcs = make([]uint64, n)
			vals = make([]uint32, n)
		}
		hcs, vals = hcs[:n], vals[:n]
		if _, err := io.ReadFull(c, u64Bytes(hcs)); err != nil {
			return
		}
		t := time.Now()
		err := sh.LookupBatch(hcs, vals)
		s.Stats.ProbeNs.Add(int64(time.Since(t)))
		s.Stats.Batches.Add(1)
		s.Stats.Keys.Add(int64(n))
		if err != nil {
			writeErr(c, err.Error())
			return
		}
		le.PutUint32(fh[0:], 0)
		le.PutUint32(fh[4:], n)
		bufs := net.Buffers{fh[:], u32Bytes(vals)}
		if _, err := bufs.WriteTo(c); err != nil {
			return
		}
	}
}

func writeErr(c net.Conn, msg string) {
	var fh [8]byte
	binary.LittleEndian.PutUint32(fh[0:], 1)
	binary.LittleEndian.PutUint32(fh[4:], uint32(len(msg)))
	bufs := net.Buffers{fh[:], []byte(msg)}
	_, _ = bufs.WriteTo(c)
}

// The wire is little-endian, as is every host the engine runs on (chash refuses others).
func u64Bytes(v []uint64) []byte {
	if len(v) == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(unsafe.SliceData(v))), len(v)*8)
}

func u32Bytes(v []uint32) []byte {
	if len(v) == 0 {
		return nil
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(unsafe.SliceData(v))), len(v)*4)
}

// TCPClient sends batches to one shard's Server, over a pool of connections.
type TCPClient struct {
	Addr     string
	Shard, N int
	Capacity uint64
	Run      uint64
	// Lo and Hi are the owned range the server reported in its hello (set by Dial).
	Lo, Hi uint64

	pool chan net.Conn
	mu   sync.Mutex
	all  []net.Conn
}

// DialTCP connects to a shard server and checks its hello. conns bounds the idle pool.
func DialTCP(addr string, shard, n int, capacity, run uint64, conns int) (*TCPClient, error) {
	c := &TCPClient{Addr: addr, Shard: shard, N: n, Capacity: capacity, Run: run,
		pool: make(chan net.Conn, max(conns, 1))}
	conn, err := c.dial()
	if err != nil {
		return nil, err
	}
	c.put(conn)
	return c, nil
}

func (c *TCPClient) dial() (net.Conn, error) {
	conn, err := net.DialTimeout("tcp", c.Addr, 30*time.Second)
	if err != nil {
		return nil, fmt.Errorf("engine: dial shard %d at %s: %w", c.Shard, c.Addr, err)
	}
	if tc, ok := conn.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
	le := binary.LittleEndian
	var hb [32]byte
	le.PutUint32(hb[0:], protoMagic)
	le.PutUint32(hb[4:], protoVersion)
	le.PutUint32(hb[8:], uint32(c.Shard))
	le.PutUint32(hb[12:], uint32(c.N))
	le.PutUint64(hb[16:], c.Capacity)
	le.PutUint64(hb[24:], c.Run)
	var rb [44]byte
	_, err = conn.Write(hb[:])
	if err == nil {
		_, err = io.ReadFull(conn, rb[:])
	}
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("engine: hello to shard %d at %s: %w", c.Shard, c.Addr, err)
	}
	if le.Uint32(rb[0:]) != protoMagic || le.Uint32(rb[4:]) != protoVersion {
		conn.Close()
		return nil, fmt.Errorf("engine: %s is not an aws-kraken2 shard server (protocol %d)", c.Addr, protoVersion)
	}
	if st := le.Uint32(rb[8:]); st != 0 {
		conn.Close()
		return nil, fmt.Errorf("engine: shard server %s (shard %d/%d, capacity %d) refused shard %d/%d "+
			"capacity %d run %x: status %d", c.Addr, le.Uint32(rb[12:]), le.Uint32(rb[16:]), le.Uint64(rb[20:]),
			c.Shard, c.N, c.Capacity, c.Run, st)
	}
	c.Lo, c.Hi = le.Uint64(rb[28:]), le.Uint64(rb[36:])
	if lo, hi := Cut(c.Shard, c.N, c.Capacity); lo != c.Lo || hi != c.Hi {
		conn.Close()
		return nil, fmt.Errorf("engine: shard %d/%d at %s owns [%d,%d), want [%d,%d)", c.Shard, c.N, c.Addr, c.Lo, c.Hi, lo, hi)
	}
	c.mu.Lock()
	c.all = append(c.all, conn)
	c.mu.Unlock()
	return conn, nil
}

func (c *TCPClient) get() (net.Conn, error) {
	select {
	case conn := <-c.pool:
		return conn, nil
	default:
		return c.dial()
	}
}

func (c *TCPClient) put(conn net.Conn) {
	select {
	case c.pool <- conn:
	default:
		conn.Close()
	}
}

// Lookup implements Client.
func (c *TCPClient) Lookup(hcs []uint64, vals []uint32) error {
	if len(vals) != len(hcs) {
		return fmt.Errorf("engine: %d values for %d keys", len(vals), len(hcs))
	}
	if len(hcs) > maxBatch {
		return fmt.Errorf("engine: batch of %d keys exceeds %d", len(hcs), maxBatch)
	}
	conn, err := c.get()
	if err != nil {
		return err
	}
	le := binary.LittleEndian
	var fh [8]byte
	le.PutUint32(fh[0:], opLookup)
	le.PutUint32(fh[4:], uint32(len(hcs)))
	bufs := net.Buffers{fh[:], u64Bytes(hcs)}
	if _, err := bufs.WriteTo(conn); err != nil {
		conn.Close()
		return fmt.Errorf("engine: send to shard %d: %w", c.Shard, err)
	}
	if _, err := io.ReadFull(conn, fh[:]); err != nil {
		conn.Close()
		return fmt.Errorf("engine: reply from shard %d: %w", c.Shard, err)
	}
	st, n := le.Uint32(fh[0:]), le.Uint32(fh[4:])
	if st != 0 {
		msg := make([]byte, min(n, 4096))
		_, _ = io.ReadFull(conn, msg)
		conn.Close()
		return fmt.Errorf("engine: shard %d: %s", c.Shard, msg)
	}
	if int(n) != len(hcs) {
		conn.Close()
		return fmt.Errorf("engine: shard %d answered %d of %d keys", c.Shard, n, len(hcs))
	}
	if _, err := io.ReadFull(conn, u32Bytes(vals)); err != nil {
		conn.Close()
		return fmt.Errorf("engine: values from shard %d: %w", c.Shard, err)
	}
	c.put(conn)
	return nil
}

// Close closes every connection the client opened.
func (c *TCPClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	var errs []error
	for _, conn := range c.all {
		if err := conn.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			errs = append(errs, err)
		}
	}
	c.all = nil
	return errors.Join(errs...)
}
