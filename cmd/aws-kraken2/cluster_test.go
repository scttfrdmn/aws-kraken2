package main

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/engine"
	"github.com/scttfrdmn/aws-kraken2/internal/seqout"
)

func seqoutBatch(c1 string) seqout.Batch { return seqout.Batch{C1: []byte(c1)} }

// takeAsync runs inbox.take in the background.
func takeAsync(b *inbox, k bkey, home int) chan error {
	ch := make(chan error, 1)
	go func() {
		r, ok, err := b.take(k, home)
		switch {
		case err != nil:
			ch <- err
		case !ok:
			ch <- errors.New("past the end")
		case r == nil:
			ch <- errors.New("nil block")
		default:
			ch <- nil
		}
	}()
	return ch
}

func waitFor(t *testing.T, ch chan error) error {
	t.Helper()
	select {
	case err := <-ch:
		return err
	case <-time.After(5 * time.Second):
		t.Fatal("take did not return")
	}
	return nil
}

func pending(ch chan error) bool {
	select {
	case <-ch:
		return false
	case <-time.After(50 * time.Millisecond):
		return true
	}
}

// TestInboxDoneBeforeCut: a node's Done is an error for a block only once the emitter's own cut
// shows the block exists (the bz2 case at N=8: the cut was behind, rank 6 had no block 6).
func TestInboxDoneBeforeCut(t *testing.T) {
	b := newInbox(7, 3, func() bool { return false })
	b.setCut(0, 6)
	b.mu.Lock()
	b.done[6] = &engine.Done{}
	b.mu.Unlock()
	ch := takeAsync(b, bkey{0, 6}, 6)
	if !pending(ch) {
		t.Fatal("take of a block beyond the cut so far returned instead of waiting for the cut")
	}
	b.setTotal(0, 6) // the input has blocks 0..5: block 6 does not exist
	if err := waitFor(t, ch); err == nil || err.Error() != "past the end" {
		t.Fatalf("block past the end: %v", err)
	}
	// A block the cut has passed, from a node that is done without it, is an error.
	b.setCut(1, 10)
	if err := waitFor(t, takeAsync(b, bkey{1, 6}, 6)); err == nil || !strings.Contains(err.Error(), "without block 6") {
		t.Fatalf("missing block: %v", err)
	}
	// A block that arrives is taken, whatever the cut.
	ch = takeAsync(b, bkey{2, 3}, 3)
	if !pending(ch) {
		t.Fatal("take returned before the block arrived")
	}
	if err := b.put(bkey{2, 3}, &result{seq: 3}, 3); err != nil {
		t.Fatal(err)
	}
	if err := waitFor(t, ch); err != nil {
		t.Fatal(err)
	}
	// A lost node fails a wait for its block.
	ch = takeAsync(b, bkey{2, 5}, 5)
	b.mu.Lock()
	b.lost[5] = errors.New("EOF")
	b.mu.Unlock()
	b.wake()
	if err := waitFor(t, ch); err == nil || !strings.Contains(err.Error(), "lost rank 5") {
		t.Fatalf("lost node: %v", err)
	}
}

// TestInboxValidates: a block from a rank that does not own it, for an input the run does not
// have, or sent twice, is refused; Done must match what arrived and the emitter's cut.
func TestInboxValidates(t *testing.T) {
	b := newInbox(3, 2, func() bool { return false })
	if err := b.put(bkey{0, 4}, &result{}, 2); err == nil || !strings.Contains(err.Error(), "belongs to rank 1") {
		t.Fatalf("wrong rank: %v", err)
	}
	if err := b.put(bkey{2, 1}, &result{}, 1); err == nil || !strings.Contains(err.Error(), "the run has 2") {
		t.Fatalf("input out of range: %v", err)
	}
	if err := b.put(bkey{0, 1}, &result{kraken: []byte("abc")}, 1); err != nil {
		t.Fatal(err)
	}
	if err := b.put(bkey{0, 1}, &result{}, 1); err == nil || !strings.Contains(err.Error(), "twice") {
		t.Fatalf("duplicate: %v", err)
	}
	if err := b.put(bkey{0, 4}, &result{batch: seqoutBatch("xy")}, 1); err != nil {
		t.Fatal(err)
	}
	b.setTotal(0, 6) // blocks 0..5: rank 1 owns 1 and 4
	b.setTotal(1, 1) // rank 1 owns none of input 1
	b.mu.Lock()
	defer b.mu.Unlock()
	ok := &engine.Done{Files: []engine.FileCount{{Blocks: 2, Bytes: 5}, {}}}
	if err := b.checkDone(1, ok, 2); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []*engine.Done{
		{Files: []engine.FileCount{{Blocks: 2, Bytes: 5}}},              // an input missing
		{Files: []engine.FileCount{{Blocks: 3, Bytes: 5}, {}}},          // more blocks than the cut gives it
		{Files: []engine.FileCount{{Blocks: 2, Bytes: 6}, {}}},          // bytes differ from what arrived
		{Files: []engine.FileCount{{Blocks: 2, Bytes: 5}, {Blocks: 1}}}, // a block of input 1 it does not own
	} {
		if err := b.checkDone(1, bad, 2); err == nil {
			t.Fatalf("Done %+v accepted", bad.Files)
		}
	}
	if got := owned(6, 1, 3); got != 2 {
		t.Fatalf("owned(6, 1, 3) = %d", got)
	}
	if got := owned(1, 2, 3); got != 0 {
		t.Fatalf("owned(1, 2, 3) = %d", got)
	}
}
