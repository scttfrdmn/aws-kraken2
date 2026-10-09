# The ladder lever library (`scripts/g3/lever.sh`)

**What:** the deployment levers that the #25 ladder rungs switch, one shell function per lever,
shared by both arms (stock and ours). A rung's body sources the library and calls each lever
with the rung's choice as an argument. Lever choices travel in the payload, never in env.
Every call records what it did and counts its S3 requests. The ladder body, generator and
lever table (#51) are built on it. This is a stub runbook: the library and its test only.

```bash
make lever-test        # AL2023 in podman, under the preamble; record in results/rehearse/
```

## Use from a body

```bash
cd "$W/repo" && . scripts/g3/lever.sh || exit 1   # after the preamble and the clone
lv_nvme raid /mnt/nvme
ak2_phase fetch-db
lv_stage_db awscp-classic s3://<bucket>/<prefix>/ "$LV_NVME/db"
lv_etag "$LV_NVME/db/hash.k2d" "$(lv_db_etag "$LV_NVME/db" hash.k2d)"   # its own phase
ak2_phase fetch-inputs
lv_fetch_inputs lanes16 "$LV_NVME/in" "$W/inputs.txt"
lv_gunzip_shim rapidgzip-P16
lv_upload_start s5cmd-overlap
#   ... per sample: classify, then lv_upload_enqueue OUT s3://<results bucket>/<key>
lv_upload_drain
```

The contract (signatures, modes, records, request-count basis and rehearsal seams) is the
header of `scripts/g3/lever.sh`. Changing it means changing #51 too.

| function | modes | stock (S0) | best |
|---|---|---|---|
| `lv_nvme MODE MOUNT` | `single`, `raid` | | |
| `lv_stage_db MODE SRC_URL DEST_DIR [FILE...]` | `awscp-classic`, `s5cmd` | `awscp-classic` | `s5cmd` (S1) |
| `lv_etag FILE EXPECTED` | (its own phase) | | |
| `lv_fetch_inputs MODE DEST MANIFEST` | `serial`, `lanes<K>` | `serial` | `lanes16` (S6) |
| `lv_upload_start MODE` / `_enqueue LOCAL S3URL` / `_drain` | `awscp-serial`, `s5cmd-overlap` | `awscp-serial` | `s5cmd-overlap` (S7) |
| `lv_gunzip_shim MODE` | `gzip`, `rapidgzip-P<k>` | `gzip` | `rapidgzip-P<k>` (S5) |
| `lv_s5 ARGS...` | the only way s5cmd is called | | |

## What it guarantees

- **Failures are surfaced.** Every failure returns non-zero and also goes through `ak2_err`,
  so the run's exit status carries it even if the body ignores the return code.
  - An upload that fails in the overlap lane is a lane failure. `lv_upload_drain` waits for the
    lane by PID and fails if the lane failed or any upload failed or is missing.
  - The lane stops if the body's shell is gone, so it cannot outlive a killed run.
- **Records.** Every call appends a JSON line to `$LV_DIR/lever.jsonl`, echoed into the run
  log as `lever {json}` (streamed by the preamble's pusher) and pushed to `out/lever.jsonl`.
  Uploads are rows of `out/lever-uploads.tsv`. A staged database's ETags and sizes are in
  `out/lever-db-<dir>-SOURCE`.
- **Law 1 across arms.** s5cmd's part size changes an object's S3 ETag, so the sha256 of every
  upload is computed on the node and recorded at enqueue, before the upload starts.
- **Bucket allow-list.** `lv_s5` refuses (rc 126) any `s3://BUCKET` outside
  `AK2_ALLOWED_BUCKETS`, in any argument, and the `run` subcommand. It is read-only to the body.
  The preamble's aws shim already covers the aws CLI.
- **Pins.**
  - s5cmd 2.3.0: the release tarball, checked against the release's `s5cmd_checksums.txt`
    (as probe (a)).
  - rapidgzip 0.14.5: a binary wheel (as probe (c)).
  - Both versions are checked after install and recorded.
  - The classic transfer client is forced by a private `AWS_CONFIG_FILE`, passed to each
    command that uses it and never exported. Its content is recorded.
- **Requests** are derived from sizes, as the rest of the repo counts them. The basis is in the
  header: the classic CLI's 8 MiB parts, and s5cmd's `--part-size`.

## The test (`make lever-test`)

`scripts/tests/lever_test.sh` builds `localhost/ak2-lever-test` (AL2023 with gzip, tar, perl,
diffutils and the rapidgzip 0.14.5 wheel; the tag is the Containerfile's hash). It then runs
`scripts/preamble.sh` followed by `scripts/tests/lever_body.sh` as `bash -e -c`, the way spawn
starts a body.

**Stand-ins**, only at the edges:
- curl answers IMDS and the bucket-region HEAD;
- aws and s5cmd are stubs over a shared directory. They log every call with its start and end
  times. Uploads under `up/` take 2 s and input gets take 0.4 s, so overlap and lane
  concurrency show in the timestamps;
- sudo runs the command;
- `AK2_REHEARSE_NVME`, `AK2_REHEARSE_S5CMD` and `AK2_REHEARSE_RAPIDGZIP` are set.

**Cases:**
- **main** must exit 0 with no helper errors. It checks:
  - the classic config is in effect, and s5cmd's flags;
  - the anonymous fallback;
  - the staged files are identical, and the request counts;
  - a real multipart ETag in its own phase;
  - serial and `lanes3` fetches both verify, with serial never overlapping and lanes
    overlapping;
  - the shim is byte-identical to `gzip -dc` on plain and multi-member gz, both directly and
    through perl's `open "gzip -dc FILE |"` as upstream's wrapper calls it, and rapidgzip
    really ran;
  - uploads: serial blocks (the contrast that shows the probe resolves the effect); the
    overlapped enqueue returns at once, upload 1 runs inside the body's next work, uploads run
    in enqueue order, and drain waits;
  - each sha256 is recorded before its upload and equals the object's.
- **refuse** checks five refusals, s5cmd never reached, and exit 126.
- **fail** checks a wrong ETag, a bad sha256, a failed lane upload and bad modes. Each must
  return non-zero, and the run must exit 1 with each failure in `helper-errors.tsv`.

The driver also checks that `lever.sh` passes `errexit_check.py` (run.sh does not check
sourced files) and that `lever {json}` lines streamed. `CASES="refuse"` runs one case, for
debugging; `KEEP=1` keeps the work dir.

**Not covered locally:**
- `lv_nvme` on real devices (mdadm, mkfs.xfs and mount). The test covers only its rehearsal
  seam.
- The s5cmd and rapidgzip downloads (seams replace them).
- Real S3 request counts.

All three are first exercised by the ladder rehearsal and the first ladder run (#53).
