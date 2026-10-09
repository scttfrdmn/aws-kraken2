# The sharded engine (G3, #24)

**What:** `bin/aws-kraken2` with the table sharded N ways. It has the same command line and the
same outputs as the plain path (Law 1 at every N: `make oracle-engine`, [oracle.md](oracle.md)).
It is selected by environment variables, so the command line stays upstream's. Code:
`internal/engine` (shards, router, transports, rendezvous, emitter protocol), `internal/objstore`
(S3 through the aws CLI, multipart writer), `cmd/aws-kraken2/{engine,cluster}.go`.

## Modes

| env | mode |
|---|---|
| `AK2_ENGINE_N=n` | n shards in one process; `AK2_ENGINE_TRANSPORT=local` (direct calls) or `tcp` (loopback servers) |
| `AK2_ENGINE_N=n AK2_ENGINE_RANK=r AK2_ENGINE_RENDEZVOUS=loc` | node r of an n-node run: one process per node, normally one per instance |

Shared settings:
- `AK2_ENGINE_TAIL=<cells>`: the overlap tail. The default is 302, RODA v205's longest run. The
  shard checks it at load: a tail too short for the table is an error, never a wrong answer.
- `AK2_TIMINGS=1`: `ak2-timing` phase lines and `ak2-engine` counters on stderr.

Node settings (`cmd/aws-kraken2/cluster.go`):
- `AK2_ENGINE_RENDEZVOUS`: `s3://bucket/prefix` (on AWS, the cohort prefix plus a per-invocation
  suffix) or a local directory.
- `AK2_ENGINE_LISTEN` / `AK2_ENGINE_ADVERTISE`: the address to listen on and the one peers dial.
  On AWS this is the private IP from IMDS.
- `AK2_ENGINE_HASH_URL`, `_ETAG`, `_SIZE`: load the shard from this object by ranged GETs with
  If-Match. This is RODA's public HTTPS URL, or a presigned URL of a staged copy. `hash.k2d`
  then need not exist locally.
- `AK2_ENGINE_VERIFY_ETAG=1`: check the ETag of hash.k2d against the loaded shards (see "ETag
  verification" below). It uses `AK2_ENGINE_HASH_ETAG`, which a local hash.k2d may also be given.
  The in-process engine verifies too. Setting it without `AK2_ENGINE_N` is a usage error.
  `AK2_ENGINE_ETAG_PART_BYTES=<n>` gives the part size.
- `AK2_ENGINE_WINDOW` (blocks, default 64): flow control.
- `AK2_ENGINE_TIMEOUT` (default 15m): the rendezvous, peer-accept and barrier deadline.

## What a node does

1. **Load:** shard r is the floor-cut slot range plus the tail, with wraparound, read by parallel
   ranged reads into off-heap huge-page memory, then the tail check. Phase `shard-load-<r>`.
2. **Identify:** the table id is SHA-256 of the size, the declared ETag, the header and 16 samples.
   Every connection's hello must carry the same id, so two tables of the same capacity cannot
   be mixed.
3. **Serve and publish:** the shard is served over TCP. The node writes
   `<rendezvous>/rank-<r>.json` (shard address, emitter address on rank 0, load seconds), polls
   until all n are there, and dials every other shard. Phases `rendezvous` and `connect`.
4. **Classify:** every node reads the whole input and cuts the same 8 MiB blocks. gzip cannot be
   split, so each node decompresses all of it; the time is the `read_s` counter, the gunzip cap.
   A node keeps the blocks with block mod n = r. Each block's lookups are batched by owner shard,
   sent, and gathered back in order, and the block is classified by the ported code. Phase
   `classify`.
5. **Emit:** home nodes send each classified block to rank 0, the emitter. The emitter writes the
   outputs in read order, either to local files as the plain path does, or to `s3://` outputs as
   one multipart upload each: parts of at least 8 MiB uploaded in the background, with part
   numbers in read order. Flow control: a node cuts its own block only within `WINDOW` blocks of
   the emitter's write position.
6. **Barrier and reduce:** every node sends Done with its per-taxon counters. The emitter
   sum-reduces them (zero-read taxa included) for the report, then sends Finish. No node exits
   while another may still need its shard. Phases `barrier`, `close`, `report`.

Counters (`AK2_TIMINGS=1`): `ak2-engine shard` (keys, batches, probe seconds, tail and wrap
probes); `route` (keys, batches, route, wait and gather seconds); `worker` (scan, lookup and
classify seconds); `node` (blocks cut and owned, `read_s`, window wait, bytes sent, emit wait and
emit seconds); `rendezvous` (object-store requests). Together with the spec's `ak2_phase` (boot,
setup, fetch) they give #25's decomposition: boot, load, scan, probe, gather, emit, tail.

## ETag verification (#49)

