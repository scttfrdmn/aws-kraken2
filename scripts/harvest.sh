#!/usr/bin/env bash
# make harvest CAMPAIGN=<conductor run id> [PARTIAL=1] (docs/conductor.md, "Harvest"), on the laptop:
# fetch the conductor's staging prefix, verify it (scripts/lib/harvest_check.py), install it into the
# repo (new files only; tracked.patch applied after git apply --check), tag the staged objects, and
# print exactly what to commit. It commits nothing. Exit 0: installed; 1: refused (nothing
# installed); 2: usage, fetch or patch failure.
# Test seam: AK2_HARVEST_SRC=<local dir> instead of the S3 prefix (no AWS; make conductor-rehearse).
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
echo "harvest: shell flags $-" >&2
# shellcheck source=/dev/null
. scripts/ak2.env
export AWS_PROFILE
die() { echo "harvest: $*" >&2; exit 2; }
CID=${1:-}; PARTIAL=${2:-}
[[ "$CID" =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{7}$ ]] || die "usage: make harvest CAMPAIGN=<conductor run id, yyyymmdd-hhmmss-sha7> [PARTIAL=1]"
URI="s3://$AK2_RESULTS_BUCKET_us_west_2/$AK2_RESULTS_ROOT/$AK2_STAGING_DIR/$CID"
T=$(mktemp -d "${TMPDIR:-/tmp}/ak2-harvest.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$T"' EXIT
if [ -n "${AK2_HARVEST_SRC:-}" ]; then
  mkdir -p "$T/stage" && cp -R "$AK2_HARVEST_SRC/." "$T/stage/" || die "cannot copy $AK2_HARVEST_SRC"
  echo "harvest: from $AK2_HARVEST_SRC (test seam)" >&2
else
  aws s3 sync --only-show-errors --region us-west-2 --exclude DRAIN "$URI/" "$T/stage/" || die "aws s3 sync $URI/ failed"
  echo "harvest: fetched $URI/" >&2
fi
[ -s "$T/stage/conductor.json" ] || die "nothing staged at $URI/ (no conductor.json)"
python3 scripts/lib/harvest_check.py --stage "$T/stage" --campaign "$CID" --root "$ROOT" ${PARTIAL:+--partial} > "$T/summary.json"
VRC=$?
[ "$VRC" = 0 ] || { echo "harvest: refused; nothing installed (above)" >&2; exit 1; }
if [ -s "$T/stage/tracked.patch" ]; then
  git apply --check "$T/stage/tracked.patch" || die "tracked.patch does not apply to this tree (above); nothing installed"
fi
if [ -d "$T/stage/tree" ]; then
  ( cd "$T/stage/tree" && find . -type f -print ) | while IFS= read -r f; do
    f=${f#./}; mkdir -p "$(dirname "$f")" && cp -p "$T/stage/tree/$f" "$f" || { echo "harvest: copy of $f failed" >&2; exit 1; }
  done || die "installing the staged tree failed part-way; inspect git status"
fi
MOD=""
if [ -s "$T/stage/tracked.patch" ]; then
  git apply "$T/stage/tracked.patch" || die "git apply tracked.patch failed after its check"
  MOD=$(git apply --numstat "$T/stage/tracked.patch" | cut -f3 | tr '\n' ' ')
fi
if [ -z "${AK2_HARVEST_SRC:-}" ]; then
  TL=$(scripts/tag-objects.sh "$URI/" 2>&1) && echo "harvest: $TL" >&2 || echo "harvest: WARNING: tagging the staged objects failed: $TL" >&2
fi
ADD=$(jq -r '.add[]' "$T/summary.json" | tr '\n' ' ')
echo "harvest: installed. To commit (harvest commits nothing):"
echo "  git add ${ADD}${MOD}"
jq -r --arg mod "$MOD" '"  git commit -m \"results/g3: conductor campaign \(.campaign) (\(.conductor.campaign_ts // "no campaign") \(.conductor.state); \(.cohorts|length) cohort(s), $\(.spend_usd*100|round/100)); conductor overhead $\(.conductor_cost_usd // "?") (\(.conductor_run_dir // "conductor run dir not on this laptop"))\""' "$T/summary.json"
jq -r 'if .conductor_run_dir == null then "harvest: note: results/conductor/\(.campaign)/ is not here: its make run (the launch host) wrote it; commit it with this" elif .conductor_finalised then empty else "harvest: note: \(.conductor_run_dir) is not finalised yet (its make run is still polling, or run scripts/refinalise.sh)" end' "$T/summary.json"
exit 0
