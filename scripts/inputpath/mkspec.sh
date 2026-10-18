#!/usr/bin/env bash
# make inputpath FAMILY=<c8g|c9g|c8gn> ENGINE=<upstream|ours> [ARGS="KEY=VALUE ..."] [LAUNCH=1]
# (docs/inputpath.md; #90): writes runs/inputpath-<family>-<engine>.json from
# scripts/inputpath/inputpath.body.sh, prints the time estimate, the cost bound and the make run
# command. It launches nothing unless LAUNCH=1 (then, for a committed and unchanged spec only, it
# runs scripts/run.sh inputpath SPEC, exactly as make run GATE=inputpath does).
#
#   scripts/inputpath/mkspec.sh FAMILY ENGINE [KEY=VALUE ...]
#
# The type is <family>.16xlarge (64 vCPU, 128 GiB, arm64; checked with the pinned truffle). The
# TTL is the longest whole minute, at most 240 (Scott: TTL up to 4 h), whose cost_limit, TTL x the
# truffle on-demand price + $0.005 to the cent (cost_check's rule), is at most COST_MAX (Scott:
# $5 per run). KEY=VALUE: THREADS ("48 32 16"), PS ("16 8 4 2"), CHUNKS ("8192 16384", KiB),
# REPS (2), MAIN_THP (always), THP_CONTRAST (1 for upstream, 0 for ours), PIPE_BYTES (1048576),
# PIPE_CONTRAST (1), POINT_TIMEOUT (900 s), ID_TIMEOUT (360 s), MARGIN_S (600), TTL (minutes, at
# most the cost rule's), COST_MAX (5.00), AZ (us-west-2b), LAUNCH (0), G1_REF (#95's Law 1 reference,
# results/inputpath/preflight-inputs-20261018T224922Z-89e0340/manifest.json), RG2_SCRIPT (empty: a
# second rapidgzip build's script, e.g. scripts/g3/rg-build.sh, adds I2-I4 at the best p with it).
# THREADS defaults to "48 16" on c8gn (its TTL is 79 min).
# Datasets: our Standard-8 copy (make stage-db) and every object of scripts/inputpath/inputs.tsv;
# the accessions are inputs.tsv's. With no valid inputs.tsv the spec is still written (for make
# rehearse), marked NOT READY: its body fails at the input check before any build or stage.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=/dev/null
. scripts/lib/tools_pin.sh
ak2_pin_tools "$PWD" || { echo "inputpath: the pinned spawn/truffle are not in place (make tools)" >&2; exit 2; }
FAMILY=${1:-}; ENGINE=${2:-}; shift 2 2> /dev/null
case "$FAMILY" in c8g | c9g | c8gn) ;; *) echo "inputpath: FAMILY must be c8g, c9g or c8gn (got '$FAMILY')" >&2; exit 2 ;; esac
case "$ENGINE" in upstream | ours) ;; *) echo "inputpath: ENGINE must be upstream or ours (got '$ENGINE')" >&2; exit 2 ;; esac
THREADS="48 32 16"; [ "$FAMILY" = c8gn ] && THREADS="48 16"   # c8gn's 79-min TTL: the cut (#90 review)
PS="16 8 4 2" CHUNKS="8192 16384" REPS=2 MAIN_THP=always PIPE_BYTES=1048576 PIPE_CONTRAST=1
POINT_TIMEOUT=900 ID_TIMEOUT=360 MARGIN_S=600 TTL="" COST_MAX=5.00 AZ=us-west-2b LAUNCH=0 RG2_SCRIPT=""
G1_REF=results/inputpath/preflight-inputs-20261018T224922Z-89e0340/manifest.json   # #95's upstream I0 reference
THP_CONTRAST=0; [ "$ENGINE" = upstream ] && THP_CONTRAST=1
for kv in "$@"; do
  case "${kv%%=*}" in
    THREADS | PS | CHUNKS | REPS | MAIN_THP | THP_CONTRAST | PIPE_BYTES | PIPE_CONTRAST | POINT_TIMEOUT | ID_TIMEOUT | MARGIN_S | TTL | COST_MAX | AZ | LAUNCH | G1_REF | RG2_SCRIPT)
      printf -v "${kv%%=*}" '%s' "${kv#*=}" ;;
    *) echo "inputpath: unknown $kv" >&2; exit 2 ;;
  esac