With `AK2_ENGINE_VERIFY_ETAG=1`, every arm checks the table's ETag, as upstream's arm runs
`scripts/lib/etagcheck.py` on its staged copy. Without it, the engine relies on If-Match alone.
The code is in `internal/engine/etag.go` and `cmd/aws-kraken2/etag.go`.

- **Format.** A multipart ETag is `md5(concat(md5(part_i)))-count`; a single-part ETag is the
  plain md5. The part size is not stored, so it is inferred as `etagcheck.py` does: the smallest
  power-of-two MiB size whose part count for the object's size equals the ETag's. RODA v205
  (`…-8860`, 1,189,091,671,800 bytes) has 128 MiB parts. `AK2_ENGINE_ETAG_PART_BYTES=<n>`
  gives the part size instead, for uploads whose parts are not a power-of-two MiB.
- **Unverifiable ETags.** Some ETags cannot be checked at all: one that is not an md5 (an SSE-KMS
  or SSE-C object's), or one whose part size cannot be inferred, or does not give its part count.
  These fail the run with `engine: ETag cannot be verified: …` (`engine.ErrETagFormat`), which is
  distinct from a mismatch.
- **The guarantee.** Every byte any node holds in memory is covered, and so is the header each
  node parsed. That means its owned cells, its overlap tail, and the last shard's wrapped tail.
  Each such byte either is one of the bytes the ETag was recomputed from, or is md5-equal to a
  copy of those bytes that is. No byte is counted twice in the ETag.
- **Who hashes what.** Node r of n owns the bytes of its owned slots, `[32 + lo·cb, 32 + hi·cb)`.
  Node 0's range starts at byte 0, so it includes the header, and node n−1's ends at the
  object's end. These ranges partition the object. Each node hashes exactly the parts that
  *start* in its range, by file offset: its *used* bytes. They come from the shard's unwrapped
  cells, from the header, and, for the node's last part, from **one extra ranged GET** of
  whatever lies past its cells.
- **Cross-checks** (no GET). Node q may hold bytes that another node r used for the ETag:
  - the head of q's own range, when r = q−1's last part straddles into it;
  - q's overlap tail, past its range;
  - the last shard's wrapped tail, at the table's start, which node 0 used.

  For every such pair (holder q, user r) and every interval where q's held cells meet r's used
  bytes, q publishes the md5 of its memory there, and r publishes the md5 of the bytes it used
  there. The two must both exist and be equal. Each node also publishes the md5 of the header it
  parsed, which must equal node 0's. A held byte inside the node's own used bytes is hashed from
  its memory directly. The intervals are computed from the cut, the tail and the part size, so
  every node must run with the same `AK2_ENGINE_TAIL`. If they do not, a check is one-sided and
  the run fails.
- **Combine.** Each node publishes its record in its rendezvous record as `etag_parts`:
  `rank`, `part_bytes`, `parts`, `first`, `md5[]`, `header_md5`, `held[]` and `used[]`. Each
  `held` and `used` entry is `holder`, `user`, `off`, `len` and `md5`. Once all records are in,
  every node, rank 0 included, assembles them. It checks that each part was hashed exactly once
  and that every cross-check pairs up and is equal, then recomputes the ETag and compares it.
  Any failure fails every node there, before any shard is dialled and before any sample is
  read: a mismatch, a differing copy, a missing record, a gap or a one-sided check. So no output
  object or multipart upload exists yet. The run exits 1 with `classify: engine: hash.k2d does
  not match its ETag: …` (`engine.ErrETagMismatch`). In-process, the one process hashes all its
  shards and combines.
- **Timing and counts.** The hashing is phase `etag`, after `shard-load-<r>` and before
  `rendezvous`; md5 runs on GOMAXPROCS goroutines. With `AK2_TIMINGS=1` the counter line is:

      ak2-engine etag etag <etag> computed <etag> part_bytes <n> parts <n> hashed <n> requests <n> retries <n> bytes <n> cross_bytes <n> hash_s <s> combine_s <s>

  `requests`, `retries` and `bytes` are the source's counts over the phase, that is, the extra
  GET. The `load` line is snapshotted before the phase and excludes them. `cross_bytes` are the
  bytes hashed from memory for the cross-checks.
- **Cost on RODA v205** (default tail of 302 cells):

  | N | extra GETs | extra bytes | share of object | cross-check md5 bytes (both sides, from memory) |
  |---|---|---|---|---|
  | 1 | 0 | 0 | 0 | 0 |
  | 8 | 7 | 405,103,152 | 0.034% | 810,225,632 |
  | 32 | 31 | 1,736,506,368 | 0.15% | 3,473,090,048 |

  At N = 1 the shard holds the whole object. The last rank never fetches, because its range
  ends at the object's end. Each node also hashes about size/N bytes of md5 for its parts.
- **Memory.** The extra GET is buffered in memory while it is hashed. For a multipart ETag it is
  under one part (under 128 MiB on RODA). For a **single-part** ETag (the plain md5), rank 0
  hashes the whole object. Its one GET is everything past its own cells, about (N−1)/N of the
  object, held in memory at once. S3 gives an md5 ETag to a single-part object only up to 5 GiB,
  which bounds this.
- **Tests.**
  - `internal/engine/etag_test.go`: N = 1, 2, 3, 4 and 7 over 4- and 5-byte cells; part sizes
    that straddle cells, shard boundaries and tails; a wrapping last shard; single-part ETags;
    one-byte corruptions of the object.
  - The same file, for memory: a flip of every byte of every shard's memory at N = 2, 3 and 4,
    including Full shards at N = 3. This includes the review's case (N = 2, 1000-byte parts,
    offset 6035 in shard 1) and each shard's last tail cell. The object is intact, and every
    flip must fail with `ErrETagMismatch`.
  - `cmd/aws-kraken2/etag_test.go`: serves the viral hash.k2d through `k2probe serve-file`'s
    handler with a real 8 MiB-part ETag, which `etagcheck.py` checks. Outputs go to the fake S3.
    It runs 3 verified nodes against the plain path, and 2 nodes on a one-byte-corrupted object:
    both exit 1 with `ErrETagMismatch`, no outputs and no open uploads. It also covers the
    in-process engine (right ETag, wrong ETag, a given part size, a wrong part size, a non-md5
    ETag) and `AK2_ENGINE_VERIFY_ETAG=1` without `AK2_ENGINE_N`, which is a usage error.

