#!/usr/bin/env bash
# Local post-processing for runs/g0c-probes.json (G0c-b, #8), run by scripts/run.sh as
# scripts/post/g0c-probes.sh <run-dir>; re-runnable by hand. Reads only <run-dir>; writes
# decoded/ and tables/. Object identities come from manifest.json.
set -uo pipefail
D=${1:?run dir}
O="$D/out"
M="$D/manifest.json"
fail() { echo "g0c-probes.post: $*" >&2; exit 1; }
for f in head-hash.k2d.json opts.k2d probes/summary.json probes/probe-summary.tsv probes/probe-hist.tsv; do
  [ -s "$O/$f" ] || fail "missing $O/$f"
done
[ -s "$M" ] || fail "missing $M"
S="$O/probes/summary.json"
ds() { jq -r --arg f "$1" "[.datasets[] | select(.uri|endswith(\"/\" + \$f))][0].$2 // empty" "$M"; }
L_ETAG=$(ds hash.k2d etag); [ -n "$L_ETAG" ] || fail "manifest declares no hash.k2d dataset"
make -s build || fail "make build failed"
mkdir -p "$D/decoded" "$D/tables"
jq -n --arg c "$(git rev-parse HEAD)" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{decoded_at_commit:$c, decoded_at:$t, decoder:"scripts/post/g0c-probes.sh (k2probe probes output)"}' > "$D/decoded/provenance.json"
bin/k2probe opts "$O/opts.k2d" > "$D/decoded/opts.json" || fail "opts decode failed"

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$([ "$2" = "$3" ] && echo yes || echo NO)"; }
{
  printf 'check\tobserved\texpected\tok\n'
  row "ETag: instance head-object" "$(jq -r '.ETag | gsub("\"";"")' "$O/head-hash.k2d.json")" "$L_ETAG"
  row "ETag: k2probe -etag, enforced in internal/rangeread as If-Match on every GET plus a check of each response's ETag and Content-Range" "$(jq -r .etag "$S")" "$L_ETAG"
  row "miss_probes_from_runs taken from a G0c-a pass (same ETag, checked by k2probe)" "$(jq -r 'has("miss_probes_from_runs")' "$S")" true
  row "get_requests == 1 header GET + the per-sample GETs + retries" "$(jq -r .get_requests "$S")" "$(jq -r '1 + ([to_entries[] | select(.key|endswith("_gets")) | .value] | add) + .get_retries' "$S")"
  row "opts.k2d bytes == launch size" "$(jq -r .file_size "$D/decoded/opts.json")" "$(ds opts.k2d size)"
  row "k, l from opts.k2d == used" "$(jq -r '"\(.k),\(.l)"' "$D/decoded/opts.json")" "$(jq -r '"\(.k),\(.l)"' "$S")"
  row "minimum_acceptable_hash_value" "$(jq -r .minimum_acceptable_hash_value "$S")" 0
  for a in $(jq -r '.sample_accessions[]' "$M"); do
    row "$a lookups sampled" "$(jq -r --arg a "$a" '.[$a + "_sampled"]' "$S")" "$(jq -r .n_per_sample "$S")"
    row "$a lookup rows" "$(($(wc -l < "$O/probes/lookups-$a.tsv") - 1))" "$(jq -r .n_per_sample "$S")"
  done
} > "$D/tables/checks.tsv"
if grep -q 'NO$' "$D/tables/checks.tsv"; then cat "$D/tables/checks.tsv" >&2; fail "a check failed"; fi

jq 'del(.knuth_formulas)' "$S" > "$D/decoded/probes.json"
jq '{knuth_formulas, miss_probes_from_runs_source, hit:"value != 0: chash.Probe found a cell whose compacted key matches (with key_bits bits, some are false positives)", probes:"cells chash.Probe examined, the empty cell that ends a miss included"}' "$S" > "$D/decoded/rules.json"
cp "$O/probes/probe-summary.tsv" "$D/tables/probe-summary.tsv"
# Probe-count distribution in bands (the exact counts are out/probes/probe-hist.tsv).
awk -F'\t' 'BEGIN{n=split("1 2 3 4 5 6-10 11-20 21-50 51-100 101+",B," ")}
  NR==1{next}
  {p=$3; b=(p<=5)?p:(p<=10?6:(p<=20?7:(p<=50?8:(p<=100?9:10)))); k=$1"\t"$2; c[k,b]+=$4; if(!(k in seen)){seen[k]=1; o[++m]=k}}
  END{printf "sample\tclass"; for(i=1;i<=n;i++) printf "\t%s", B[i]; printf "\n";
      for(j=1;j<=m;j++){printf "%s", o[j]; for(i=1;i<=n;i++) printf "\t%d", c[o[j],i]; printf "\n"}}' \
  "$O/probes/probe-hist.tsv" > "$D/tables/probe-bands.tsv"
echo "g0c-probes.post: $(awk -F'\t' 'NR>1 && $2!="all"{printf "%s/%s n=%s mean=%s max=%s; ", $1,$2,$3,$5,$11}' "$D/tables/probe-summary.tsv")"
