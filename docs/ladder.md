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
lv_stage_db awscp-default s3://<bucket>/<prefix>/ "$LV_NVME/db"
lv_etag "$LV_NVME/db/hash.k2d" "$(lv_db_etag "$LV_NVME/db" hash.k2d)"   # its own phase
ak2_phase fetch-inputs
lv_fetch_inputs lanes16 default "$LV_NVME/in" "$W/inputs.txt"   # S0's client, 16 lanes
lv_gunzip_shim rapidgzip-P16
lv_upload_start s5cmd-overlap
#   ... per sample: classify, then lv_upload_enqueue OUT s3://<results bucket>/<key>
#   (OUT must not change until lv_upload_drain)
lv_upload_drain
```

The contract (signatures, modes, records, request-count basis and rehearsal seams) is the
header of `scripts/g3/lever.sh`. Changing it means changing #51 too.

| function | modes | stock (S0) | rung |
|---|---|---|---|
| `lv_nvme MODE MOUNT` | `single`, `raid` | | |
| `lv_stage_db MODE SRC_URL DEST_DIR [FILE...]` | `awscp-default`, `awscp-classic`, `s5cmd` | `awscp-default` | S1: `s5cmd` |
| `lv_etag FILE EXPECTED` | (its own phase) | | |
| `lv_fetch_inputs MODE CLIENT DEST MANIFEST` | `serial`, `lanes<K>`; client `default`, `classic`, `crt` | `serial default` | S6: `lanes16 default` (the lanes only) |
| `lv_upload_start MODE` / `_enqueue LOCAL S3URL` / `_drain` | `awscp-default`, `awscp-classic` (alias `awscp-serial`), `awscp-overlap`, `s5cmd-serial`, `s5cmd-overlap` | `awscp-default` | S7a: `s5cmd-serial`; S7b: `s5cmd-overlap` |
| `lv_gunzip_shim MODE` | `gzip`, `rapidgzip-P<k>` | `gzip` | S5: `rapidgzip-P<k>` |
| `lv_s5 ARGS...` | the only way s5cmd is called | | |

**S7 is two rungs (Law 5: one lever per rung).** The upload mode is a tool and a schedule:

| | serial (enqueue uploads, returns when done) | overlap (one background lane) |
|---|---|---|
| aws CLI | `awscp-default` (S0), `awscp-classic` | `awscp-overlap` (default client) |
| s5cmd | `s5cmd-serial` (S7a: the tool) | `s5cmd-overlap` (S7b: the overlap) |

S7a changes only the tool (awscp-default → s5cmd-serial) and S7b only the schedule
(s5cmd-serial → s5cmd-overlap). `awscp-overlap` is the other order (schedule first), if #51
wants to check that the two levers compose.

## What it guarantees

- **Failures are surfaced.** Every failure returns non-zero and also goes through `ak2_err`,
  so the run's exit status carries it even if the body ignores the return code.
  - An upload that fails in the overlap lane is a lane failure. `lv_upload_drain` waits for the
    lane by PID and fails if the lane failed or any upload failed or is missing.
  - The lane checks at the top of every iteration that the body's shell is alive, so it cannot
    outlive a killed run. If drain cannot write the lane's END marker, it kills the lane and
    fails at once instead of leaving it to poll until the TTL.
- **Records.** Every call appends a JSON line to `$LV_DIR/lever.jsonl`, echoed into the run
  log as `lever {json}` (streamed by the preamble's pusher) and pushed to `out/lever.jsonl`.
  Uploads are rows of `out/lever-uploads.tsv`. A staged database's ETags and sizes are in
  `out/lever-db-<dir>-SOURCE`.
- **Law 1 across arms.** s5cmd's part size changes an object's S3 ETag, so the sha256 of every
  upload is computed on the node and recorded at enqueue, before the upload starts. The file
  must not change between enqueue and drain.
- **Bucket allow-list.** `lv_s5` refuses (rc 126):
  - any `s3://BUCKET` outside `AK2_ALLOWED_BUCKETS`, in any argument;
  - any argument equal to `run` (the run subcommand reads commands it cannot check);
  - `--endpoint-url` or `-endpoint-url` in any spelling, and a set `S3_ENDPOINT_URL`
    (another endpoint is another S3).

  Flags are parsed in both `--long` and `-long` spellings. `lv_s5` is read-only to the body.
  The preamble's aws shim already covers the aws CLI.
