package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"hash/fnv"
	"strings"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/objstore"
)

// Peer is one node's rendezvous record: where its shard server and its emitter listener are.
type Peer struct {
	Rank      int     `json:"rank"`
	N         int     `json:"n"`
	Run       string  `json:"run"` // the run token, hex
	Shard     string  `json:"shard_addr"`
	Emit      string  `json:"emit_addr"`
	Host      string  `json:"host"`
	PID       int     `json:"pid"`
	Published string  `json:"published"` // RFC 3339, UTC
	LoadS     float64 `json:"load_s"`    // seconds the node took to load its shard
}

// Rendezvous is peer discovery through an object store: each node writes
// <prefix>/rank-<r>.json once its shard is loaded and its servers listen, then polls for the
// others. The location is s3://bucket/prefix (the run prefix, so nothing stale can match) or,
// for local runs, a directory.
type Rendezvous struct {
	Store          objstore.Store
	Bucket, Prefix string
	Location       string
	Poll           time.Duration // default 1 s
	Requests       int64         // object-store requests made (Put and Get)
}

// NewRendezvous parses a location: s3://bucket/prefix uses objstore.FromEnv, anything else is a
// local directory.
func NewRendezvous(loc string) (*Rendezvous, error) {
	if strings.HasPrefix(loc, "s3://") {
		b, p, err := objstore.ParseURL(loc)
		if err != nil {
			return nil, err
		}
		return &Rendezvous{Store: objstore.FromEnv(), Bucket: b, Prefix: strings.TrimSuffix(p, "/"), Location: loc}, nil
	}
	if loc == "" {
		return nil, errors.New("engine: empty rendezvous location")
	}
	return &Rendezvous{Store: &objstore.Dir{Root: loc}, Bucket: "rendezvous", Prefix: "peers", Location: loc}, nil
}

// Token is the run token every node derives from the rendezvous location: FNV-64a of it.
func (r *Rendezvous) Token() uint64 {
	h := fnv.New64a()
	h.Write([]byte(r.Location))
	return h.Sum64()
}

func (r *Rendezvous) key(rank int) string { return fmt.Sprintf("%s/rank-%04d.json", r.Prefix, rank) }

// Publish writes this node's record.
func (r *Rendezvous) Publish(ctx context.Context, p Peer) error {
	p.Run = fmt.Sprintf("%016x", r.Token())
	p.Published = time.Now().UTC().Format(time.RFC3339Nano)
	b, _ := json.Marshal(p)
	r.Requests++
	return r.Store.Put(ctx, r.Bucket, r.key(p.Rank), b)
}

// Wait polls until every rank 0..n−1 has published, and returns their records by rank.
func (r *Rendezvous) Wait(ctx context.Context, n int) ([]Peer, error) {
	// Poll quickly at first (peers that are already up), backing off to Poll.
	maxPoll := r.Poll
	if maxPoll <= 0 {
		maxPoll = time.Second
	}
	poll := min(50*time.Millisecond, maxPoll)
	peers := make([]Peer, n)
	have := make([]bool, n)
	left := n
	for {
		for i := 0; i < n; i++ {
			if have[i] {
				continue
			}
			r.Requests++
			b, err := r.Store.Get(ctx, r.Bucket, r.key(i))
			if errors.Is(err, objstore.ErrNotFound) {
				continue
			}
			if err != nil {
				return nil, fmt.Errorf("engine: rendezvous rank %d: %w", i, err)
			}
			var p Peer
			if err := json.Unmarshal(b, &p); err != nil {
				return nil, fmt.Errorf("engine: rendezvous rank %d: %w", i, err)
			}
			if p.Rank != i || p.N != n || p.Run != fmt.Sprintf("%016x", r.Token()) {
				return nil, fmt.Errorf("engine: rendezvous rank %d record is for rank %d of %d, run %s", i, p.Rank, p.N, p.Run)
			}
			peers[i], have[i] = p, true
			left--
		}
		if left == 0 {
			return peers, nil
		}
		select {
		case <-ctx.Done():
			var missing []int
			for i, h := range have {
				if !h {
					missing = append(missing, i)
				}
			}
			return nil, fmt.Errorf("engine: rendezvous at %s: ranks %v never published: %w", r.Location, missing, ctx.Err())
		case <-time.After(poll):
		}
		poll = min(2*poll, maxPoll)
	}
}
