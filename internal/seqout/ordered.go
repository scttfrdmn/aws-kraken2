package seqout

// Ordered delivers items to a sink in sequence order (0, 1, 2, …) from any number of
// goroutines, in place of upstream's priority queue and output lock. Producers never wait on
// each other: Submit only sends on a channel, and one goroutine reorders and writes.
type Ordered[T any] struct {
	in   chan item[T]
	done chan error
}

type item[T any] struct {
	seq uint64
	v   T
}

// NewOrdered starts the writer goroutine. sink is called once per item, in sequence order;
// after its first error the remaining items are discarded. buffer is the channel depth.
func NewOrdered[T any](sink func(T) error, buffer int) *Ordered[T] {
	o := &Ordered[T]{in: make(chan item[T], buffer), done: make(chan error, 1)}
	go func() {
		pending := map[uint64]T{}
		var next uint64
		var err error
		for it := range o.in {
			if err != nil {
				continue
			}
			pending[it.seq] = it.v
			for {
				v, ok := pending[next]
				if !ok {
					break
				}
				delete(pending, next)
				next++
				if err = sink(v); err != nil {
					break
				}
			}
		}
		o.done <- err
	}()
	return o
}

// Submit hands over the item with sequence number seq. Each number must be submitted once.
func (o *Ordered[T]) Submit(seq uint64, v T) { o.in <- item[T]{seq, v} }

// Close waits until every submitted item has been written and returns the sink's first error.
// Items after a gap in the sequence are never written.
func (o *Ordered[T]) Close() error {
	close(o.in)
	return <-o.done
}
