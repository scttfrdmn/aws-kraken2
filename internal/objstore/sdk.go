package objstore

// SDK is the store through aws-sdk-go-v2 (pure Go): multipart parts upload concurrently from
// one process instead of an aws CLI process per part (G3 lever L1, #25). The SDK does not go
// through the run harness's aws PATH shim, so the bucket allow-list is enforced here instead
// (Guard, AK2_ALLOWED_BUCKETS).

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// SDK is an S3 store through aws-sdk-go-v2.
type SDK struct {
	Region   string
	Endpoint string // tests only: an S3-compatible endpoint, path-style, static test credentials

	once sync.Once
	cl   *s3.Client
	err  error
}

func (s *SDK) client(ctx context.Context) (*s3.Client, error) {
	s.once.Do(func() {
		opts := []func(*config.LoadOptions) error{
			// Checksums only where S3 requires them: the parts are verified by ETag at Complete,
			// and the default (a CRC on every request, aws-chunked bodies) is not needed.
			config.WithRequestChecksumCalculation(aws.RequestChecksumCalculationWhenRequired),
			config.WithResponseChecksumValidation(aws.ResponseChecksumValidationWhenRequired),
		}
		if s.Region != "" {
			opts = append(opts, config.WithRegion(s.Region))
		}
		if s.Endpoint != "" {
			opts = append(opts, config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider("test", "test", "")))
			if s.Region == "" {
				opts = append(opts, config.WithRegion("us-west-2"))
			}
		}
		cfg, err := config.LoadDefaultConfig(ctx, opts...)
		if err != nil {
			s.err = fmt.Errorf("objstore: sdk config: %w", err)
			return
		}
		s.cl = s3.NewFromConfig(cfg, func(o *s3.Options) {
			if s.Endpoint != "" {
				o.BaseEndpoint = aws.String(s.Endpoint)
				o.UsePathStyle = true
			}
		})
	})
	return s.cl, s.err
}

func notFound(err error) bool {
	var nk *types.NoSuchKey
	var nf *types.NotFound
	return errors.As(err, &nk) || errors.As(err, &nf)
}

// Put implements Store.
func (s *SDK) Put(ctx context.Context, bucket, key string, data []byte) error {
	cl, err := s.client(ctx)
	if err != nil {
		return err
	}
	_, err = cl.PutObject(ctx, &s3.PutObjectInput{Bucket: &bucket, Key: &key, Body: bytes.NewReader(data),
		ContentLength: aws.Int64(int64(len(data)))})
	if err != nil {
		return fmt.Errorf("objstore: put s3://%s/%s: %w", bucket, key, err)
	}
	return nil
}

// Get implements Store.
func (s *SDK) Get(ctx context.Context, bucket, key string) ([]byte, error) {
	cl, err := s.client(ctx)
	if err != nil {
		return nil, err
	}
	out, err := cl.GetObject(ctx, &s3.GetObjectInput{Bucket: &bucket, Key: &key})
	if err != nil {
		if notFound(err) {
			return nil, ErrNotFound
		}
		return nil, fmt.Errorf("objstore: get s3://%s/%s: %w", bucket, key, err)
	}
	defer out.Body.Close()
	return io.ReadAll(out.Body)
}

// CreateMultipart implements Store.
func (s *SDK) CreateMultipart(ctx context.Context, bucket, key string) (string, error) {
	cl, err := s.client(ctx)
	if err != nil {
		return "", err
	}
	out, err := cl.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{Bucket: &bucket, Key: &key})
	if err != nil {
		return "", fmt.Errorf("objstore: create-multipart-upload s3://%s/%s: %w", bucket, key, err)
	}
	if out.UploadId == nil || *out.UploadId == "" {
		return "", errors.New("objstore: create-multipart-upload returned no UploadId")
	}
	return *out.UploadId, nil
}

// UploadPart implements Store.
func (s *SDK) UploadPart(ctx context.Context, bucket, key, id string, n int, data []byte) (string, error) {
	cl, err := s.client(ctx)
	if err != nil {
		return "", err
	}
	out, err := cl.UploadPart(ctx, &s3.UploadPartInput{Bucket: &bucket, Key: &key, UploadId: &id,
		PartNumber: aws.Int32(int32(n)), Body: bytes.NewReader(data), ContentLength: aws.Int64(int64(len(data)))})
	if err != nil {
		return "", fmt.Errorf("objstore: upload-part %d of s3://%s/%s: %w", n, bucket, key, err)
	}
	if out.ETag == nil || *out.ETag == "" {
		return "", fmt.Errorf("objstore: upload-part %d returned no ETag", n)
	}
	return *out.ETag, nil
}

