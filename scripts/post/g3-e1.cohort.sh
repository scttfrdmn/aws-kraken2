#!/usr/bin/env bash
# Cohort post script for runs/g3-e1.json (scripts/run-multi.sh runs scripts/post/<spec>.cohort.sh
# with the cohort dir). Every table is computed on the launch host from files in the record:
#   - tables/tidy.tsv and tables/rates.tsv (scripts/lib/tidy.py): the members' pushed engine stderr,
#     the measured rates against the sweep estimate's basis;
#   - tables/consistency.tsv (scripts/lib/e1_consistency.py): from outputs.tsv, run-multi's listing
#     of <prefix>/out/ (list-object-versions, Versions[?IsLatest]); one ETag per output across every
#     variant of a sample, and E1's variant counts (8 and 5);
#   - tables/{batches,samples,invocations}.tsv (scripts/lib/e1_batches.py), from tidy.tsv;
#   - tables/provenance.tsv: the commit and time these were computed, and outputs.tsv's sha256;
#   - tables/summary.md (scripts/lib/e1_summary.py), generated from the above.
# Exits non-zero if any step fails or any sample's variants differ.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
D=$1
python3 scripts/lib/tidy.py cohort "$D"; t=$?
python3 scripts/lib/e1_consistency.py "$D"; c=$?
python3 scripts/lib/e1_batches.py "$D"; b=$?
P="$D/tables/provenance.tsv"
dirty=
git diff --quiet HEAD -- scripts || dirty=-dirty
{
  printf 'key\tvalue\n'
  printf 'commit\t%s%s\n' "$(git rev-parse HEAD)" "$dirty"
  printf 'generated_utc\t%s\n' "$(date -u +%FT%TZ)"
  printf 'consistency_source\t%s\n' "outputs.tsv (launch host, scripts/run-multi.sh: list-object-versions, Versions[?IsLatest])"
  printf 'outputs_tsv_sha256\t%s\n' "$(shasum -a 256 "$D/outputs.tsv" | cut -d' ' -f1)"
  printf 'tables\t%s\n' "tidy.tsv rates.tsv consistency.tsv batches.tsv samples.tsv invocations.tsv summary.md"
} > "$P"
p=$?
python3 scripts/lib/e1_summary.py "$D"; s=$?
[ "$t" = 0 ] && [ "$c" = 0 ] && [ "$b" = 0 ] && [ "$p" = 0 ] && [ "$s" = 0 ]
