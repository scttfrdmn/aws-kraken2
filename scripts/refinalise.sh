#!/usr/bin/env bash
# scripts/refinalise.sh results/<gate>/<run-id>: finish a run whose local driver (scripts/run.sh)
# did not: its finalisation failed, it was killed, or the fetch failed (docs/run.md, "Failure
# looks like"). It:
#   1. fetches the run prefix into the run dir, as run.sh does, and tags its objects;
#   2. derives tables/phases.tsv and tables/requests.tsv from log/run.log and out/requests.tsv
#      (run.sh's own rules);
#   3. re-describes the instance if EC2 still can (terminated instances stay describable for
#      about an hour), and fills only manifest fields that are null: instance ami/az/launch_time/
#      architecture, final state, terminated_at, task (completion record), preflight, phases,
#      requests, billed seconds and cost_usd;
#   4. records what it did, and every gap, in .manifest_repair.
# When the instance is no longer describable, terminated_at stays null; stop and billed_seconds
# then end at the completion record's ended_at (else the last phase start), and the gap is
# named. It never overwrites a field that is set. It refuses a manifest that is finalised and
# already has its completion record.
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
. scripts/ak2.env
export AWS_PROFILE
D=${1:?usage: scripts/refinalise.sh results/<gate>/<run-id>}
D=${D%/}
M="$D/manifest.json"
[ -s "$M" ] || { echo "refinalise: no $M" >&2; exit 2; }
if [ -n "$(jq -r '.manifest_finalised_at // empty' "$M")" ] && [ "$(jq -r '.task // empty' "$M")" != "" ]; then
  echo "refinalise: $M is finalised and has its completion record" >&2; exit 2
fi
PREFIX=$(jq -r .s3_prefix "$M"); IID=$(jq -r .launch.instance_id "$M"); REG=$(jq -r .launch.region "$M")
[ -n "$PREFIX" ] && [ "$PREFIX" != null ] || { echo "refinalise: no s3_prefix in $M" >&2; exit 2; }
GAPS=()

# 1. fetch and tag
aws s3 cp --only-show-errors --recursive "$PREFIX/" "$D/" || { echo "refinalise: fetch of $PREFIX failed" >&2; exit 2; }
TASK_ID=$(jq -r .task_id "$M")
[ -s "$D/spawn/$TASK_ID/completion.json" ] && [ ! -s "$D/completion.json" ] && cp "$D/spawn/$TASK_ID/completion.json" "$D/completion.json"
TAGLINE=$(scripts/tag-objects.sh "$PREFIX/" 2>&1); TAG_OK=$?

