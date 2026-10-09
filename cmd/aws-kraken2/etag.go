package main

// ETag verification of the sharded load (#49): AK2_ENGINE_VERIFY_ETAG=1 checks the S3 ETag of
// hash.k2d (AK2_ENGINE_HASH_ETAG, the same ETag the ranged GETs send as If-Match) against the
// bytes the shards loaded, before the first sample (internal/engine/etag.go). Each node hashes
// the parts that start in its byte range plus its cross-checks (phase etag), publishes them in
// its rendezvous record, and every node, rank 0 included, combines all records and compares; a
// mismatch fails the run before any output is opened. In-process (no AK2_ENGINE_RANK) the one
// process hashes every shard and combines. AK2_ENGINE_ETAG_PART_BYTES=<n> gives the part size
// instead of inferring it.

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/chash"
	"github.com/scttfrdmn/aws-kraken2/internal/engine"
	"github.com/scttfrdmn/aws-kraken2/internal/rangeread"
)

// etagCheck is this process's part of the verification.
type etagCheck struct {
	tag      engine.ETag
	mine     []engine.PartDigests // this process's shards' records (one per shard)
	cost     engine.ETagCost      // summed over them
	computed string               // the combined ETag, once checked
	hashS    float64
	combineS float64
	// The source's counters over the phase: the extra GET, retries included.
	requests, retries, bytes int64
}

// srcCounters is a source's request accounting.
func srcCounters(src rangeread.Source) (requests, retries, bytes int64) {
	switch s := src.(type) {
	case *rangeread.HTTPSource:
		return s.Requests.Load(), s.Retries.Load(), s.Bytes.Load()
	case *rangeread.FileSource:
		return s.Requests.Load(), s.Retries.Load(), s.Bytes.Load()
	}
	return 0, 0, 0
}

// hashETag computes the records of the shards (phase etag).
func hashETag(ctx context.Context, conf *engineConf, h chash.Header, size int64, src rangeread.Source, shards []*engine.Shard) (*etagCheck, error) {
	tag, err := engine.ParseETagParts(conf.verifyTag, size, conf.etagPartBytes)
	if err != nil {
		return nil, err
	}
	p := phase("etag")
	t0 := time.Now()
	r0, t0r, b0 := srcCounters(src)
	ec := &etagCheck{tag: tag}
	hdr := engine.HeaderBytes(h)
	for _, s := range shards {
		d, c, err := s.HashParts(ctx, tag, hdr, src, conf.tail, 0)
		if err != nil {
			return nil, err
		}
		ec.mine = append(ec.mine, d)
		ec.cost.Parts += c.Parts
		ec.cost.ExtraRequests += c.ExtraRequests
		ec.cost.ExtraBytes += c.ExtraBytes
		ec.cost.CrossBytes += c.CrossBytes
	}
	r1, t1r, b1 := srcCounters(src)
	ec.requests, ec.retries, ec.bytes = r1-r0, t1r-t0r, b1-b0
	ec.hashS = time.Since(t0).Seconds()
	p.end()
	return ec, nil
}

// combine checks the records of every node (or every in-process shard), by rank.
func (ec *etagCheck) combine(ds []engine.PartDigests) error {
	t0 := time.Now()
	got, err := ec.tag.Combine(ds)
	ec.combineS = time.Since(t0).Seconds()
	ec.computed = got
	return err
}

// combinePeers is combine over the rendezvous records: every rank must have published its record.
func (ec *etagCheck) combinePeers(peers []engine.Peer) error {
	ds := make([]engine.PartDigests, len(peers))
	for i, p := range peers {
		if p.ETagParts == nil {
			return fmt.Errorf("engine: etag: rank %d published no part digests (is AK2_ENGINE_VERIFY_ETAG set on every node?)", i)
		}
		ds[i] = *p.ETagParts
	}
	return ec.combine(ds)
}

// report writes (AK2_TIMINGS=1):
//
//	ak2-engine etag etag <etag> computed <etag> part_bytes <n> parts <n> hashed <n>
//	           requests <n> retries <n> bytes <n> cross_bytes <n> hash_s <s> combine_s <s>
//
// hashed counts the parts this process hashed. requests, retries and bytes are the source's
// over the etag phase: the one ranged GET per node past its shard (the load line excludes
// them). cross_bytes are the bytes hashed for the cross-checks (from memory, no GET).
func (ec *etagCheck) report() {
	if ec == nil || !timingsOn {
		return
	}
	fmt.Fprintf(os.Stderr, "ak2-engine\tetag\tetag\t%s\tcomputed\t%s\tpart_bytes\t%d\tparts\t%d\thashed\t%d\trequests\t%d\tretries\t%d\tbytes\t%d\tcross_bytes\t%d\thash_s\t%.6f\tcombine_s\t%.6f\n",
		ec.tag.Raw, ec.computed, ec.tag.PartSize, ec.tag.Parts, ec.cost.Parts, ec.requests, ec.retries, ec.bytes,
		ec.cost.CrossBytes, ec.hashS, ec.combineS)
}
