#!/usr/bin/env bash
# make ladder-respec [COHORT=<n>] (docs/ladder.md, "The body and its specs"): regenerate every
# committed runs/g3-l-*-c<n>.json (every cohort when COHORT is empty) with scripts/g3/mkspec-ladder.sh,
# from the ARM, RUNG and COHORT its own PARAMS header names (and, where the cohort is not 1, its TTL
# unless that TTL was estimated: an estimate is made again).
# Run it after any change to scripts/g3/ladder.body.sh: every spec embeds the body. It then prints
# what changed in each spec other than the body, which must be nothing for
# scripts/g3/ladder.body-compat.tsv to keep a finished run counted (scripts/lib/ladder_body_compat.py
# diff).
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
echo "ladder-respec: shell flags $-"
COHORT=${1:-}
[ -z "$COHORT" ] || [[ "$COHORT" =~ ^[1-9][0-9]*$ ]] || { echo "ladder-respec: COHORT=$COHORT" >&2; exit 2; }
pat="runs/g3-l-*-c${COHORT:-*}.json"
n=0; bad=0
for f in $(git ls-files "$pat"); do
  hdr=$(jq -r '.command[2]' "$f" | grep -m1 '^# Parameters (scripts/g3/mkspec-ladder.sh ')
  read -r arm rung coh <<< "$(printf '%s\n' "$hdr" | sed 's/^# Parameters (scripts\/g3\/mkspec-ladder.sh \([^;]*\);.*/\1/')"
  [ -n "$arm" ] && [ -n "$rung" ] && [ -n "$coh" ] || { echo "ladder-respec: $f: no PARAMS header" >&2; bad=1; continue; }
  # Above c1 a given TTL is kept; an estimated one (its comment cites scripts/lib/ladder_ttl.py) is
  # estimated again from the same record, so it comes out the same unless the c1 record changed.
  ttl=()
  if [ "$coh" != 1 ] && ! jq -r '.command[2]' "$f" | grep '^# TTL .*(scripts/lib/ladder_ttl.py)' > /dev/null; then
    ttl=("TTL=$(jq -r '.lifecycle.ttl' "$f" | sed 's/m$//')")
  fi
  old=$(mktemp); git show "HEAD:$f" > "$old" 2> /dev/null || cp "$f" "$old"
  scripts/g3/mkspec-ladder.sh "$arm" "$rung" "$coh" "${ttl[@]}"; rc=$?
  if [ "$rc" != 0 ]; then echo "ladder-respec: $f: mkspec-ladder.sh exit $rc" >&2; bad=1; rm -f "$old"; continue; fi
  python3 scripts/lib/ladder_body_compat.py diff "$old" "$f"; drc=$?
  [ "$drc" = 0 ] || [ "$drc" = 1 ] || bad=1
  rm -f "$old"; n=$((n + 1))
done
echo "ladder-respec: $n spec(s) regenerated; exit $bad"
exit $bad
