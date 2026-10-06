#!/usr/bin/env bash
# scripts/refinalise.sh results/<gate>/<run-id>: finish a manifest whose finalisation failed in
# scripts/run.sh (docs/run.md, "Failure looks like"). It re-describes the run's instance (EC2 keeps
# terminated instances describable for about an hour), fills the instance fields run.sh records
# at launch when they are null (ami, az, launch_time, architecture), and then applies run.sh's own
# finalisation: final state, terminated_at from StateTransitionReason, task record, preflight,
# phases, requests, billed seconds and cost_usd. It records what it did in .manifest_repair.
# It never overwrites a field that is already set, and refuses a manifest that is already
# finalised.
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
. scripts/ak2.env
export AWS_PROFILE
D=${1:?usage: scripts/refinalise.sh results/<gate>/<run-id>}
M="$D/manifest.json"
[ -s "$M" ] || { echo "refinalise: no $M" >&2; exit 2; }
[ "$(jq -r '.manifest_finalised_at // empty' "$M")" = "" ] || { echo "refinalise: $M is already finalised" >&2; exit 2; }
IID=$(jq -r .launch.instance_id "$M"); REG=$(jq -r .launch.region "$M")
DESC=$(aws ec2 describe-instances --region "$REG" --instance-ids "$IID" --query 'Reservations[0].Instances[0]' --output json) ||
  { echo "refinalise: cannot describe $IID" >&2; exit 2; }
STATE=$(echo "$DESC" | jq -r .State.Name)
END_AT=$(echo "$DESC" | jq -r '.StateTransitionReason' | sed -n 's/.*(\([0-9-]* [0-9:]*\) GMT).*/\1/p')
END_ISO=""; [ -n "$END_AT" ] && END_ISO="${END_AT/ /T}Z"
REC='null'; [ -s "$D/completion.json" ] && REC=$(cat "$D/completion.json")
PRE='null'; [ -s "$D/preflight.json" ] && PRE=$(cat "$D/preflight.json")
PH='null'; [ -s "$D/tables/phases.tsv" ] && PH=$(awk -F'\t' 'NR>1' "$D/tables/phases.tsv" | jq -R -s 'split("\n") | map(select(. != "") | split("\t")
    | {phase:.[0], start:.[1], seconds:(.[2] | tonumber? // null), cold:(.[3] == "yes")})')
RQ='null'; [ -s "$D/tables/requests.tsv" ] && RQ=$(awk -F'\t' 'NR>1' "$D/tables/requests.tsv" | jq -R -s 'split("\n") | map(select(. != "") | split("\t")
      | {phase:.[0], op:.[1], count:(.[2] | tonumber? // null), bucket:.[3]})
    | {total:(map(.count // 0)|add // 0), unparsed_rows:(map(select(.count == null))|length),
       by_op:(group_by(.op) | map({key:.[0].op, value:(map(.count // 0)|add)}) | from_entries), rows:.}')
TMP=$(mktemp) || exit 2
jq --argjson d "$DESC" --arg state "$STATE" --arg end "$END_ISO" --argjson rec "$REC" --argjson pre "$PRE" \
   --argjson ph "$PH" --argjson rq "$RQ" --arg fin "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  (.instance | to_entries | map(select(.value == null) | .key)) as $was_null
  | .instance.ami //= $d.ImageId | .instance.az //= $d.Placement.AvailabilityZone
  | .instance.launch_time //= $d.LaunchTime | .instance.architecture //= $d.Architecture
  | .phases //= $ph | .requests //= $rq
  | .instance.final_state = $state
  | .instance.terminated_at = (if $end == "" then null else $end end)
  | .task //= $rec | .preflight //= $pre
  | .start = (.instance.launch_time) | .stop = .instance.terminated_at
  | .billed_seconds = (if .stop then ((.stop|sub("\\+00:00$";"Z")|fromdateiso8601) - (.start|sub("\\.[0-9]+";"")|sub("\\+00:00$";"Z")|fromdateiso8601)) else null end)
  | .cost_usd = (if .billed_seconds and .truffle_price_usd_per_hour then
       ((([.billed_seconds, 60]|max) * .truffle_price_usd_per_hour / 3600) * 1e6 | round / 1e6) else null end)
  | .cost_basis = "on-demand truffle price x (terminated_at - launch_time), 60 s minimum; compute only, excludes EBS and S3 requests"
  | .manifest_finalised_at = $fin
  | .manifest_repair = {by:"scripts/refinalise.sh", at:$fin, filled_from_describe_instances:$was_null,
      why:"run.sh finalisation failed (instance fields null: DescribeInstances returned InvalidInstanceID.NotFound right after launch)"}
' "$M" > "$TMP" && mv "$TMP" "$M" || { echo "refinalise: jq failed" >&2; rm -f "$TMP"; exit 2; }
jq -c '{instance, billed_seconds, cost_usd, task_exit:.task.exit_code, manifest_repair}' "$M"