done
for v in THREADS PS CHUNKS; do [[ "${!v}" =~ ^[0-9]+( [0-9]+)*$ ]] || { echo "inputpath: $v '${!v}' must be numbers" >&2; exit 2; }; done
[ -s "$G1_REF" ] && git ls-files --error-unmatch "$G1_REF" > /dev/null 2>&1 || { echo "inputpath: G1_REF $G1_REF is not a committed file" >&2; exit 2; }
[ -z "$RG2_SCRIPT" ] || [ -f "$RG2_SCRIPT" ] || { echo "inputpath: RG2_SCRIPT $RG2_SCRIPT is not in the tree" >&2; exit 2; }
[[ "$REPS$POINT_TIMEOUT$ID_TIMEOUT$MARGIN_S" =~ ^[0-9]+$ ]] && [[ "$THP_CONTRAST$PIPE_CONTRAST" =~ ^[01][01]$ ]] &&
  [[ "$MAIN_THP" =~ ^(always|never)$ ]] && [[ "$PIPE_BYTES" =~ ^[0-9]+$ ]] && [[ "$COST_MAX" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
  { echo "inputpath: bad REPS/POINT_TIMEOUT/ID_TIMEOUT/MARGIN_S/THP_CONTRAST/PIPE_CONTRAST/MAIN_THP/PIPE_BYTES/COST_MAX" >&2; exit 2; }
TYPE=$FAMILY.16xlarge
INFO=$(truffle find "$TYPE" --regions us-west-2 --show-price -o json 2> /dev/null |
  jq -c --arg t "$TYPE" '[.. | objects | select(has("on_demand_price") and .instance_type == $t)][0]')
[ -n "$INFO" ] && [ "$INFO" != null ] || { echo "inputpath: truffle knows no $TYPE in us-west-2" >&2; exit 1; }
PRICE=$(jq -r .on_demand_price <<< "$INFO"); VCPU=$(jq -r .vcpus <<< "$INFO"); MEM=$(jq -r .memory_mib <<< "$INFO"); ARCH=$(jq -r .architecture <<< "$INFO")
[ "$VCPU" = 64 ] && [ "$ARCH" = arm64 ] || { echo "inputpath: $TYPE is $VCPU vCPU $ARCH, want 64 arm64" >&2; exit 1; }
TMAX=$(awk -v p="$PRICE" -v c="$COST_MAX" 'BEGIN{t = int((c - 0.005) / p * 60); if (t > 240) t = 240; print t}')
[ -n "$TTL" ] || TTL=$TMAX
[[ "$TTL" =~ ^[0-9]+$ ]] && [ "$TTL" -le "$TMAX" ] && [ "$TTL" -gt 0 ] ||
  { echo "inputpath: TTL $TTL min: at most $TMAX (the cost rule: TTL x \$$PRICE/h <= \$$COST_MAX, and <= 240)" >&2; exit 1; }
COST=$(awk -v p="$PRICE" -v t="$TTL" 'BEGIN{printf "%.2f", p * t / 60 + 0.005}')
awk -v c="$COST" -v m="$COST_MAX" 'BEGIN{exit !(c <= m + 1e-9)}' || { echo "inputpath: cost_limit \$$COST > \$$COST_MAX" >&2; exit 1; }

B=aws-kraken2-942542972736-us-west-2; DATA=aws-kraken2/data; DBP=s3://$B/$DATA/k2_standard_08_GB_20260626
DS="$DBP/hash.k2d $DBP/opts.k2d $DBP/taxo.k2d"
RW="s3://$B/$DATA/"
READY=1; ACC=""
if KEYS=$(python3 scripts/inputpath/inputs.py keys scripts/inputpath/inputs.tsv 2> "${TMPDIR:-/tmp}/inputpath-inputs.err"); then
  DS="$DS $(tr '\n' ' ' <<< "$KEYS" | sed 's/ $//')"
  ACC=$(python3 scripts/inputpath/inputs.py accessions scripts/inputpath/inputs.tsv)
  for k in $KEYS; do case "$k" in "$RW"*) ;; *) RW="$RW ${k%/*}/" ;; esac; done
else
  READY=0
