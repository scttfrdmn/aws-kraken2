#!/usr/bin/env bash
# make tag-objects [PREFIX=s3://bucket/key/] -- idempotently tag every object under the project's
# S3 prefix (default s3://<AK2_RESULTS_BUCKET_us_west_2>/<AK2_RESULTS_ROOT>/) with
# project=aws-kraken2 and kind=data|payload|results (scripts/lib/tags.sh). Prints one summary
# line; exits non-zero if any object could not be tagged. See docs/tag-objects.md.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=/dev/null
. scripts/ak2.env
# shellcheck source=/dev/null
. scripts/lib/tags.sh
export AWS_PROFILE
PREFIX=${1:-s3://$AK2_RESULTS_BUCKET_us_west_2/$AK2_RESULTS_ROOT/}
U=${PREFIX#s3://}; BUCKET=${U%%/*}; KP=${U#*/}; [ "$KP" = "$U" ] && KP=""
case "$KP" in "$AK2_RESULTS_ROOT"/*) ;; *) echo "tag-objects: refusing a prefix outside $AK2_RESULTS_ROOT/: $PREFIX" >&2; exit 2 ;; esac
KEYS=$(aws s3api list-objects-v2 --region us-west-2 --bucket "$BUCKET" --prefix "$KP" \
         --query 'Contents[].Key' --output json) || { echo "tag-objects: listing $PREFIX failed" >&2; exit 2; }
n=0 tagged=0 ok=0 failed=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  n=$((n + 1))
  case "$(ak2_tag_object "$BUCKET" "$k")" in
    tagged) tagged=$((tagged + 1)) ;;
    ok) ok=$((ok + 1)) ;;
    *) failed=$((failed + 1)); echo "tag-objects: FAILED $k" >&2 ;;
  esac
done < <(echo "$KEYS" | jq -r '.[]? // empty')
echo "tag-objects: $PREFIX: $n objects, $tagged tagged now, $ok already tagged, $failed failed"
[ "$failed" = 0 ]
