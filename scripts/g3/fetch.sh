#!/usr/bin/env bash
# Fetch staged cohort files in parallel, each checked against its sha256 metadata (#25).
#
#   scripts/g3/fetch.sh BUCKET KEYPREFIX DIR LANES FILE...
#
# A child process of the spec body, so its jobs are its own (no harness children to confuse a
# wait), run as LANES background lanes (file i in lane i mod LANES), each lane waited for by PID.
# Prints "<file> <bytes>" per verified file and "ERROR: ..." per failure; exits 1 if any failed.
set +e
set -uo pipefail
B=$1 CK=$2 DIR=$3 K=$4; shift 4
FILES=("$@")
hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
fetch_one() {
  local f=$1 want got
  aws s3 cp --only-show-errors "s3://$B/$CK/$f" "$DIR/$f" 2>&1 || { echo "ERROR: get $f failed"; return 1; }
  want=$(aws s3api head-object --bucket "$B" --key "$CK/$f" --query Metadata.sha256 --output text)
  got=$(sha256sum "$DIR/$f" | cut -d' ' -f1)
  hex64 "$want" && [ "$got" = "$want" ] || { echo "ERROR: $f sha256 $got != metadata $want"; return 1; }
  echo "$f $(stat -c%s "$DIR/$f")"
}
pids=()
for ((l = 0; l < K; l++)); do
  ( r=0; for ((i = l; i < ${#FILES[@]}; i += K)); do fetch_one "${FILES[$i]}" || r=1; done; exit "$r" ) &
  pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
exit "$rc"