## Security

The engine's TCP ports have no authentication. The **run token** is FNV-64a of the rendezvous
location (`Rendezvous.Token`), and anyone who knows the location can compute it, so it is **not a
secret**. With the table id, it only keeps a connection from reaching the wrong run, table or
shard by mistake. What protects the ports is the security group: on AWS, the default-VPC default
group, which admits only itself (plus 22/tcp and ICMP). `make run … NODES=n` refuses a group that
admits more (docs/run.md). The group is account-wide, so every `task run` instance in the region
can reach a running engine.

A presigned `AK2_ENGINE_HASH_URL` is a credential. Errors never carry its query string
(`rangeread.Redact`): the URL in `*url.Error`, the 412 and status messages, and S3 error bodies,
of which only the `<Code>` is kept, because a SignatureDoesNotMatch body echoes the credential.
Spec bodies must not log it.

## Cohort mode and the S3 clients

`AK2_COHORT=<manifest>` runs a whole sample list in one engine process per node, with the shard
loaded once. Samples are sample-parallel (each sample's home node is its emitter) or
block-striped (one control session per sample), with samples in flight per node and one
`ak2-sample` line each. See [cohort.md](cohort.md).
- **S3 clients.** `s3://` outputs go through aws-sdk-go-v2 by default (`AK2_S3_CLIENT=sdk`,
  concurrent parts from one process) or through the aws CLI (`cli`, a process per part, kept for
  the L1 comparison).
- **Allow-list.** The SDK store refuses any bucket not in `AK2_ALLOWED_BUCKETS`, the engine's own
  copy of the run harness's allow-list (the SDK bypasses the aws shim).
- **Connection phases.** A single multi-node invocation now times `connect` (the shards) and
  `connect-control` (the emitter sessions) separately.

## Failure

Each failure ends the run with exit 1 and a `classify: engine: …` message, rather than hanging:
- a shard whose tail is too short;
- a hello mismatch: shard, n, capacity, table id or run token;
- a lookup that times out (2 min) or a peer that disconnects;
- a node that ends without a block the emitter needs;
- a missing rendezvous record after the timeout;
- with `AK2_ENGINE_VERIFY_ETAG=1`: loaded bytes that do not give the ETag, a node's copy that
  differs from the copy another node hashed, an unverifiable ETag, or a record without
  `etag_parts`;
- a Result frame from a rank that does not own the block, for an input the run lacks, or sent
  twice;
- a Done whose per-input block and byte counts disagree with what arrived or with the emitter's
  own cut.

After an engine failure, the emitter aborts its `s3://` uploads instead of completing a truncated
object. An upstream-style data error (exit 65: malformed records, mates that differ) still
completes them, as upstream writes its outputs then. An output that stays empty is one
PutObject: the multipart upload is created with the first part, so an empty output has none.

## AWS runs

`make run GATE=g3 SPEC=runs/<spec>.json NODES=n` ([run.md](run.md), "Multi-node runs").
`runs/g3-std8.json` checks Standard-8 byte-identity at N = 2 and 4: rank 0 runs the same cases
through upstream at the pin afterwards and writes `out/identity.tsv`.
