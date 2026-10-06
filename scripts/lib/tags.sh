# Object tags that account S3 objects to this project (sourced by scripts/tag-objects.sh,
# scripts/stage-db.sh, scripts/stage-reads.sh and scripts/run.sh). See docs/tag-objects.md.
#
#   project=aws-kraken2 (AK2_TAG_PROJECT)
#   kind=data     under <AK2_RESULTS_ROOT>/data/  (staged databases and reads)
#   kind=payload  any .../payload.sh               (run.sh's stub payload)
#   kind=results  everything else                 (run outputs, logs, spawn records)
#
# `aws s3 cp` cannot set tags, and multipart uploads (hash.k2d) cannot use put-object, so tags are
# set with put-object-tagging immediately after each write. Other tags on an object are kept.

# ak2_bucket_region BUCKET -> the region whose AK2_RESULTS_BUCKET_<region> names BUCKET
# (scripts/ak2.env); fails if the bucket is not a configured results bucket.
ak2_bucket_region() {
  local v r
  for v in ${!AK2_RESULTS_BUCKET_*}; do
    if [ "${!v}" = "$1" ]; then r=${v#AK2_RESULTS_BUCKET_}; echo "${r//_/-}"; return 0; fi
  done
  return 1
}

# ak2_tag_kind KEY -> data|payload|results
ak2_tag_kind() {
  case "$1" in
    "$AK2_RESULTS_ROOT"/data/*) echo data ;;
    */payload.sh) echo payload ;;
    *) echo results ;;
  esac
}

# ak2_tag_object BUCKET KEY [KIND]: idempotent. Prints "tagged" or "ok"; returns non-zero on error.
ak2_tag_object() {
  local b=$1 k=$2 kind=${3:-} cur want region
  region=$(ak2_bucket_region "$b") || { echo "ak2_tag_object: $b is not a configured AK2_RESULTS_BUCKET_*" >&2; return 1; }
  [ -n "$kind" ] || kind=$(ak2_tag_kind "$k")
  cur=$(aws s3api get-object-tagging --region "$region" --bucket "$b" --key "$k" --output json 2>/dev/null) || return 1
  if [ "$(echo "$cur" | jq -r --arg p "$AK2_TAG_PROJECT" --arg kd "$kind" \
          '[.TagSet[] | select((.Key=="project" and .Value==$p) or (.Key=="kind" and .Value==$kd))] | length')" = 2 ]; then
    echo ok; return 0
  fi
  want=$(echo "$cur" | jq -c --arg p "$AK2_TAG_PROJECT" --arg kd "$kind" \
    '{TagSet: ([.TagSet[] | select(.Key != "project" and .Key != "kind")] + [{Key:"project",Value:$p},{Key:"kind",Value:$kd}])}')
  aws s3api put-object-tagging --region "$region" --bucket "$b" --key "$k" --tagging "$want" >/dev/null || return 1
  echo tagged
}
