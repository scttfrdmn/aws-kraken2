# make tag-objects [PREFIX=s3://…/]

**What:** tags every object under the project's S3 prefix so its storage and requests can be
accounted to the project. The default prefix is
`s3://cookbook-942542972736-us-west-2/aws-kraken2/`; that bucket is shared with the cookbook.
Each object gets:

| tag | value |
|---|---|
| `project` | `aws-kraken2` (`AK2_TAG_PROJECT`) |
| `kind` | `data` under `aws-kraken2/data/` (staged DBs and reads), `payload` for any `…/payload.sh`, `results` for everything else |

Other tags on an object are preserved. It is idempotent: an object already tagged correctly is
left alone. Backed by `scripts/tag-objects.sh` and `scripts/lib/tags.sh`.

**Tags at write time:** `aws s3 cp` cannot set tags, and multipart uploads cannot use
`put-object --tagging`, so each writer calls `put-object-tagging` right after the write.
- `stage-db.sh` and `stage-reads.sh` tag each object they upload, or find already present, as
  `data`.
- `run.sh` tags the payload as `payload` right after uploading it.
- The instance role has `PutObject` but not `PutObjectTagging`. So what the preamble and spawn
  write under a run prefix is tagged by `run.sh` after the run, using
  `scripts/tag-objects.sh <run prefix>/`. It prints one line and records it in the manifest as
  `.object_tags = {ok, line}`; `make report` shows it.

**Inputs:**
- `PREFIX` (optional). Its bucket must be one of the configured `AK2_RESULTS_BUCKET_<region>`,
  and its key must lie under `aws-kraken2/`.
- The region of every call is the `<region>` of that configured bucket, never hard-coded.
- `AWS_PROFILE` and `scripts/ak2.env`.

**Outputs:** one line, `tag-objects: <prefix>: N objects, T tagged now, A already tagged, F failed`.
The first run over the whole prefix (2026-10-06) tagged 134 of 134 objects, and a second run
tagged 0. It takes about 3 minutes for 134 objects (two API calls each, sequential).

**Failure looks like:** exit 2 if the bucket is not a configured results bucket, if the prefix is
outside `aws-kraken2/`, or if it cannot be listed. Exit 1
with `FAILED <key>` lines if an object could not be read or tagged (permissions, or the object
was deleted mid-run). Re-run; it only touches what is still missing.
