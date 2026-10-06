#!/usr/bin/env bash
# Oracle inputs for internal/classify (issues #13, #14): build the classify_trace harness, trace
# the real reads through upstream's own scanner, hash table and taxonomy, and run upstream
# kraken2 --output over the option matrix. Everything lands in $OUT (default .cache/classify),
# which the Go equivalence test (internal/classify, K2_CLASSIFY_ORACLE=$OUT) replays.
# Usage: scripts/classify-oracle.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
MAIN=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
ORACLE=${ORACLE_ROOT:-$MAIN/.oracle}
K2="$ORACLE/$UPSTREAM_PIN"
DB=${DB:-$MAIN/.cache/db/k2_viral_20260626}
READS=${READS:-$MAIN/.cache/reads/SRR062634_200000}
OUT=${1:-.cache/classify}
THREADS=${THREADS:-4}
mkdir -p "$OUT/se" "$OUT/pe"
[ -x "$K2/kraken2" ] || { echo "classify-oracle: no upstream build at $K2 (make oracle)" >&2; exit 1; }

H=$(scripts/harness-build.sh classify_trace)
"$H" "$DB" "$OUT/se.trace" "$OUT/taxo.tsv" "${READS}_1.fq"
"$H" "$DB" "$OUT/pe.trace" "$OUT/taxo.tsv" "${READS}_1.fq" "${READS}_2.fq"

# name|kraken2 flags. kraken2's own default --minimum-hit-groups is 2.
CONFIGS=(
  "default|"
  "conf0.1|--confidence 0.1"
  "conf0.5|--confidence 0.5"
  "mhg1|--minimum-hit-groups 1"
  "mhg3|--minimum-hit-groups 3"
  "quick|--quick"
  "quick-mhg1|--quick --minimum-hit-groups 1"
  "quick-conf0.5|--quick --confidence 0.5"
  "names|--use-names"
  "names-conf0.5|--use-names --confidence 0.5"
)
for c in "${CONFIGS[@]}"; do
  name=${c%%|*}
  flags=${c#*|}
  # shellcheck disable=SC2086
  "$K2/kraken2" --db "$DB" --threads "$THREADS" $flags --output "$OUT/se/$name.out" \
    "${READS}_1.fq" 2>"$OUT/se/$name.log"
  # shellcheck disable=SC2086
  "$K2/kraken2" --db "$DB" --threads "$THREADS" $flags --paired --output "$OUT/pe/$name.out" \
    "${READS}_1.fq" "${READS}_2.fq" 2>"$OUT/pe/$name.log"
done
# Reports for the per-taxon call counts (default options).
"$K2/kraken2" --db "$DB" --threads "$THREADS" --output - --report "$OUT/se/default.report" \
  "${READS}_1.fq" 2>"$OUT/se/default.report.log"
"$K2/kraken2" --db "$DB" --threads "$THREADS" --paired --output - --report "$OUT/pe/default.report" \
  "${READS}_1.fq" "${READS}_2.fq" 2>"$OUT/pe/default.report.log"
# -F (flag unique minimizers) is a classify option the kraken2 wrapper does not expose.
for mode in se pe; do
  pflag=(); files=("${READS}_1.fq")
  if [ "$mode" = pe ]; then pflag=(-P); files+=("${READS}_2.fq"); fi
  "$K2/classify" -H "$DB/hash.k2d" -t "$DB/taxo.k2d" -o "$DB/opts.k2d" -p "$THREADS" \
    -T 0 -Q 0 -g 2 -F "${pflag[@]}" -O "$OUT/$mode/flagunique.out" "${files[@]}" \
    2>"$OUT/$mode/flagunique.log"
done
{
  echo "pin $UPSTREAM_PIN"
  cat "$K2/BUILD"
  echo "db $DB"
  cat "$DB/SOURCE" 2>/dev/null || true
  echo "reads $READS"
  cat "${READS}.SOURCE" 2>/dev/null || true
  echo "harness $H"
  cat "$(dirname "$H")/BUILD"
  echo "configs"
  printf '  %s\n' "${CONFIGS[@]}" "flagunique|classify -F -g 2"
} > "$OUT/MANIFEST"
echo "$OUT"