fi
RWJ=$(tr ' ' '\n' <<< "$RW" | sort -u | grep . | jq -R . | jq -sc .)
PARAMS="FAMILY=$FAMILY; ENGINE=$ENGINE; TTL_S=$((TTL * 60)); REPS=$REPS; THREADS=\"$THREADS\"; PS=\"$PS\"; CHUNKS=\"$CHUNKS\"; MAIN_THP=$MAIN_THP; THP_CONTRAST=$THP_CONTRAST; PIPE_BYTES=$PIPE_BYTES; PIPE_CONTRAST=$PIPE_CONTRAST; POINT_TIMEOUT=$POINT_TIMEOUT; ID_TIMEOUT=$ID_TIMEOUT; MARGIN_S=$MARGIN_S; LAUNCH_LEAD_S=120; G1_REF=$G1_REF; RG2_SCRIPT=$RG2_SCRIPT"
BODY=$(awk -v p="$PARAMS" '$0 == "@PARAMS@" {print "# Parameters (scripts/inputpath/mkspec.sh):"; print p; q = p; gsub(/'\''/, "", q); print "PARAMS_LINE='\''" q "'\''"; next} {print}' scripts/inputpath/inputpath.body.sh)
grep -q '^PARAMS_LINE=' <<< "$BODY" || { echo "inputpath: the body has no @PARAMS@ line" >&2; exit 1; }
SPEC=runs/inputpath-$FAMILY-$ENGINE.json
jq -n --arg body "$BODY" --arg task "inputpath-$FAMILY-$ENGINE" --arg type "$TYPE" --arg az "$AZ" --arg ttl "${TTL}m" \
  --argjson cost "$COST" --arg ds "$DS" --arg acc "$ACC" --argjson rw "$RWJ" '{
  task_id: $task,
  command: ["bash", "-c", $body],
  resources: {instance_type: $type, architecture: "arm64", disk_gib: 40, s3_read_write: $rw},
  placement: {availability_zone: $az},
  env: {AK2_REGION: "us-west-2", AK2_ACCESSIONS: $acc, AK2_DATASETS: $ds},
  lifecycle: {ttl: $ttl, on_complete: "terminate", cost_limit: $cost}
}' > "$SPEC" || exit 1
ln -sf inputpath.sh "scripts/post/inputpath-$FAMILY-$ENGINE.sh" || exit 1
printf 'inputpath: %s: %s (%d vCPU, %d GiB, $%s/h on demand, truffle %s), %s, TTL %d min, cost_limit $%s (<= $%s)\n' \
  "$SPEC" "$TYPE" "$VCPU" "$((MEM / 1024))" "$PRICE" "$(truffle version 2> /dev/null | awk '/Version:/{print $2}')" "$ENGINE" "$TTL" "$COST" "$COST_MAX"
python3 scripts/inputpath/estimate.py --engine "$ENGINE" --ttl-min "$TTL" --reps "$REPS" --threads "$THREADS" --ps "$PS" \
  --chunks "$CHUNKS" --thp-contrast "$THP_CONTRAST" --pipe-contrast "$PIPE_CONTRAST" | sed 's/^/inputpath: /'
if [ "$READY" = 0 ]; then
  echo "inputpath: NOT READY: scripts/inputpath/inputs.tsv is not a valid input list; the body would fail at its input check:" >&2
  sed 's/^/  /' "${TMPDIR:-/tmp}/inputpath-inputs.err" | head -8 >&2
fi
echo "inputpath: rehearse: make rehearse SPEC=$SPEC"
echo "inputpath: launch (Scott's call; commit and push first): make run GATE=inputpath SPEC=$SPEC   (at most \$$COST: TTL ${TTL}m x \$$PRICE/h)"
if [ "$LAUNCH" = 1 ]; then
  [ "$READY" = 1 ] || { echo "inputpath: LAUNCH=1 refused: NOT READY" >&2; exit 1; }
  git diff --quiet HEAD -- "$SPEC" && git ls-files --error-unmatch "$SPEC" > /dev/null 2>&1 ||
    { echo "inputpath: LAUNCH=1 refused: $SPEC changed or is not committed (commit it, then launch)" >&2; exit 1; }
  exec scripts/run.sh inputpath "$SPEC"
fi
exit 0