// Complete implements Store.
func (s *SDK) Complete(ctx context.Context, bucket, key, id string, parts []Part) error {
	cl, err := s.client(ctx)
	if err != nil {
		return err
	}
	cp := make([]types.CompletedPart, len(parts))
	for i, p := range parts {
		cp[i] = types.CompletedPart{ETag: aws.String(p.ETag), PartNumber: aws.Int32(int32(p.Number))}
	}
	_, err = cl.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{Bucket: &bucket, Key: &key, UploadId: &id,
		MultipartUpload: &types.CompletedMultipartUpload{Parts: cp}})
	if err != nil {
		return fmt.Errorf("objstore: complete-multipart-upload s3://%s/%s: %w", bucket, key, err)
	}
	return nil
}

// Abort implements Store.
func (s *SDK) Abort(ctx context.Context, bucket, key, id string) error {
	cl, err := s.client(ctx)
	if err != nil {
		return err
	}
	_, err = cl.AbortMultipartUpload(ctx, &s3.AbortMultipartUploadInput{Bucket: &bucket, Key: &key, UploadId: &id})
	return err
}

// Guard refuses any operation on a bucket outside Allowed: the engine's own copy of the run
// harness's bucket allow-list, for clients the aws PATH shim cannot see (the SDK).
type Guard struct {
	Store   Store
	Allowed map[string]bool
}

func (g Guard) check(bucket string) error {
	if !g.Allowed[bucket] {
		return fmt.Errorf("objstore: bucket %q is not in AK2_ALLOWED_BUCKETS; refused", bucket)
	}
	return nil
}

// Put implements Store.
func (g Guard) Put(ctx context.Context, b, k string, d []byte) error {
	if err := g.check(b); err != nil {
		return err
	}
	return g.Store.Put(ctx, b, k, d)
}

// Get implements Store.
func (g Guard) Get(ctx context.Context, b, k string) ([]byte, error) {
	if err := g.check(b); err != nil {
		return nil, err
	}
	return g.Store.Get(ctx, b, k)
}

// CreateMultipart implements Store.
func (g Guard) CreateMultipart(ctx context.Context, b, k string) (string, error) {
	if err := g.check(b); err != nil {
		return "", err
	}
	return g.Store.CreateMultipart(ctx, b, k)
}

// UploadPart implements Store.
func (g Guard) UploadPart(ctx context.Context, b, k, id string, n int, d []byte) (string, error) {
	if err := g.check(b); err != nil {
		return "", err
	}
	return g.Store.UploadPart(ctx, b, k, id, n, d)
}

// Complete implements Store.
func (g Guard) Complete(ctx context.Context, b, k, id string, p []Part) error {
	if err := g.check(b); err != nil {
		return err
	}
	return g.Store.Complete(ctx, b, k, id, p)
}

// Abort implements Store.
func (g Guard) Abort(ctx context.Context, b, k, id string) error {
	if err := g.check(b); err != nil {
		return err
	}
	return g.Store.Abort(ctx, b, k, id)
}

// allowed parses AK2_ALLOWED_BUCKETS (space-separated bucket names).
func allowed() map[string]bool {
	m := map[string]bool{}
	for _, b := range strings.Fields(os.Getenv("AK2_ALLOWED_BUCKETS")) {
		m[b] = true
	}
	return m
}

// Open returns the store for client "sdk", "cli" or "" (AK2_S3_CLIENT, default sdk):
//   - AK2_S3_EMULATE=<dir>: the local emulation, whatever the client;
//   - sdk: aws-sdk-go-v2 (AK2_S3_ENDPOINT, tests only, points it at an S3-compatible server),
//     always behind Guard: with no AK2_ALLOWED_BUCKETS it refuses every bucket;
//   - cli: the aws CLI (the shim sees it), also behind Guard when AK2_ALLOWED_BUCKETS is set.
func Open(client string) (Store, error) {
	if d := os.Getenv("AK2_S3_EMULATE"); d != "" {
		return &Dir{Root: d}, nil
	}
	if client == "" {
		client = os.Getenv("AK2_S3_CLIENT")
	}
	region := os.Getenv("AK2_REGION")
	if region == "" {
		region = os.Getenv("AWS_REGION")
	}
	al := allowed()
	switch client {
	case "", "sdk":
		return Guard{Store: &SDK{Region: region, Endpoint: os.Getenv("AK2_S3_ENDPOINT")}, Allowed: al}, nil
	case "cli":
		var st Store = &CLI{Region: region}
		if len(al) > 0 {
			st = Guard{Store: st, Allowed: al}
		}
		return st, nil
	}
	return nil, fmt.Errorf("objstore: S3 client %q: want sdk or cli", client)
}
