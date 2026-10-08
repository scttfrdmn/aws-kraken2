// Package objstore is the engine's object-store access (G3, #24): small objects (the peer
// rendezvous) and multipart uploads (each sample's outputs). It has two backends:
//
//   - CLI runs the aws CLI (aws s3api …). On an instance launched by make run, the CLI is
//     found through PATH, so the run harness's bucket allow-list shim (docs/run.md) covers every
//     request the engine makes, and the credentials are the CLI's own.
//   - Dir emulates a bucket in a local directory (Dir/<bucket>/<key>), with multipart parts kept
//     as files until Complete assembles them in part order. Local tests and make
//     oracle-engine use it; it applies S3's part rules (numbers 1..10000, ascending at
//     Complete, every part but the last at least MinPartSize).
package objstore

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
)

// MinPartSize is S3's smallest part other than the last.
const MinPartSize = 5 << 20

// ErrNotFound is Get's error for a missing object.
var ErrNotFound = errors.New("objstore: no such object")

// Part is one uploaded part.
type Part struct {
	Number int
	ETag   string
	Size   int64
}

// Store is an object store.
type Store interface {
	Put(ctx context.Context, bucket, key string, data []byte) error
	Get(ctx context.Context, bucket, key string) ([]byte, error)
	CreateMultipart(ctx context.Context, bucket, key string) (uploadID string, err error)
	UploadPart(ctx context.Context, bucket, key, uploadID string, number int, data []byte) (etag string, err error)
	Complete(ctx context.Context, bucket, key, uploadID string, parts []Part) error
	Abort(ctx context.Context, bucket, key, uploadID string) error
}

// ParseURL splits s3://bucket/key.
func ParseURL(u string) (bucket, key string, err error) {
	rest, ok := strings.CutPrefix(u, "s3://")
	if !ok {
		return "", "", fmt.Errorf("objstore: %q is not an s3:// URL", u)
	}
	bucket, key, _ = strings.Cut(rest, "/")
	if bucket == "" || key == "" {
		return "", "", fmt.Errorf("objstore: %q needs a bucket and a key", u)
	}
	return bucket, key, nil
}

// FromEnv returns the store the engine uses by default: Open("") (AK2_S3_EMULATE, else
// AK2_S3_CLIENT, default sdk, behind the AK2_ALLOWED_BUCKETS guard). A configuration error is
// returned by every call on the store.
func FromEnv() Store {
	st, err := Open("")
	if err != nil {
		return errStore{err}
	}
	return st
}

type errStore struct{ err error }

func (e errStore) Put(context.Context, string, string, []byte) error               { return e.err }
func (e errStore) Get(context.Context, string, string) ([]byte, error)             { return nil, e.err }
func (e errStore) CreateMultipart(context.Context, string, string) (string, error) { return "", e.err }
func (e errStore) UploadPart(context.Context, string, string, string, int, []byte) (string, error) {
	return "", e.err
}
func (e errStore) Complete(context.Context, string, string, string, []Part) error { return e.err }
func (e errStore) Abort(context.Context, string, string, string) error            { return e.err }

// ---- CLI ----------------------------------------------------------------------------------

// CLI runs the aws CLI found through PATH.
type CLI struct {
	Region string
}