- **Pins, checked against hashes in lever.sh** (a checksum file from the same release would
  only catch corruption):
  - s5cmd 2.3.0: the release tarball's sha256 (`LV_S5_SHA256_arm64`, `LV_S5_SHA256_64bit`;
    checked on 2026-10-09 by hashing the downloaded tarballs, and equal to the release's
    checksum file). The tarball and binary sha256 are recorded.
  - rapidgzip 0.14.5: `pip download` then `pip install`, both `--require-hashes` against the
    sha256 of its manylinux wheels on PyPI (`LV_RG_HASHES`: aarch64 and x86_64, CPython 3.9,
    which is AL2023's python3, to 3.13). The wheel's and the extension's sha256 are recorded.
  - Both versions are checked after install.
- **Stock is the AMI's aws CLI as shipped.** The `default` client (`awscp-default`) runs `aws s3
  cp` with no config override; an `AWS_CONFIG_FILE` the body exported is removed for the call
  (`env -u`). `classic` and `crt` force that transfer client in a private `AWS_CONFIG_FILE`,
  passed to the one command and never exported. `classic` is available but not used by S0.
  `crt` also sets `multipart_chunksize = 8MB`.
  - The first use of each client records a line of kind `aws-client`: the CLI version, the
    config and its content (`none` for default), `aws configure get
    default.s3.preferred_transfer_client` (empty when nothing is configured; v2 then uses
    `auto`), the instance type, and `resolved` with `how`. For `default` it also records the
    AMI's own config: `~/.aws/config` and any file under `/etc/aws` (presence and content), and
    `~/.aws/credentials` (presence only).
  - `resolved` is the configured client if one is named, or `classic` for CLI v1. For v2 on
    `auto` it is the CLI's own rule, read from its source
    (`awscli/customizations/s3/factory.py`): CRT if `awscrt.s3.is_optimized_for_system()` and
    no other aws CLI process holds the CRT process lock
    (`_is_crt_client_running_in_other_aws_cli_process`), else classic. lever.sh checks that the
    source has this rule, evaluates the first part with the CLI's own python (the CLI must be a
    python script, as AL2023's rpm is: `#! /usr/bin/python3 -s`), and records the lock as a
    caveat in `how`. Otherwise `resolved` is `unknown`, with the reason.
  - It records `awscrt.s3.get_optimized_platforms()` (awscrt 0.36.4 in AL2023's rpm:
    trn1n.32xlarge, trn1.32xlarge, p6-b300.48xlarge, p6-b200.48xlarge, p5en.48xlarge,
    p5e.48xlarge, p5.48xlarge, p4de.24xlarge, p4d.24xlarge) and whether the host and the ladder
    types (r8gd.48xlarge, x8g.24xlarge) are on it. Neither ladder type is, so `default`
    resolves to classic on every ladder host.
- **Requests** are derived from sizes, as the rest of the repo counts them. For the aws CLI the
  basis is the classic client's algorithm: 8 MiB threshold and parts. It is exact only where
  classic ran. When a client resolves to `crt` or `unknown`, every op of its transfers is
  written as `<op>-estimate` in `requests.tsv` (for example `GetObject-estimate`), and the
  lever record has `estimate: true`, so they cannot be read as measurements. The head-objects
  lever.sh makes itself are always plain. For s5cmd the basis is its `--part-size`.

## The test (`make lever-test`)

`scripts/tests/lever_test.sh` builds `localhost/ak2-lever-test`: AL2023 with gzip, tar, perl,
diffutils and the `awscli-2` rpm, plus the rapidgzip 0.14.5 wheel (`/opt/wheels`) and the s5cmd
2.3.0 release tarball (`/opt/s5`) downloaded at build time. The tag is the Containerfile's
hash. It then runs `scripts/preamble.sh` followed by `scripts/tests/lever_body.sh` as
`bash -e -c`, the way spawn starts a body.

**Stand-ins**, only at the edges:
- curl answers IMDS and the bucket-region HEAD;
- aws and s5cmd are stubs over a shared directory. They log every call with its start and end
  times. Uploads under `up/` take 2 s and input gets take 0.4 s, so overlap and lane
  concurrency show in the timestamps;
- sudo runs the command;
- `AK2_REHEARSE_NVME` and `AK2_REHEARSE_S5CMD` (the stub) are set. `AK2_REHEARSE_WHEELS`
  points pip at the image's wheel dir, so rapidgzip goes through the real `--require-hashes`
  install. The s5cmd tarball pin is checked with `AK2_REHEARSE_S5CMD_TGZ` on the real tarball.

**Cases:**
- **main** must exit 0 with no helper errors. It checks:
  - `awscp-default` reaches the CLI with no config, even with a body-exported crt config, and
    records the AMI's `~/.aws/config`. `awscp-classic` runs under the classic config. s5cmd
    gets its flags. Each client is recorded;
  - the auto rule, evaluated against the image's real AL2023 `awscli-2` rpm, resolves to
    `classic` in a container. Its `how` names the CRT process lock, its platform list includes
    p4d.24xlarge, and both ladder types are off it;
  - estimates: the stub CLI resolves to `unknown`, so its transfers count as
    `GetObject-estimate` and similar, and `crt` fetches likewise. lever.sh's own head-objects
    stay plain;
  - fetch: the `default` client for serial and lanes, `crt` under its config with
    `multipart_chunksize = 8MB`;
  - the anonymous fallback;
  - the staged files are identical, and the request counts;
  - a real multipart ETag in its own phase;
  - serial and `lanes3` fetches both verify, with serial never overlapping and lanes
    overlapping;
  - the shim is byte-identical to `gzip -dc` on plain and multi-member gz, both directly and
    through perl's `open "gzip -dc FILE |"` as upstream's wrapper calls it. rapidgzip really
    ran, and was installed from a wheel whose sha256 is a pin. The record carries the paired
    concurrency (2 shims, 2k threads);
  - uploads:
    - serial blocks, for both `awscp-default`/`awscp-classic` and `s5cmd-serial` (the
      contrast that shows the probe resolves the effect);
    - `awscp-overlap` and `s5cmd-overlap` enqueue return at once, and upload 1 runs inside the
      body's next work;
    - uploads run in enqueue order, and drain waits;
  - each sha256 is recorded before its upload and equals the object's;
  - `lv_s5` finds the subcommand with single-dash flags;
  - the real s5cmd tarball installs against its pinned sha256.
- **refuse** checks nine refusals (undeclared buckets in any position, `run` as a subcommand
  and as any argument, `--endpoint-url`, `-endpoint-url=`, `S3_ENDPOINT_URL`), s5cmd never
  reached, and exit 126.
- **fail** checks each of these returns non-zero, and the run exits 1 with each in
  `helper-errors.tsv`:
  - a wrong ETag, a bad sha256 and a failed lane upload;
  - bad modes and a bad client;
  - a drain that cannot write END, which kills the lane at once;
  - a tampered s5cmd tarball and a tampered rapidgzip wheel, both refused by their pins.

The driver also checks that `lever.sh` passes `errexit_check.py` (run.sh does not check
sourced files) and that `lever {json}` lines streamed. `CASES="refuse"` runs one case, for
debugging; `KEEP=1` keeps the work dir.

**Not covered locally:**
- `lv_nvme` on real devices (mdadm, mkfs.xfs and mount). The test covers only its rehearsal
  seam.
- The downloads from GitHub and PyPI themselves (the image fetched the same files at build
  time).
- Real S3 request counts.
- The lane's main-shell check (the body's shell is the test itself).

These are first exercised by the ladder rehearsal and the first ladder run (#53).
