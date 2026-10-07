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

## Failure

Each failure ends the run with exit 1 and a `classify: engine: …` message, rather than hanging:
- a shard whose tail is too short;
- a hello mismatch: shard, n, capacity, table id or run token;
- a lookup that times out (2 min) or a peer that disconnects;
- a node that ends without a block the emitter needs;
- a missing rendezvous record after the timeout.

## AWS runs

`make run GATE=g3 SPEC=runs/<spec>.json NODES=n` ([run.md](run.md), "Multi-node runs").
`runs/g3-std8.json` checks Standard-8 byte-identity at N = 2 and 4: rank 0 runs the same cases
through upstream at the pin afterwards and writes `out/identity.tsv`.
