#!/usr/bin/env bash
# make stage-reads (docs/oracle.md, "Canonical run"): copy the real-read subsets the oracles use
# (.cache/reads/<run>_200000_{1,2}.fq[.gz] and <run>_200000.SOURCE, for SRR062634, ERR478965,
# SRR28305653, SRR5935746 and ERR598966) to the in-region results bucket,
# s3://<AK2_RESULTS_BUCKET_us_west_2>/<AK2_RESULTS_ROOT>/data/reads/, so a run in us-west-2 does
# not depend on ENA (CI keeps fetching from ENA with scripts/fetch-reads.sh). Each object carries
# its sha256 as metadata, checked with head-object after upload; the SOURCE files (ENA URLs and
# the sha256 of each plain FASTQ) travel with them. Idempotent: an object whose metadata already
# matches is skipped. Writes nothing locally; prints the prefix.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/pin.env
. scripts/paths.sh
. scripts/ak2.env
# shellcheck source=/dev/null
. scripts/lib/tags.sh
export AWS_PROFILE
echo "stage-reads: shell flags $-"
N=200000
RUNS=(SRR062634 ERR478965 SRR28305653 SRR5935746 ERR598966)
BUCKET=$AK2_RESULTS_BUCKET_us_west_2
KEY="$AK2_RESULTS_ROOT/data/reads"
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
FAILED=0
for r in "${RUNS[@]}"; do
  [ -s "$K2_READS/${r}_$N.SOURCE" ] || { echo "stage-reads: no $K2_READS/${r}_$N.SOURCE (scripts/fetch-reads.sh $r $N)" >&2; FAILED=1; continue; }
  for f in "${r}_${N}_1.fq" "${r}_${N}_2.fq" "${r}_${N}_1.fq.gz" "${r}_${N}_2.fq.gz" "${r}_$N.SOURCE"; do
    p="$K2_READS/$f"
    [ -s "$p" ] || { echo "stage-reads: missing $p" >&2; FAILED=1; continue; }
    h=$(sha "$p")
    [[ $h =~ ^[0-9a-f]{64}$ ]] || { echo "stage-reads: no sha256 for $p" >&2; FAILED=1; continue; }
    # A plain FASTQ must still match the sha256 its SOURCE recorded at fetch time.
    # A gzip copy must decompress to exactly that plain FASTQ.
    case "$f" in
      *.fq)
        grep -qx "sha256 $h $f" "$K2_READS/${r}_$N.SOURCE" \
          || { echo "stage-reads: $f does not match its SOURCE" >&2; FAILED=1; continue; } ;;
      *.fq.gz)
        dh=$(gzip -dc "$p" | { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi; } | cut -d' ' -f1)
        grep -qx "sha256 $dh ${f%.gz}" "$K2_READS/${r}_$N.SOURCE" \
          || { echo "stage-reads: $f does not decompress to the ${f%.gz} its SOURCE names" >&2; FAILED=1; continue; } ;;
    esac
    have=$(aws s3api head-object --region us-west-2 --bucket "$BUCKET" --key "$KEY/$f" \
             --query 'Metadata.sha256' --output text 2>/dev/null)
    if [ "$have" = "$h" ]; then
      t=$(ak2_tag_object "$BUCKET" "$KEY/$f" data) || { echo "stage-reads: tagging $f failed" >&2; FAILED=1; continue; }
      echo "stage-reads: $f present (sha256 $h; tags $t)"; continue
    fi
    aws s3 cp --only-show-errors --region us-west-2 --metadata "sha256=$h" "$p" "s3://$BUCKET/$KEY/$f" \
      || { echo "stage-reads: upload of $f failed" >&2; FAILED=1; continue; }
    got=$(aws s3api head-object --region us-west-2 --bucket "$BUCKET" --key "$KEY/$f" \
            --query '[Metadata.sha256, ContentLength]' --output text)
    [ "$got" = "$h	$(wc -c < "$p" | tr -d ' ')" ] \
      || { echo "stage-reads: $f: head-object says '$got'" >&2; FAILED=1; continue; }
    t=$(ak2_tag_object "$BUCKET" "$KEY/$f" data) || { echo "stage-reads: tagging $f failed" >&2; FAILED=1; continue; }
    echo "stage-reads: $f uploaded (sha256 $h; tags $t)"
  done
done
[ "$FAILED" = 0 ] || { echo "stage-reads: FAILED" >&2; exit 1; }
echo "s3://$BUCKET/$KEY/"