# 2. derived tables (run.sh's rules)
mkdir -p "$D/tables"
PH='null'
if [ -s "$D/log/run.log" ]; then
  awk -F'\t' 'BEGIN{print "phase\tstart\tseconds\tcold"}
    $1=="ak2-phase"{n++; name[n]=$4; at[n]=$2; ep[n]=$3; cold[n]=($5==""?"no":$5)}
    END{for(i=1;i<=n;i++){ if(name[i]=="end") continue
          if(i<n) printf "%s\t%s\t%d\t%s\n", name[i], at[i], ep[i+1]-ep[i], cold[i]
          else printf "%s\t%s\t\t%s\n", name[i], at[i], cold[i] }}' "$D/log/run.log" > "$D/tables/phases.tsv"
  PH=$(awk -F'\t' 'NR>1' "$D/tables/phases.tsv" | jq -R -s 'split("\n") | map(select(. != "") | split("\t")
    | {phase:.[0], start:.[1], seconds:(.[2] | tonumber? // null), cold:(.[3] == "yes")})') || PH='null'
else GAPS+=("no log/run.log: no phases"); fi
RQ='null'
if [ -s "$D/out/requests.tsv" ]; then
  cp "$D/out/requests.tsv" "$D/tables/requests.tsv"
  RQ=$(awk -F'\t' 'NR>1' "$D/out/requests.tsv" | jq -R -s 'split("\n") | map(select(. != "") | split("\t")
      | {phase:.[0], op:.[1], count:(.[2] | tonumber? // null), bucket:.[3]})
    | {total:(map(.count // 0)|add // 0), unparsed_rows:(map(select(.count == null))|length),
       by_op:(group_by(.op) | map({key:.[0].op, value:(map(.count // 0)|add)}) | from_entries), rows:.}') || RQ='null'
else GAPS+=("no out/requests.tsv: no request counts"); fi
REC='null'; [ -s "$D/completion.json" ] && REC=$(cat "$D/completion.json") || GAPS+=("no completion record in the prefix")
PRE='null'; [ -s "$D/preflight.json" ] && PRE=$(cat "$D/preflight.json")
LAST_PHASE=$(awk -F'\t' '$1=="ak2-phase"{t=$2} END{print t}' "$D/log/run.log" 2>/dev/null)

# 3. the instance, if EC2 still describes it
DESC=$(aws ec2 describe-instances --region "$REG" --instance-ids "$IID" --query 'Reservations[0].Instances[0]' --output json 2>"$D/.refinalise.err") || DESC=null
[ "$DESC" = null ] && [ "$(jq -r '.instance.terminated_at // empty' "$M")" = "" ] &&
  GAPS+=("instance $IID no longer describable ($(tr '\n' ' ' < "$D/.refinalise.err" | cut -c1-160)): terminated_at unknown; stop = completion ended_at (else last phase start), so billed_seconds and cost_usd undercount by the shutdown time (about 10-15 s)")
rm -f "$D/.refinalise.err"
STATE=$(echo "$DESC" | jq -r '.State.Name // empty')
END_AT=$(echo "$DESC" | jq -r '.StateTransitionReason // empty' | sed -n 's/.*(\([0-9-]* [0-9:]*\) GMT).*/\1/p')
END_ISO=""; [ -n "$END_AT" ] && END_ISO="${END_AT/ /T}Z"
GAPJ=$(printf '%s\n' "${GAPS[@]+"${GAPS[@]}"}" | jq -R -s 'split("\n") | map(select(. != ""))')

TMP=$(mktemp) || exit 2
jq --argjson d "$DESC" --arg state "$STATE" --arg end "$END_ISO" --argjson rec "$REC" --argjson pre "$PRE" \
   --argjson ph "$PH" --argjson rq "$RQ" --arg last "$LAST_PHASE" --argjson gaps "$GAPJ" \
   --argjson tagok "$([ "$TAG_OK" = 0 ] && echo true || echo false)" --arg tagline "$TAGLINE" \
   --arg fin "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  ([paths(. == null)] | map(map(tostring) | join("."))) as $nulls_before
  | if $d != null then
      .instance.ami //= $d.ImageId | .instance.az //= $d.Placement.AvailabilityZone
      | .instance.launch_time //= $d.LaunchTime | .instance.architecture //= $d.Architecture
      | .instance.final_state //= (if $state == "" then null else $state end)
      | .instance.terminated_at //= (if $end == "" then null else $end end)
    else . end
  | .task //= $rec | .preflight //= $pre | .phases //= $ph | .requests //= $rq
  | .object_tags = {ok: $tagok, line: $tagline}
  | .start //= .instance.launch_time
  | .stop_basis = (if .instance.terminated_at then "terminated_at"
                   elif .stop then "kept" elif ($rec != null and $rec.ended_at) then "completion ended_at (instance not describable)"
                   elif $last != "" then "last phase start (instance not describable)" else "unknown" end)
  | .stop //= (.instance.terminated_at // (if $rec != null then $rec.ended_at else null end) // (if $last == "" then null else $last end))
  | .billed_seconds //= (if .stop and .start then ((.stop|sub("\\+00:00$";"Z")|fromdateiso8601) - (.start|sub("\\.[0-9]+";"")|sub("\\+00:00$";"Z")|fromdateiso8601)) else null end)
  | .cost_usd //= (if .billed_seconds and .truffle_price_usd_per_hour then
       ((([.billed_seconds, 60]|max) * .truffle_price_usd_per_hour / 3600) * 1e6 | round / 1e6) else null end)
  | .cost_basis //= "on-demand truffle price x (terminated_at - launch_time), 60 s minimum; compute only, excludes EBS and S3 requests"
  | .manifest_finalised_at //= $fin
  | .manifest_repair = ((.manifest_repair // {}) + {by:"scripts/refinalise.sh", at:$fin,
      fields_null_before:$nulls_before, gaps:$gaps})
' "$M" > "$TMP" && mv "$TMP" "$M" || { echo "refinalise: jq failed" >&2; rm -f "$TMP"; exit 2; }
jq -c '{instance, start, stop, stop_basis, billed_seconds, cost_usd, task_exit:.task.exit_code, gaps:.manifest_repair.gaps}' "$M"
