#!/usr/bin/env bash
# scripts/lib/cohort_dir.sh RUN_DIR: print the cohort dir of a cohort member's run dir, or nothing
# (exit 1) if RUN_DIR is not a member. refinalise.sh uses it to re-derive the cohort's
# tables/util.tsv after repairing a member's manifest (#58). It finds the cohort dir from, in order:
#   the manifest's .cohort.dir (run.sh records it: results/<gate>/<cohort id>);
#   the manifest's .cohort.id, as a sibling of RUN_DIR;
#   the run id's form <cohort id>-r<rank>, as a sibling of RUN_DIR.
# The cohort dir must have a cohort.json that lists RUN_DIR's run id among its members. A member
# whose cohort has no cohort.json (run-multi.sh never finished) prints the dir and exits 2.
set +e
set -uo pipefail
D=${1:?usage: cohort_dir.sh RUN_DIR}
D=${D%/}
M="$D/manifest.json"
RID=$(basename "$D")
C=""
if [ -s "$M" ]; then
  C=$(jq -r '.cohort.dir // empty' "$M" 2>/dev/null)
  if [ -z "$C" ]; then
    CID=$(jq -r '.cohort.id // empty' "$M" 2>/dev/null)
    [ -n "$CID" ] && C="$(dirname "$D")/$CID"
  fi
  # .cohort.dir is relative to the repository root, and RUN_DIR may not be. run.sh puts the cohort
  # dir beside its members (results/<gate>/), so it is resolved as RUN_DIR's sibling.
  [ -n "$C" ] && C="$(dirname "$D")/$(basename "$C")"
fi
if [ -z "$C" ] && [[ "$RID" =~ ^(.+-n[0-9]+)-r[0-9]+$ ]]; then
  C="$(dirname "$D")/${BASH_REMATCH[1]}"
fi
[ -n "$C" ] || exit 1
if [ ! -s "$C/cohort.json" ]; then
  [ -s "$M" ] && [ -n "$(jq -r '.cohort.id // empty' "$M" 2>/dev/null)" ] && { echo "$C"; exit 2; }
  exit 1
fi
jq -e --arg r "$RID" 'any(.members[]?; .run_id == $r)' "$C/cohort.json" > /dev/null 2>&1 || exit 1
echo "$C"
