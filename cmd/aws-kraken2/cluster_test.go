package main

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/engine"
)

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
	b := newInbox(func() bool { return false })
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
	b.put(bkey{2, 3}, &result{seq: 3})
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
