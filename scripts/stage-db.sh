#!/usr/bin/env bash
# make stage-db DB=viral|standard8 (docs/oracle.md, "Canonical run"): copy a pinned database's
# hash.k2d, opts.k2d, taxo.k2d and SOURCE from the shared .cache/db/ to the in-region results
# bucket, s3://<AK2_RESULTS_BUCKET_us_west_2>/<AK2_RESULTS_ROOT>/data/<name>/, so a run in
# us-west-2 can stage it without cross-region I/O (the public genome-idx bucket is in us-east-1).
# The local SOURCE (genome-idx URI, ETag, fetch time) travels with it; each file's sha256 is
# stored as object metadata and checked against a head-object after upload. Writes nothing
# locally; prints the prefix. Idempotent: a file whose object already has the same sha256 is
# skipped.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/pin.env
. scripts/paths.sh
. scripts/ak2.env
export AWS_PROFILE
echo "stage-db: shell flags $-"
case "${1:-}" in
  viral) NAME=k2_viral_20260626 ;;
  standard8) NAME=k2_standard_08_GB_20260626 ;;
  *) echo "usage: $0 viral|standard8" >&2; exit 2 ;;
esac
SRC="$K2_DB_ROOT/$NAME"
[ -s "$SRC/SOURCE" ] || { echo "stage-db: $SRC incomplete (scripts/fetch-db.sh)" >&2; exit 1; }
BUCKET=$AK2_RESULTS_BUCKET_us_west_2
KEY="$AK2_RESULTS_ROOT/data/$NAME"
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
FAILED=0
for f in hash.k2d opts.k2d taxo.k2d SOURCE; do
  h=$(sha "$SRC/$f")
  have=$(aws s3api head-object --region us-west-2 --bucket "$BUCKET" --key "$KEY/$f" \
           --query 'Metadata.sha256' --output text 2>/dev/null)
  if [ "$have" = "$h" ]; then echo "stage-db: $f present (sha256 $h)"; continue; fi
  aws s3 cp --only-show-errors --region us-west-2 --metadata "sha256=$h" "$SRC/$f" "s3://$BUCKET/$KEY/$f" \
    || { echo "stage-db: upload of $f failed" >&2; FAILED=1; continue; }
  got=$(aws s3api head-object --region us-west-2 --bucket "$BUCKET" --key "$KEY/$f" \
          --query '[Metadata.sha256, ContentLength]' --output text)
  [ "$got" = "$h	$(wc -c < "$SRC/$f" | tr -d ' ')" ] \
    || { echo "stage-db: $f: head-object says '$got'" >&2; FAILED=1; continue; }
  echo "stage-db: $f uploaded (sha256 $h)"
done
[ "$FAILED" = 0 ] || exit 1
echo "s3://$BUCKET/$KEY/"