func (c *CLI) run(ctx context.Context, stdin []byte, args ...string) ([]byte, error) {
	if c.Region != "" {
		args = append([]string{"--region", c.Region}, args...)
	}
	cmd := exec.CommandContext(ctx, "aws", args...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("objstore: aws %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

// bodyFile writes data to a temporary file for --body (the CLI reads parts from a file).
func bodyFile(data []byte) (string, func(), error) {
	f, err := os.CreateTemp("", "ak2-part-*")
	if err != nil {
		return "", nil, err
	}
	name := f.Name()
	cleanup := func() { os.Remove(name) }
	if _, err := f.Write(data); err != nil {
		f.Close()
		cleanup()
		return "", nil, err
	}
	if err := f.Close(); err != nil {
		cleanup()
		return "", nil, err
	}
	return name, cleanup, nil
}

// Put implements Store.
func (c *CLI) Put(ctx context.Context, bucket, key string, data []byte) error {
	CLICounts.Put.Add(1)
	name, cleanup, err := bodyFile(data)
	if err != nil {
		return err
	}
	defer cleanup()
	_, err = c.run(ctx, nil, "s3api", "put-object", "--bucket", bucket, "--key", key, "--body", name)
	return err
}

// Get implements Store.
func (c *CLI) Get(ctx context.Context, bucket, key string) ([]byte, error) {
	CLICounts.Get.Add(1)
	f, err := os.CreateTemp("", "ak2-get-*")
	if err != nil {
		return nil, err
	}
	name := f.Name()
	f.Close()
	defer os.Remove(name)
	if _, err := c.run(ctx, nil, "s3api", "get-object", "--bucket", bucket, "--key", key, name); err != nil {
		if strings.Contains(err.Error(), "NoSuchKey") || strings.Contains(err.Error(), "Not Found") {
			return nil, ErrNotFound
		}
		return nil, err
	}
	return os.ReadFile(name)
}

// CreateMultipart implements Store.
func (c *CLI) CreateMultipart(ctx context.Context, bucket, key string) (string, error) {
	CLICounts.Create.Add(1)
	out, err := c.run(ctx, nil, "s3api", "create-multipart-upload", "--bucket", bucket, "--key", key)
	if err != nil {
		return "", err
	}
	var r struct{ UploadId string }
	if err := json.Unmarshal(out, &r); err != nil || r.UploadId == "" {
		return "", fmt.Errorf("objstore: create-multipart-upload: no UploadId in %q", out)
	}
	return r.UploadId, nil
}

// UploadPart implements Store.
func (c *CLI) UploadPart(ctx context.Context, bucket, key, id string, n int, data []byte) (string, error) {
	CLICounts.Part.Add(1)
	CLICounts.PartBytes.Add(int64(len(data)))
	name, cleanup, err := bodyFile(data)
	if err != nil {
		return "", err
	}
	defer cleanup()
	out, err := c.run(ctx, nil, "s3api", "upload-part", "--bucket", bucket, "--key", key, "--upload-id", id,
		"--part-number", strconv.Itoa(n), "--body", name)
	if err != nil {
		return "", err
	}
	var r struct{ ETag string }
	if err := json.Unmarshal(out, &r); err != nil || r.ETag == "" {
		return "", fmt.Errorf("objstore: upload-part %d: no ETag in %q", n, out)
	}
	return r.ETag, nil
}

// Complete implements Store.
func (c *CLI) Complete(ctx context.Context, bucket, key, id string, parts []Part) error {
	CLICounts.Complete.Add(1)
	type p struct {
		ETag       string
		PartNumber int
	}
	var m struct{ Parts []p }
	for _, x := range parts {
		m.Parts = append(m.Parts, p{x.ETag, x.Number})
	}
	js, _ := json.Marshal(m)
	name, cleanup, err := bodyFile(js)
	if err != nil {
		return err
	}
	defer cleanup()
	_, err = c.run(ctx, nil, "s3api", "complete-multipart-upload", "--bucket", bucket, "--key", key,
		"--upload-id", id, "--multipart-upload", "file://"+name)
	return err
}

// Abort implements Store.
func (c *CLI) Abort(ctx context.Context, bucket, key, id string) error {
	CLICounts.Abort.Add(1)
	_, err := c.run(ctx, nil, "s3api", "abort-multipart-upload", "--bucket", bucket, "--key", key, "--upload-id", id)
	return err
}

// ---- Dir ----------------------------------------------------------------------------------

// Dir emulates S3 under Root.
type Dir struct {
	Root string
}

// uploadSeq numbers emulated uploads across every Dir in the process.
var uploadSeq atomic.Int64

func (d *Dir) path(bucket, key string) (string, error) {
	p := filepath.Join(d.Root, bucket, filepath.FromSlash(key))
	if !strings.HasPrefix(p, filepath.Clean(d.Root)+string(filepath.Separator)) {
		return "", fmt.Errorf("objstore: key %q escapes the emulated bucket", key)
	}
	return p, nil
}

func writeAtomic(p string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp := p + ".tmp-" + strconv.Itoa(os.Getpid())
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

// Put implements Store.
func (d *Dir) Put(_ context.Context, bucket, key string, data []byte) error {
	p, err := d.path(bucket, key)
	if err != nil {
		return err
	}
	return writeAtomic(p, data)
}

// Get implements Store.
func (d *Dir) Get(_ context.Context, bucket, key string) ([]byte, error) {
	p, err := d.path(bucket, key)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return b, err
}

func (d *Dir) uploadDir(id string) string { return filepath.Join(d.Root, ".uploads", id) }

// CreateMultipart implements Store.
func (d *Dir) CreateMultipart(_ context.Context, bucket, key string) (string, error) {
	if _, err := d.path(bucket, key); err != nil {
		return "", err
	}
	id := fmt.Sprintf("u%d-%d", os.Getpid(), uploadSeq.Add(1))
	if err := os.MkdirAll(d.uploadDir(id), 0o755); err != nil {
		return "", err
	}
	return id, os.WriteFile(filepath.Join(d.uploadDir(id), "target"), []byte(bucket+"/"+key), 0o644)
}

// UploadPart implements Store.
func (d *Dir) UploadPart(_ context.Context, bucket, key, id string, n int, data []byte) (string, error) {
	if n < 1 || n > 10000 {
		return "", fmt.Errorf("objstore: part number %d outside 1..10000", n)
	}
	t, err := os.ReadFile(filepath.Join(d.uploadDir(id), "target"))
	if err != nil || string(t) != bucket+"/"+key {
		return "", fmt.Errorf("objstore: no upload %s for %s/%s", id, bucket, key)
	}
	if err := writeAtomic(filepath.Join(d.uploadDir(id), fmt.Sprintf("part-%05d", n)), data); err != nil {
		return "", err
	}
	return fmt.Sprintf("etag-%d-%d", n, len(data)), nil
}

// Complete implements Store: S3's checks, then the parts concatenated in order.
func (d *Dir) Complete(_ context.Context, bucket, key, id string, parts []Part) error {
	if len(parts) == 0 {
		return errors.New("objstore: complete with no parts")
	}
	var out []byte
	for i, p := range parts {
		if i > 0 && p.Number <= parts[i-1].Number {
			return fmt.Errorf("objstore: parts not ascending at %d", p.Number)
		}
		b, err := os.ReadFile(filepath.Join(d.uploadDir(id), fmt.Sprintf("part-%05d", p.Number)))
		if err != nil {
			return fmt.Errorf("objstore: part %d: %w", p.Number, err)
		}
		if p.ETag != fmt.Sprintf("etag-%d-%d", p.Number, len(b)) {
			return fmt.Errorf("objstore: part %d ETag %q does not match", p.Number, p.ETag)
		}
		if i < len(parts)-1 && len(b) < MinPartSize {
			return fmt.Errorf("objstore: part %d is %d bytes, below S3's minimum for a non-final part (EntityTooSmall)", p.Number, len(b))
		}
		out = append(out, b...)
	}
	p, err := d.path(bucket, key)
	if err != nil {
		return err
	}
	if err := writeAtomic(p, out); err != nil {
		return err
	}
	return os.RemoveAll(d.uploadDir(id))
}

// Abort implements Store.
func (d *Dir) Abort(_ context.Context, _, _, id string) error {
	if id == "" || strings.ContainsAny(id, `/\.`) {
		return fmt.Errorf("objstore: no upload %q", id)
	}
	return os.RemoveAll(d.uploadDir(id))
}

// Pending lists the emulated uploads not completed or aborted (tests: none may be left).
func (d *Dir) Pending() []string {
	es, _ := os.ReadDir(filepath.Join(d.Root, ".uploads"))
	var ids []string
	for _, e := range es {
		ids = append(ids, e.Name())
	}
	sort.Strings(ids)
	return ids
}
