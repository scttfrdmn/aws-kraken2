#!/usr/bin/env bash
# scripts/refinalise.sh [--force] results/<gate>/<run-id>: finish a run whose local driver
# (scripts/run.sh) did not: its finalisation failed, it was killed, or the fetch failed
# (docs/run.md, "Failure looks like"). It:
#   1. fetches the run prefix into the run dir, as run.sh does, and tags its objects;
#   2. derives tables/phases.tsv and tables/requests.tsv from log/run.log and out/requests.tsv
#      (run.sh's own rules);
#   3. re-describes the instance if EC2 still can (terminated instances stay describable for
#      about an hour), and fills only manifest fields that are unset (null or ""): instance
#      ami/az/launch_time/architecture, final state, terminated_at, task (completion record),
#      preflight, phases, requests, object_tags, stop, billed seconds and cost_usd;
#   4. records what it did, the object-tag result and every gap in a repair record.
# When EC2 has aged the instance out (InvalidInstanceID.NotFound, or a query printing None),
# final_state becomes "terminated" with instance.final_state_basis "aged_out"; terminated_at
# stays null; stop and billed_seconds end at the completion record's ended_at (else the last
# phase start), cost_basis says so, and the gap is named. Any other describe error is a gap, not
# a state. Set fields are never overwritten; final_state with final_state_basis "unknown" (run.sh
# never got an answer) counts as unset.
# It refuses a manifest that already has .manifest_repair, or is finalised with its completion
# record, unless --force. The first repair is .manifest_repair; a forced later one is appended
# to .manifest_repairs[].
set -uo pipefail
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
. scripts/ak2.env
export AWS_PROFILE
FORCE=false
[ "${1:-}" = --force ] && { FORCE=true; shift; }
D=${1:?usage: scripts/refinalise.sh [--force] results/<gate>/<run-id>}
D=${D%/}
M="$D/manifest.json"
[ -s "$M" ] || { echo "refinalise: no $M" >&2; exit 2; }
if ! $FORCE; then
  if jq -e 'has("manifest_repair")' "$M" >/dev/null; then
    echo "refinalise: $M already has .manifest_repair; --force appends another repair" >&2; exit 2
  fi
  if [ -n "$(jq -r '.manifest_finalised_at // empty' "$M")" ] && [ -n "$(jq -r '.task // empty' "$M")" ]; then
    echo "refinalise: $M is finalised and has its completion record; --force to repair anyway" >&2; exit 2
  fi
fi
PREFIX=$(jq -r .s3_prefix "$M"); IID=$(jq -r .launch.instance_id "$M"); REG=$(jq -r .launch.region "$M")
[ -n "$PREFIX" ] && [ "$PREFIX" != null ] || { echo "refinalise: no s3_prefix in $M" >&2; exit 2; }
AWS_TO=(--cli-connect-timeout 10 --cli-read-timeout 30)
GAPS=()

# 1. fetch and tag
aws "${AWS_TO[@]}" s3 cp --only-show-errors --recursive "$PREFIX/" "$D/" ||
  { echo "refinalise: fetch of $PREFIX failed" >&2; exit 2; }
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
REC='null'
if [ -s "$D/completion.json" ]; then REC=$(cat "$D/completion.json"); else GAPS+=("no completion record in the prefix"); fi
PRE='null'; [ -s "$D/preflight.json" ] && PRE=$(cat "$D/preflight.json")
LAST_PHASE=$(awk -F'\t' '$1=="ak2-phase"{t=$2} END{print t}' "$D/log/run.log" 2>/dev/null)

# 3. the instance, if EC2 still describes it
ERRF=$(mktemp)
DESC=$(aws "${AWS_TO[@]}" ec2 describe-instances --region "$REG" --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0]' --output json 2>"$ERRF"); DRC=$?
DERR=$(tr '\n' ' ' < "$ERRF" | cut -c1-160); rm -f "$ERRF"
AGED=false
if [ "$DRC" = 0 ] && [ -n "$DESC" ] && [ "$DESC" != null ] && [ "$DESC" != None ]; then
  :
