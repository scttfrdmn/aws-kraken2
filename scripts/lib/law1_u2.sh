#!/usr/bin/env bash
# make g3-law1-u2 (docs/cohort.md, "The G3 campaign"): two checks against real S3, from the
# launch host, on the cohort's sample 1 (SRR5935740):
#   1. scripts/lib/ak2etag.py on a downloaded engine output (multipart) and report (one PutObject)
#      must equal the S3 ETags outputs.tsv records for them (the U1 cross-check rests on this);
#   2. their sha256 must equal U2's (upstream at the pin, run on NVMe: out/g2-u2/runs.jsonl's
#      output_sha256 and report_sha256 for every SRR5935740 rung): Law 1 on a full-size real sample.
#
#   scripts/lib/law1_u2.sh [ENGINE_COHORT_DIR] [U2_RUN_DIR]
#
# Defaults: the E2 x8g.4xlarge N=8 cohort and the U2 run. Writes results/g3/campaign/law1-u2.tsv;
# exits 1 if any comparison differs or nothing was compared. Downloads about 1 GB to a temp dir.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. scripts/ak2.env
export AWS_PROFILE
E=${1:-results/g3/20261008-062751-c217150-8332-n8}
U=${2:-results/g3/20261008-050900-9c4a5c7}
B=$AK2_RESULTS_BUCKET_us_west_2
S=SRR5935740
T=$(mktemp -d "${TMPDIR:-/tmp}/ak2-law1u2.XXXXXX"); trap 'rm -rf "$T"' EXIT
OUT=results/g3/campaign/law1-u2.tsv; mkdir -p "$(dirname "$OUT")"
printf 'check\tfile\tengine_object\twant\tgot\tidentical\n' > "$OUT"
RC=0; n=0
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
for f in output report; do
  row=$(awk -F'\t' -v k="/0-$S/$f" 'substr($1, length($1) - length(k) + 1) == k' "$E/outputs.tsv" | head -1)
  [ -n "$row" ] || { echo "law1_u2: no 0-$S/$f in $E/outputs.tsv" >&2; RC=1; continue; }
  key=$(echo "$row" | cut -f1); etag=$(echo "$row" | cut -f4)
  aws s3 cp --only-show-errors "s3://$B/$key" "$T/$f" || { echo "law1_u2: download of $key failed" >&2; RC=1; continue; }
  got=$(python3 scripts/lib/ak2etag.py "$f" "$T/$f" | cut -f1)
  ok=no; [ "$got" = "$etag" ] && ok=yes; [ "$ok" = yes ] || RC=1; n=$((n + 1))
  printf 'ak2etag (%s)\t%s\t%s\t%s\t%s\t%s\n' "$([ "$f" = output ] && echo multipart || echo single-part)" "$f" "$key" "$etag" "$got" "$ok" >> "$OUT"
  h=$(sha "$T/$f")
  while read -r rung want; do
    ok=no; [ "$h" = "$want" ] && ok=yes; [ "$ok" = yes ] || RC=1; n=$((n + 1))
    printf 'sha256 vs U2 %s\t%s\t%s\t%s\t%s\t%s\n' "$rung" "$f" "$key" "$want" "$h" "$ok" >> "$OUT"
  done < <(jq -r --arg f "${f}_sha256" 'select((.input // "") | tostring | test("SRR5935740")) | "\(.tag) \(.[$f])"' "$U/out/g2-u2/runs.jsonl")
done
[ "$n" -gt 0 ] || { echo "law1_u2: nothing compared" >&2; RC=1; }
column -t -s$'\t' "$OUT"
echo "law1_u2: $n comparisons, $(awk -F'\t' 'NR>1 && $6=="yes"' "$OUT" | wc -l | tr -d ' ') identical -> $OUT"
exit "$RC"
