#!/usr/bin/env bash
# Record and abort open multipart uploads under a results prefix, from the launch host (the
# instance role cannot abort; make run's finish trap aborts its own cohort's, but not those an
# interrupted member started on its own log).
#
#   scripts/lib/abort_uploads.sh KEYPREFIX RECORD.json
#
# Writes the listing (with each upload's part count) to RECORD.json, aborts every upload in it,
# and checks none remain. Refuses a prefix outside aws-kraken2/.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. scripts/ak2.env
export AWS_PROFILE
P=${1:?KEYPREFIX}; R=${2:?RECORD}
case "$P" in aws-kraken2/*) ;; *) echo "abort_uploads: refusing $P" >&2; exit 2 ;; esac
B=$AK2_RESULTS_BUCKET_us_west_2
aws s3api list-multipart-uploads --bucket "$B" --prefix "$P" --output json > "$R.tmp" || exit 1
jq -c '.Uploads // [] | .[] | {Key, UploadId, Initiated, Initiator: .Initiator.DisplayName}' "$R.tmp" > "$R.list"
: > "$R.lines"
RC=0
while read -r u; do
  k=$(echo "$u" | jq -r .Key); id=$(echo "$u" | jq -r .UploadId)
  parts=$(aws s3api list-parts --bucket "$B" --key "$k" --upload-id "$id" --query 'length(Parts || `[]`)' --output text)
  aws s3api abort-multipart-upload --bucket "$B" --key "$k" --upload-id "$id"; a=$?
  [ "$a" = 0 ] || RC=1
  echo "$u" | jq -c --arg p "$parts" --argjson a "$a" '. + {parts: ($p|tonumber? // $p), abort_rc: $a, aborted_at: (now | todate)}' >> "$R.lines"
done < "$R.list"
left=$(aws s3api list-multipart-uploads --bucket "$B" --prefix "$P" --query 'length(Uploads || `[]`)' --output text)
jq -s --arg p "$P" --arg left "$left" '{prefix: $p, uploads: ., remaining_after: ($left|tonumber? // $left)}' "$R.lines" > "$R"
rm -f "$R.tmp" "$R.list" "$R.lines"
cat "$R"
[ "$left" = 0 ] || RC=1
exit "$RC"
