#!/usr/bin/env bash
# Pre-launch cost_limit check (docs/run.md, "cost_limit"):
#
#   scripts/lib/cost_check.sh REGION INSTANCE_TYPE TTL COST_LIMIT [NODES]
#
# Scott, 2026-10-09 (#25): there is no budget cap; spend is tracked only, and each run's TTL and
# cost_limit are runaway backstops. So a cost_limit is checked against what the run can cost,
# not against a budget: it must be at most
#
#   NODES x (TTL in hours x the truffle on-demand price x (1 + epsilon) + $0.01)
#
# where NODES x COST_LIMIT is the cohort's total (cost_limit is per member), epsilon is
# AK2_COST_EPSILON (default 0.10), and the cent per node covers a cost_limit rounded up to the cent
# (scripts/g3/mkspec.sh sets TTL x price + $0.005, to the cent). Anything above is taken for a
# typo and refused. If AK2_MAX_COST_USD is set (it is unset by default; scripts/ak2.env does not
# set it), NODES x COST_LIMIT must also be at most it: an optional override, not a budget.
#
# stdout: one JSON object (the record). stderr: the verdict.
# exit 0: within; 1: above (refuse); 2: cannot judge (refuse too: no price, bad arguments).
set +e
set -uo pipefail
REGION=${1:-}; TYPE=${2:-}; TTL=${3:-}; COST=${4:-}; NODES=${5:-1}
die() { echo "cost_check: $*" >&2; exit 2; }
[ -n "$REGION" ] && [ -n "$TYPE" ] && [[ "$TTL" =~ ^([0-9]+[hms])+$ ]] && [[ "$COST" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
  [[ "$NODES" =~ ^[1-9][0-9]*$ ]] || die "usage: cost_check.sh REGION TYPE TTL(e.g. 1h30m) COST_LIMIT [NODES]"
EPS=${AK2_COST_EPSILON:-0.10}
[[ "$EPS" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "AK2_COST_EPSILON '$EPS' is not a number"
OVR=${AK2_MAX_COST_USD:-}
[ -z "$OVR" ] || [[ "$OVR" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "AK2_MAX_COST_USD '$OVR' is not a number"
command -v truffle >/dev/null || die "truffle not on PATH"
t=$TTL; TTL_S=0
while [[ $t =~ ^([0-9]+)([hms])(.*)$ ]]; do
  n=${BASH_REMATCH[1]}
  case ${BASH_REMATCH[2]} in h) TTL_S=$((TTL_S + n * 3600)) ;; m) TTL_S=$((TTL_S + n * 60)) ;; s) TTL_S=$((TTL_S + n)) ;; esac
  t=${BASH_REMATCH[3]}
done
[ "$TTL_S" -gt 0 ] || die "TTL '$TTL' is zero"

PRICE=$(truffle find "$TYPE" --regions "$REGION" --show-price --skip-azs -o json 2>/dev/null |
  jq --arg t "$TYPE" '[.. | objects | select(has("on_demand_price") and .instance_type == $t)][0].on_demand_price // empty')
[[ "$PRICE" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]] && awk -v p="$PRICE" 'BEGIN{exit !(p > 0)}' ||
  die "truffle gave no on-demand price for $TYPE in $REGION ('$PRICE'); cannot judge cost_limit"

REC=$(jq -nc --arg region "$REGION" --arg type "$TYPE" --arg ttl "$TTL" --argjson ttl_s "$TTL_S" \
  --argjson cost "$COST" --argjson n "$NODES" --argjson price "$PRICE" --argjson eps "$EPS" --arg ovr "$OVR" '
  ($ttl_s / 3600 * $price) as $exp
  | ($exp * (1 + $eps) + 0.01) as $max
  | {region:$region, instance_type:$type, ttl:$ttl, ttl_s:$ttl_s, nodes:$n, price_usd_per_hour:$price,
     epsilon:$eps, cent_allowance_usd:0.01, cost_limit_usd:$cost, expected_usd:($exp * 1e4 | round / 1e4),
     max_cost_limit_usd:($max * 1e4 | round / 1e4), total_cost_limit_usd:($cost * $n * 1e4 | round / 1e4),
     total_max_usd:($max * $n * 1e4 | round / 1e4),
     max_cost_usd_override:(if $ovr == "" then null else ($ovr | tonumber) end),
     within_price:($cost <= $max + 1e-9),
     within_override:(if $ovr == "" then true else ($cost * $n <= ($ovr | tonumber) + 1e-9) end)}
  | .ok = (.within_price and .within_override)') || die "jq failed"
echo "$REC"
MSG=$(echo "$REC" | jq -r '"\(.nodes) x cost_limit $\(.cost_limit_usd) = $\(.total_cost_limit_usd); TTL \(.ttl) x $\(.price_usd_per_hour)/h \(.instance_type) = $\(.expected_usd) per node, max $\(.max_cost_limit_usd) per node (epsilon \(.epsilon) + $0.01) = $\(.total_max_usd)"')
if [ "$(echo "$REC" | jq -r .ok)" = true ]; then echo "cost_check: ok: $MSG" >&2; exit 0; fi
if [ "$(echo "$REC" | jq -r .within_price)" != true ]; then
  echo "cost_check: REFUSED: $MSG. A cost_limit above what TTL x price can cost is taken for a typo; set it to TTL x price (scripts/g3/mkspec.sh does)." >&2
else
  echo "cost_check: REFUSED: $MSG, above the AK2_MAX_COST_USD override \$$OVR." >&2
fi
exit 1
