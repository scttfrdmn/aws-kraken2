#!/usr/bin/env bash
# Local post-processing for runs/g0c-runs.json (G0c-a, #7), run by scripts/run.sh as
# scripts/post/g0c-runs.sh <run-dir>; re-runnable by hand. Reads only <run-dir>; writes decoded/
# and tables/, and records the pass's SHA-256 next to the ETag/VersionId of hash.k2d in
# manifest.json (datasets[].sha256, with sha256_source naming the file it came from and
# sha256_check the checks it passed; docs/run.md allows post scripts only this manifest write).
# Object identities come from manifest.json (the launch-time head-object), never from here.
set -uo pipefail
D=${1:?run dir}
O="$D/out"
M="$D/manifest.json"
fail() { echo "g0c-runs.post: $*" >&2; exit 1; }
for f in head-hash.k2d.json head-hash.k2d.after.json pilot/summary.json pass/summary.json pass/hist.tsv \
         pass/hist-raw.tsv pass/boundaries.tsv pass/tails.tsv; do
  [ -s "$O/$f" ] || fail "missing $O/$f"
done
[ -s "$M" ] || fail "missing $M"
S="$O/pass/summary.json"
HURI=$(jq -r '[.datasets[] | select(.uri|endswith("/hash.k2d"))][0].uri // empty' "$M")
[ -n "$HURI" ] || fail "manifest declares no hash.k2d dataset"
L_ETAG=$(jq -r --arg u "$HURI" '.datasets[] | select(.uri==$u) | .etag' "$M")
L_SIZE=$(jq -r --arg u "$HURI" '.datasets[] | select(.uri==$u) | .size' "$M")
L_VER=$(jq -r --arg u "$HURI" '.datasets[] | select(.uri==$u) | .version_id // "null"' "$M")
etag() { jq -r '.ETag // empty | gsub("\"";"")' "$1"; }
I_ETAG=$(etag "$O/head-hash.k2d.json"); A_ETAG=$(etag "$O/head-hash.k2d.after.json")
P_ETAG=$(jq -r .etag "$S")
mkdir -p "$D/decoded" "$D/tables"
jq -n --arg c "$(git rev-parse HEAD)" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{decoded_at_commit:$c, decoded_at:$t, decoder:"scripts/post/g0c-runs.sh (k2probe runs output)"}' > "$D/decoded/provenance.json"

# ---- checks: same object throughout, whole object covered, counts agree with the header ----
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$([ "$2" = "$3" ] && echo yes || echo NO)"; }
{
  printf 'check\tobserved\texpected\tok\n'
  row "ETag: instance head-object before the pass" "$I_ETAG" "$L_ETAG"
  row "ETag: k2probe -etag, enforced in internal/rangeread as If-Match on every GET plus a check of each response's ETag and Content-Range" "$P_ETAG" "$L_ETAG"
  row "ETag: instance head-object after the pass" "$A_ETAG" "$L_ETAG"
  row "bytes streamed" "$(jq -r .bytes_streamed "$S")" "$L_SIZE"
  row "complete pass" "$(jq -r .complete "$S")" true
  row "cells counted == capacity" "$(jq -r .cells "$S")" "$(jq -r .capacity "$S")"
  row "occupied (value != 0) == header size" "$(jq -r .occupied "$S")" "$(jq -r .header_size "$S")"
  row "SHA-256 scope" "$(jq -r .sha256_scope "$S")" "bytes [0,$L_SIZE)"
} > "$D/tables/checks.tsv"
if grep -q 'NO$' "$D/tables/checks.tsv"; then cat "$D/tables/checks.tsv" >&2; fail "a check failed"; fi

SHA=$(jq -r .sha256 "$S")
[[ $SHA =~ ^[0-9a-f]{64}$ ]] || fail "no sha256 in $S"
jq -n --arg u "$HURI" --arg e "$L_ETAG" --arg v "$L_VER" --argjson s "$L_SIZE" --arg h "$SHA" \
  '{uri:$u, etag:$e, version_id:$v, size:$s, sha256:$h, sha256_source:"out/pass/summary.json", sha256_check:"tables/checks.tsv all yes: ETag equal at launch, before, on every GET (If-Match + response ETag/Content-Range) and after; bytes streamed == object size; complete pass"}' > "$D/decoded/object.json"
