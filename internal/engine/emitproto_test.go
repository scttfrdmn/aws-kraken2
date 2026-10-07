package engine

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestFramesRoundTrip(t *testing.T) {
	r := &BlockResult{File: 2, Seq: 77, Sequences: 5, Bases: 500, Classified: 3, FaultCount: 1,
		FaultFirst: "bad record", Err: ""}
	r.Streams[StreamKraken] = []byte("C\tr1\t9606\t100\t9606:5\n")
	r.Streams[StreamU2] = []byte("@r2\nACGT\n+\nIIII\n")
	d := &Done{Status: 65, Counts: []Count{{1, 2, 3}, {9606, 0, 17}}}
	var b []byte
	b = AppendResult(b, r)
	b = AppendDone(b, d)
	b = AppendProgress(b, Progress{File: 1, Next: 40})
	b = AppendFinish(b, -3)
	b = AppendResult(b, &BlockResult{})
	br := bufio.NewReader(bytes.NewReader(b))
	f, err := ReadFrame(br)
	if err != nil || f.Type != MsgResult {
		t.Fatal(f, err)
	}
	for i := range r.Streams { // nil and empty decode alike
		if len(r.Streams[i]) == 0 {
			r.Streams[i] = f.Result.Streams[i]
		}
	}
	if !reflect.DeepEqual(f.Result, r) {
		t.Fatalf("result %+v, want %+v", f.Result, r)
	}
	if f, err = ReadFrame(br); err != nil || !reflect.DeepEqual(f.Done, d) {
		t.Fatalf("done %+v %v", f, err)
	}
	if f, err = ReadFrame(br); err != nil || *f.Progress != (Progress{1, 40}) {
		t.Fatalf("progress %+v %v", f, err)
	}
	if f, err = ReadFrame(br); err != nil || f.Type != MsgFinish || f.Status != -3 {
		t.Fatalf("finish %+v %v", f, err)
	}
	if f, err = ReadFrame(br); err != nil || f.Result == nil || f.Result.Seq != 0 {
		t.Fatalf("empty result %+v %v", f, err)
	}
	// A truncated frame is an error, not a short result.
	if _, err := ReadFrame(bufio.NewReader(bytes.NewReader(AppendResult(nil, r)[:30]))); err == nil {
		t.Fatal("truncated frame accepted")
	}
}

func TestControlHello(t *testing.T) {
	for _, tc := range []struct {
		rank, n int
		run     uint64
		ok      bool
	}{{1, 3, 7, true}, {3, 3, 7, false}, {1, 4, 7, false}, {1, 3, 8, false}} {
		a, b := net.Pipe()
		var wg sync.WaitGroup
		var aerr error
		wg.Add(1)
		go func() { defer wg.Done(); _, aerr = AcceptControl(b, 3, 7) }()
		err := HelloControl(a, tc.rank, tc.n, tc.run)
		wg.Wait()
		a.Close()
		b.Close()
		if (err == nil) != tc.ok || (aerr == nil) != tc.ok {
			t.Fatalf("%+v: node %v, emitter %v", tc, err, aerr)
		}
	}
}

func TestRendezvousDir(t *testing.T) {
	dir := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const n = 4
	var wg sync.WaitGroup
	res := make([][]Peer, n)
	errs := make([]error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rv, _ := NewRendezvous(dir)
			rv.Poll = 10 * time.Millisecond
			time.Sleep(time.Duration(i) * 20 * time.Millisecond)
			if errs[i] = rv.Publish(ctx, Peer{Rank: i, N: n, Shard: "s" + string(rune('0'+i))}); errs[i] == nil {
				res[i], errs[i] = rv.Wait(ctx, n)
			}
		}()
	}
	wg.Wait()
	for i := 0; i < n; i++ {
		if errs[i] != nil {
			t.Fatal(errs[i])
		}
		for j, p := range res[i] {
			if p.Rank != j || p.Shard != "s"+string(rune('0'+j)) {
				t.Fatalf("node %d sees rank %d as %+v", i, j, p)
			}
		}
	}
	// Another run's records (another location, so another token) do not match, and a missing
	// rank times out naming it.
	rv, _ := NewRendezvous(dir)
	rv.Location = dir + "-other"
	short, c2 := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer c2()
	if _, err := rv.Wait(short, n); err == nil {
		t.Fatal("records of another run accepted")
	}
	rv, _ = NewRendezvous(dir)
	rv.Poll = 10 * time.Millisecond
	if _, err := rv.Wait(short, n+1); err == nil {
		t.Fatal("a missing rank did not time out")
	}
}
