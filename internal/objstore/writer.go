package objstore

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"
)

// DefaultPartSize is the engine's part size: every part but the last is at least this big.
const DefaultPartSize = 8 << 20

// Writer is one object written as a multipart upload, in order: the bytes given to Write, in
// the order given, become parts 1, 2, … of at least PartSize (the last part any size). Parts
// upload in the background, at most InFlight at once; Write blocks only when that many are
// already in flight (bounded memory). Writer is not safe for concurrent Write calls: its caller
// is the sequencer that orders the output.
type Writer struct {
	st          Store
	ctx         context.Context
	bucket, key string
	id          string
	partSize    int
	buf         []byte
	next        int
	total       int64
	sem         chan struct{}
	wg          sync.WaitGroup
	mu          sync.Mutex
	parts       []Part
	err         error
	done        bool

	// Stats.
	UploadNs, BlockedNs int64 // summed part-upload time; time Write waited for a slot
}

// NewWriter returns a writer for s3://bucket/key. The multipart upload is created with the
// first part, so an object that stays empty never has one (and needs no Abort, which the
// instance role is not granted).
func NewWriter(ctx context.Context, st Store, url string, partSize, inFlight int) (*Writer, error) {
	b, k, err := ParseURL(url)
	if err != nil {
		return nil, err
	}
	if partSize < MinPartSize {
		return nil, fmt.Errorf("objstore: part size %d below S3's minimum %d", partSize, MinPartSize)
	}
	return &Writer{st: st, ctx: ctx, bucket: b, key: k, partSize: partSize, next: 1,
		sem: make(chan struct{}, max(inFlight, 1))}, nil
}

// size is part n's target size: PartSize, doubled every 1000 parts so that 10000 parts reach
// far beyond any sample's output.
func (w *Writer) size(n int) int { return min(w.partSize<<((n-1)/1000), 5<<30) }

// Write appends p to the object.
func (w *Writer) Write(p []byte) (int, error) {
	if err := w.Err(); err != nil {
		return 0, err
	}
	w.buf = append(w.buf, p...)
	w.total += int64(len(p))
	for len(w.buf) >= w.size(w.next) {
		n := w.size(w.next)
		part := make([]byte, n)
		copy(part, w.buf[:n])
		w.buf = append(w.buf[:0], w.buf[n:]...)
		if err := w.upload(part); err != nil {
			return len(p), err
		}
	}
	return len(p), nil
}

func (w *Writer) upload(data []byte) error {
	n := w.next
	if n > 10000 {
		return w.fail(fmt.Errorf("objstore: s3://%s/%s needs more than 10000 parts", w.bucket, w.key))
	}
	if w.id == "" {
		id, err := w.st.CreateMultipart(w.ctx, w.bucket, w.key)
		if err != nil {
			return w.fail(fmt.Errorf("objstore: s3://%s/%s: %w", w.bucket, w.key, err))
		}
		w.id = id
	}
	w.next++
	t := time.Now()
	w.sem <- struct{}{}
	w.mu.Lock()
	w.BlockedNs += int64(time.Since(t))
	w.mu.Unlock()
	w.wg.Add(1)
	go func() {
		defer func() { <-w.sem; w.wg.Done() }()
		t := time.Now()
		etag, err := w.st.UploadPart(w.ctx, w.bucket, w.key, w.id, n, data)
		w.mu.Lock()
		defer w.mu.Unlock()
		w.UploadNs += int64(time.Since(t))
		if err != nil {
			if w.err == nil {
				w.err = fmt.Errorf("objstore: s3://%s/%s part %d: %w", w.bucket, w.key, n, err)
			}
			return
		}
		w.parts = append(w.parts, Part{Number: n, ETag: etag, Size: int64(len(data))})
	}()
	return nil
}

func (w *Writer) fail(err error) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.err == nil {
		w.err = err
	}
	return w.err
}

// Err is the first upload error.
func (w *Writer) Err() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.err
}

// Parts returns the uploaded parts in number order (after Close).
func (w *Writer) Parts() []Part {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]Part(nil), w.parts...)
}

// Size is the number of bytes written.
func (w *Writer) Size() int64 { return w.total }

// Close uploads the last part and completes the upload. An object with no bytes cannot be a
// multipart upload (S3 needs at least one part; a lone empty part is not portable), and has
// none (it is created with the first part), so it is written with one PutObject. On any error
// the upload is aborted (best effort: make run aborts what is left, docs/run.md).
func (w *Writer) Close() error {
	if w.done {
		return w.Err()
	}
	w.done = true
	if w.total == 0 {
		if err := w.st.Put(w.ctx, w.bucket, w.key, nil); err != nil {
			return w.fail(err)
		}
		return nil
	}
	if len(w.buf) > 0 {
		last := w.buf
		w.buf = nil
		if err := w.upload(last); err != nil {
			w.wg.Wait()
			w.abortUpload()
			return err
		}
	}
	w.wg.Wait()
	if err := w.Err(); err != nil {
		w.abortUpload()
		return err
	}
	w.mu.Lock()
	sort.Slice(w.parts, func(i, j int) bool { return w.parts[i].Number < w.parts[j].Number })
	parts := append([]Part(nil), w.parts...)
	w.mu.Unlock()
	if err := w.st.Complete(w.ctx, w.bucket, w.key, w.id, parts); err != nil {
		w.abortUpload()
		return w.fail(err)
	}
	return nil
}

// abortUpload aborts the multipart upload if one was created (best effort).
func (w *Writer) abortUpload() {
	if w.id != "" {
		_ = w.st.Abort(w.ctx, w.bucket, w.key, w.id)
	}
}

// Abort abandons the upload: no object is written. Without parts there is nothing to abort.
func (w *Writer) Abort() error {
	if w.done {
		return nil
	}
	w.done = true
	w.wg.Wait()
	if w.id == "" {
		return nil
	}
	return w.st.Abort(w.ctx, w.bucket, w.key, w.id)
}