# Record the digest in the manifest beside the ETag/VersionId it was computed under.
T=$(mktemp) || fail "mktemp"
jq --arg u "$HURI" --arg h "$SHA" \
  '(.datasets[] | select(.uri==$u)) += {sha256:$h, sha256_source:"out/pass/summary.json (k2probe runs, one streaming pass)", sha256_check:"tables/checks.tsv all yes: ETag equal at launch, before, on every GET (If-Match + response ETag/Content-Range) and after; bytes streamed == object size; complete pass"}' \
  "$M" > "$T" && mv "$T" "$M" || { rm -f "$T"; fail "could not record sha256 in $M"; }

# ---- decoded: the pass summary without the long prose fields; rules separately ----
# The Knuth hit value is the uniform-key null (older summaries called it knuth_hit_probes).
jq 'del(.shard_rule, .tail_rule) | if has("knuth_hit_probes") then .knuth_hit_probes_uniform_key_null = .knuth_hit_probes | del(.knuth_hit_probes) else . end' \
  "$S" > "$D/decoded/pass.json"
# How the Borel model does on the long-run tail, from hist.tsv and the summary only.
H="$O/pass/hist.tsv"
bucket() { awk -F'\t' -v lo="$1" -v hi="$2" -v c="$3" '$1==lo && $2==hi {print $c}' "$H"; }
LONG=$(jq -r .longest_run "$S")
GE_OBS=$(awk -F'\t' -v l="$LONG" 'NR>1 && $1>=l {s+=$2} END{print s+0}' "$O/pass/hist-raw.tsv")
jq -n --arg r65 "$(bucket 65 128 6)" --arg r129 "$(bucket 129 256 6)" \
  --arg o257 "$(bucket 257 512 3)" --arg t257 "$(bucket 257 512 4)" \
  --argjson long "$LONG" --argjson geo "$GE_OBS" --argjson get "$(jq .theory_runs_ge_longest "$S")" \
  '{rel_residual_65_128:($r65|tonumber), rel_residual_129_256:($r129|tonumber),
    observed_257_512:($o257|tonumber), theory_257_512:($t257|tonumber),
    longest_run:$long, observed_runs_ge_longest:$geo, theory_runs_ge_longest:$get,
    borel_over_predicts_long_tail:(($r65|tonumber) < 0 and ($r129|tonumber) < 0 and ($o257|tonumber) < ($t257|tonumber) and $geo < $get),
    source:"out/pass/hist.tsv, out/pass/hist-raw.tsv, out/pass/summary.json"}' > "$D/decoded/theory-tail.json" \
  || fail "theory-tail summary failed"
jq '{shard_rule, tail_rule, theory:"expected runs of length L = (C - occupied) * e^{-a(L+1)} (a(L+1))^L / (L+1)!, a = occupied/C (Borel; Poisson model of linear probing: Flajolet, Poblete & Viola 1998; Knuth TAOCP 3, 6.4)", knuth:"hit 1/2(1+1/(1-a)), miss 1/2(1+1/(1-a)^2)"}' "$S" > "$D/decoded/rules.json"

# ---- tables ----
{
  printf 'rung\tbytes\twall_s\twall_GB_s\tsha_busy_GB_s\tsha_bench_GB_s\tconsumer_stall_s\tfetch_MB_s_per_stream\tscan_GB_s_per_worker\tget_requests\tget_retries\tgomaxprocs\tworkers\tchunk_bytes\n'
  for r in pilot pass; do
    jq -r --arg r "$r" '[$r, .bytes_streamed, (.wall_seconds*10|round/10), (.wall_gb_per_s*1000|round/1000),
      (.sha_gb_per_s_while_busy*1000|round/1000), ((.sha_bench_gb_per_s // 0)*1000|round/1000),
      (.consumer_stall_seconds*10|round/10), (.fetch_mb_per_s_per_stream*10|round/10),
      (.scan_gb_per_s_per_worker*1000|round/1000), .get_requests, .get_retries, .gomaxprocs, .workers, .chunk_bytes] | @tsv' "$O/$r/summary.json"
  done
} > "$D/tables/rates.tsv"
cp "$O/pass/tails.tsv" "$D/tables/tails.tsv"
cp "$O/pass/hist.tsv" "$D/tables/hist.tsv"
cp "$O/pass/boundaries.tsv" "$D/tables/boundaries.tsv"
echo "g0c-runs.post: sha256 $SHA; $(jq -c '{cells,occupied,load_factor,runs,longest_run,longest_run_start_slot}' "$S")"