elif [ "$DRC" = 0 ] || grep -q 'InvalidInstanceID\.NotFound' <<< "$DERR"; then
  AGED=true; DESC=null
else
  DESC=null; GAPS+=("describe-instances failed (rc $DRC: $DERR): instance fields not filled")
fi
if $AGED && [ -z "$(jq -r '.instance.terminated_at // empty' "$M")" ]; then
  GAPS+=("instance $IID aged out of EC2 (${DERR:-query printed None}): terminated_at unknown; stop = completion ended_at (else last phase start), so billed_seconds and cost_usd undercount by the shutdown time (about 10-15 s)")
fi
STATE=$(echo "$DESC" | jq -r '.State.Name // empty')
END_AT=$(echo "$DESC" | jq -r '.StateTransitionReason // empty' | sed -n 's/.*(\([0-9-]* [0-9:]*\) GMT).*/\1/p')
END_ISO=""; [ -n "$END_AT" ] && END_ISO="${END_AT/ /T}Z"
GAPJ=$(printf '%s\n' "${GAPS[@]+"${GAPS[@]}"}" | jq -R -s 'split("\n") | map(select(. != ""))')

TMP=$(mktemp) || exit 2
jq --argjson d "$DESC" --arg state "$STATE" --arg end "$END_ISO" --argjson rec "$REC" --argjson pre "$PRE" \
   --argjson ph "$PH" --argjson rq "$RQ" --arg last "$LAST_PHASE" --argjson gaps "$GAPJ" --argjson aged "$AGED" \
   --argjson tagok "$([ "$TAG_OK" = 0 ] && echo true || echo false)" --arg tagline "$TAGLINE" \
   --argjson force "$FORCE" --arg fin "$(date -u +%Y-%m-%dT%H:%M:%SZ)" -f scripts/lib/refinalise.jq "$M" > "$TMP" &&
  mv "$TMP" "$M" || { echo "refinalise: jq failed" >&2; rm -f "$TMP"; exit 2; }
# 5. the scoped orphan check, as run.sh records it, if the manifest has none
if [ "$(jq -r '.orphan_check // empty' "$M")" = "" ]; then
  AK2_ORPHANS_JSON="$D/orphan_check.json" scripts/orphans.sh --own "$TASK_ID" "$IID" > "$D/orphans.txt" 2>&1
  ORC=$?
  OC=null
  [ -s "$D/orphan_check.json" ] && OC=$(jq -e -c --argjson rc "$ORC" 'if type == "object" and .mode == "own" then . + {rc: $rc, own_gone: (.own_gone == true and $rc == 0), recorded_by: "scripts/refinalise.sh"} else null end' "$D/orphan_check.json" 2>/dev/null) || OC=null
  rm -f "$D/orphan_check.json"
  TMP=$(mktemp) && jq --argjson oc "$OC" '.orphan_check = $oc' "$M" > "$TMP" && mv "$TMP" "$M" ||
    { echo "refinalise: could not record the orphan check" >&2; rm -f "$TMP"; }
  [ "$ORC" = 0 ] || echo "refinalise: orphan check rc $ORC (see $D/orphans.txt)" >&2
fi
# 6. utilisation, as run.sh derives it (docs/run.md, "Utilisation")
python3 scripts/lib/util.py "$D" > "$D/tables/util.log" 2>&1 || echo "refinalise: util.py failed (see $D/tables/util.log)" >&2
jq -c '{instance, start, stop, stop_basis, billed_seconds, cost_usd, cost_basis, task_exit:.task.exit_code, orphan_check:(.orphan_check | {rc, own_gone}?),
        repair:((.manifest_repairs // [])[-1] // .manifest_repair | {at, forced, gaps, stop_basis})}' "$M"
