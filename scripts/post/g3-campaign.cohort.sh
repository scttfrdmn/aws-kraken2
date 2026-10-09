#!/usr/bin/env bash
# Cohort post script for every G3 campaign spec (runs/g3-<exp>-<type>-n<N>.json; each spec's
# scripts/post/<spec>.cohort.sh is a symlink to this file, made by scripts/g3/mkspec.sh). From the
# record only, on the launch host:
#   - tables/tidy.tsv and tables/rates.tsv (scripts/lib/tidy.py), from the pushed engine stderr;
#   - tables/{batches,samples,consistency,point}.tsv (scripts/lib/g3_tables.py); consistency from
#     outputs.tsv (run-multi's listing of out/: list-object-versions, Versions[?IsLatest]);
#   - tables/placement-check.txt (scripts/lib/lpt_check.py): every home rank as the manifest's
#     placement says, from the pushed stderr;
#   - tables/provenance.tsv: the commit and time these were computed, and outputs.tsv's sha256.
# Exits non-zero if any step fails.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
D=$1
python3 scripts/lib/tidy.py cohort "$D"; t=$?
python3 scripts/lib/g3_tables.py "$D"; g=$?
R0=$(jq -r '.members[] | select(.rank == 0 or .rank == "0") | .run_id' "$D/cohort.json")
N=$(jq -r .nodes "$D/cohort.json")
MAN=$(ls "results/$(basename "$(dirname "$D")")/$R0/out/rank0/"c*.tsv 2>/dev/null | head -1)
python3 scripts/lib/lpt_check.py "$N" "$MAN" results/"$(basename "$(dirname "$D")")"/"$(basename "$D")"-r*/out/rank*/eng-c*.stderr > "$D/tables/placement-check.txt"
l=$?
cat "$D/tables/placement-check.txt"
P="$D/tables/provenance.tsv"
dirty=
git diff --quiet HEAD -- scripts || dirty=-dirty
{
  printf 'key\tvalue\n'
  printf 'commit\t%s%s\n' "$(git rev-parse HEAD)" "$dirty"
  printf 'generated_utc\t%s\n' "$(date -u +%FT%TZ)"
  printf 'consistency_source\t%s\n' "outputs.tsv (launch host, scripts/run-multi.sh: list-object-versions, Versions[?IsLatest])"
  printf 'outputs_tsv_sha256\t%s\n' "$(shasum -a 256 "$D/outputs.tsv" | cut -d' ' -f1)"
  printf 'tables\t%s\n' "tidy.tsv rates.tsv batches.tsv samples.tsv consistency.tsv point.tsv placement-check.txt"
} > "$P"
p=$?
[ "$t" = 0 ] && [ "$g" = 0 ] && [ "$l" = 0 ] && [ "$p" = 0 ]
