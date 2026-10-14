#!/usr/bin/env bash
# make test: scripts/run.sh's pre-launch refusals, on the real run.sh in a scratch repo (a copy of
# scripts/ and the recorded cohort's runs.tsv), with stubbed spawn, truffle, aws and curl and a
# stubbed pin identity (no AWS, no upstream checkout). Each case runs run.sh until it refuses;
# a case that must pass a check is run until a later, known stop (the stub refuses
# `aws s3 presign`: "could not presign"), which run.sh reaches only after the checks under test.
#   cohort sha   AK2_COHORT_ID naming another commit than HEAD is refused; HEAD's sha7 passes;
#   reference    an @-reference with a body that never calls accessions.sh is refused; with one,
#                it passes.
#   conductor    GATE=conductor only with runs/conductor*.json and the other way round; a dirty tree
#                (untracked included) and a HEAD not on origin are refused; AK2_FINALISED_BY other than
#                conductor, or conductor without a conductor run id, is refused; a clean, pushed HEAD
#                passes.
#   launch fail  (review B2) run.sh driven through sizing, cost, quota, user data and the payload to a
#                spawn task run that fails with InsufficientInstanceCapacity: the manifest is
#                finalised as a non-run (launch.error, instance.final_state never-launched, cost 0,
#                finalised_by kept), with the scoped orphan check recorded; with that task "alive"
#                the manifest is not finalised and run.sh exits 3.
set +e
set -uo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/run-sh-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAILN=0
ok() { echo "run_sh_test: ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "run_sh_test: FAIL $*"; FAILN=$((FAILN + 1)); }

mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\ncase "$1" in version) echo "Version: 0.123.0" ;; *) echo "stub spawn: $*" >&2; exit 2 ;; esac\n' > "$T/bin/spawn"
printf '#!/usr/bin/env bash\ncase "$1" in version) echo "Version: 0.57.1" ;; *) echo "[]" ;; esac\n' > "$T/bin/truffle"
printf '#!/usr/bin/env bash\nprintf "HTTP/1.1 200 OK\\r\\nx-amz-bucket-region: us-west-2\\r\\n\\r\\n"\n' > "$T/bin/curl"
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "s3 presign") echo "stub aws: presign refused (the test's stop)" >&2; exit 1 ;;
  *) echo "stub aws: unexpected $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$T/bin/"*

R="$T/repo"; mkdir -p "$R/runs" "$R/results/cohort/PRJNA398089"
cp -R "$HERE/scripts" "$R/"
cp "$HERE/results/cohort/PRJNA398089/runs.tsv" "$R/results/cohort/PRJNA398089/"
cat > "$R/scripts/pin-identity.sh" <<'EOF'
pin_identity() { UPSTREAM_SHA=2731b35f7abb26ec926517274f3d87e78d42fd76; UPSTREAM_DESCRIBE=2.17.2-20-g2731b35; }
EOF
spec() {  # spec FILE ACCESSIONS BODY
  jq -n --arg acc "$2" --arg body "$3" '{command:["bash","-c",$body],
    env:{AK2_REGION:"us-west-2", AK2_ACCESSIONS:$acc, AK2_ALLOW_NO_BUCKETS:"1"},
    lifecycle:{ttl:"10m", cost_limit:0.1, on_complete:"terminate"}}' > "$R/runs/$1"
}
spec plain.json "" 'echo hi'
spec ref-nobody.json "@PRJNA398089:1-3" 'echo hi'
spec ref-body.json "@PRJNA398089:1-3" 'ACC=$("$W/repo/scripts/lib/accessions.sh" -r "$W/repo" "$AK2_ACCESSIONS")'
# A ladder spec (PARAMS block, pinned type and AZ) and a scratch AZ list with its evidence, for
# the launch overrides AK2_LADDER_REP and AK2_LAUNCH_AZ.
jq -n --arg body "$(printf '# Parameters (scripts/g3/mkspec-ladder.sh S S5 1):\nRUNG=S5; ARM=S; COHORT=1; WANT_N=1\necho hi')" '{
  command:["bash","-c",$body], resources:{instance_type:"x8g.24xlarge"}, placement:{availability_zone:"us-west-2b"},
  env:{AK2_REGION:"us-west-2", AK2_ACCESSIONS:"", AK2_ALLOW_NO_BUCKETS:"1"},
  lifecycle:{ttl:"10m", cost_limit:0.1, on_complete:"terminate"}}' > "$R/runs/ladder.json"
cp "$R/runs/plain.json" "$R/runs/conductor-x.json"
jq '.lifecycle.ttl = "72h"' "$R/runs/plain.json" > "$R/runs/conductor-72h.json"
jq '.lifecycle.ttl = "73h"' "$R/runs/plain.json" > "$R/runs/conductor-73h.json"
jq '.lifecycle.ttl = "9h"' "$R/runs/plain.json" > "$R/runs/plain-9h.json"
jq '.lifecycle.cost_limit = 0.02' "$R/runs/plain.json" > "$R/runs/deep.json"
# Pinned tools (scripts/lib/tools_pin.sh): a wrong-version spawn dir, and a "Homebrew" spawn on PATH.
mkdir -p "$T/wrongbin" "$T/brew"
printf '#!/usr/bin/env bash\necho "Version: 0.128.2"\n' > "$T/wrongbin/spawn"; cp "$T/bin/truffle" "$T/wrongbin/"
printf '#!/usr/bin/env bash\necho "Version: 0.128.2"; echo "brew spawn ran: $*" >&2; exit 2\n' > "$T/brew/spawn"
chmod +x "$T/wrongbin/spawn" "$T/brew/spawn"
mkdir -p "$R/results/ev"
echo '{"instance":{"type":"x8g.24xlarge","az":"us-west-2c"}}' > "$R/results/ev/manifest.json"
printf 'type\taz\tevidence\nx8g.24xlarge\tus-west-2c\tresults/ev/manifest.json\n' > "$R/scripts/g3/ladder.azs.tsv"
( cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm t ) || { echo "run_sh_test: cannot make the scratch repo"; exit 1; }
HEAD7=$(git -C "$R" rev-parse --short=7 HEAD)
OTHER7=$(printf '%07x' $(( (16#$HEAD7 + 1) % 268435456 )))

# run NAME SPEC [COHORT_ID]: run.sh in the scratch repo; OUT and RC.
run() {
  local spec=$2 cid=${3:-}  # $1: the case name, for the reader
  if [ -n "$cid" ]; then
    OUT=$(cd "$R" && PATH="$T/bin:$PATH" K2_SHARED_ROOT="$R" AK2_TOOLS_BIN="${TOOLS_BIN:-$T/bin}" AK2_COHORT_ID="$cid" AK2_COHORT_RANK=0 AK2_COHORT_N=2 \
      scripts/run.sh t "runs/$spec" 2>&1)
  else
    OUT=$(cd "$R" && env ${RUN_ENV:-} PATH="$T/bin:$PATH" K2_SHARED_ROOT="$R" AK2_TOOLS_BIN="${TOOLS_BIN:-$T/bin}" scripts/run.sh t "runs/$spec" 2>&1)
  fi
  RC=$?
  rm -rf "$R/results/t"
}
reached_stop() { [[ "$OUT" == *"could not presign"* ]]; }

run cohort-other plain.json "20261009-000000-$OTHER7-beef-n2"
[ "$RC" = 2 ] && [[ "$OUT" == *"names commit $OTHER7, but HEAD is $HEAD7"* ]] && ! reached_stop &&
  ok "cohort sha: a cohort id naming $OTHER7 (HEAD $HEAD7) is refused" || bad "cohort sha: other: rc $RC: $(echo "$OUT" | tail -2)"
run cohort-head plain.json "20261009-000000-$HEAD7-beef-n2"
reached_stop && [[ "$OUT" != *"names commit"* ]] && ok "cohort sha: HEAD's sha7 passes (run.sh reached the presign)" ||
  bad "cohort sha: head: rc $RC: $(echo "$OUT" | tail -2)"
run ref-nobody ref-nobody.json
[ "$RC" = 2 ] && [[ "$OUT" == *"never calls scripts/lib/accessions.sh"* ]] && ! reached_stop &&
  ok "reference: a body without accessions.sh is refused" || bad "reference: nobody: rc $RC: $(echo "$OUT" | tail -2)"
run ref-body ref-body.json
reached_stop && [[ "$OUT" == *"accessions: @PRJNA398089:1-3 -> 3 runs"* ]] &&
  ok "reference: a body calling accessions.sh passes, the reference expanded" || bad "reference: body: rc $RC: $(echo "$OUT" | tail -2)"

# Launch overrides (docs/run.md, "Launch overrides").
RUN_ENV="AK2_LADDER_REP=0" run rep-bad ladder.json
[ "$RC" = 2 ] && [[ "$OUT" == *"AK2_LADDER_REP=0 refused"* ]] && ! reached_stop &&
  ok "rep: AK2_LADDER_REP=0 is refused" || bad "rep: bad: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_LADDER_REP=2" run rep-plain plain.json
[ "$RC" = 2 ] && [[ "$OUT" == *"no ladder PARAMS block"* ]] && ! reached_stop &&
  ok "rep: AK2_LADDER_REP on a spec that is not a ladder spec is refused" || bad "rep: plain: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_LADDER_REP=2" run rep-ok ladder.json
reached_stop && ok "rep: AK2_LADDER_REP=2 on a ladder spec passes" || bad "rep: ok: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_LAUNCH_AZ=us-west-2d" run az-unlisted ladder.json
[ "$RC" = 2 ] && [[ "$OUT" == *"x8g.24xlarge in us-west-2d is not in scripts/g3/ladder.azs.tsv"* ]] && ! reached_stop &&
  ok "az: an AZ the list does not document is refused" || bad "az: unlisted: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_LAUNCH_AZ=us-west-2c" run az-plain plain.json
[ "$RC" = 2 ] && [[ "$OUT" == *"needs a spec that pins"* ]] && ! reached_stop &&
  ok "az: AK2_LAUNCH_AZ on a spec without a pinned type and AZ is refused" || bad "az: plain: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_LAUNCH_AZ=us-west-2c" run az-listed ladder.json
reached_stop && [[ "$OUT" == *"launch override: x8g.24xlarge in us-west-2c, not the spec's us-west-2b"* ]] &&
  ok "az: a documented AZ passes, the override announced" || bad "az: listed: rc $RC: $(echo "$OUT" | tail -2)"

# The conductor gate (docs/conductor.md).
crun() {  # crun GATE SPEC: run.sh in the scratch repo with RUN_ENV; OUT and RC
  OUT=$(cd "$R" && env ${RUN_ENV:-} PATH="$T/bin:$PATH" K2_SHARED_ROOT="$R" AK2_TOOLS_BIN="${TOOLS_BIN:-$T/bin}" scripts/run.sh "$1" "runs/$2" 2>&1); RC=$?
  rm -rf "$R/results/$1"
}
crun conductor plain.json
[ "$RC" = 2 ] && [[ "$OUT" == *"goes with a runs/conductor*.json spec"* ]] && ! reached_stop &&
  ok "conductor: GATE=conductor with another spec is refused" || bad "conductor: gate/spec: rc $RC: $(echo "$OUT" | tail -2)"
crun t conductor-x.json
[ "$RC" = 2 ] && [[ "$OUT" == *"goes with a runs/conductor*.json spec"* ]] && ! reached_stop &&
  ok "conductor: a conductor spec under another gate is refused" || bad "conductor: spec/gate: rc $RC: $(echo "$OUT" | tail -2)"
crun conductor conductor-x.json
[ "$RC" = 2 ] && [[ "$OUT" == *"git fetch origin failed"* ]] && ! reached_stop &&
  ok "conductor: no origin to clone from is refused" || bad "conductor: no origin: rc $RC: $(echo "$OUT" | tail -2)"
git clone -q --bare "$R" "$T/origin.git" && git -C "$R" remote add origin "$T/origin.git" && git -C "$R" fetch -q origin ||
  bad "conductor: could not make the scratch origin"
crun conductor conductor-x.json
reached_stop && ok "conductor: a clean HEAD on origin passes" || bad "conductor: pushed: rc $RC: $(echo "$OUT" | tail -2)"
crun conductor conductor-72h.json
reached_stop && ok "ttl: a conductor may have 72 h (AK2_CONDUCTOR_MAX_TTL_S)" || bad "ttl: conductor 72h: rc $RC: $(echo "$OUT" | tail -2)"
crun conductor conductor-73h.json
[ "$RC" = 2 ] && [[ "$OUT" == *"exceeds AK2_CONDUCTOR_MAX_TTL_S=259200"* ]] && ! reached_stop &&
  ok "ttl: a conductor above 72 h is refused" || bad "ttl: conductor 73h: rc $RC: $(echo "$OUT" | tail -2)"
crun t plain-9h.json
[ "$RC" = 2 ] && [[ "$OUT" == *"exceeds AK2_MAX_TTL_S=28800"* ]] && ! reached_stop &&
  ok "ttl: a run instance keeps the 8 h ceiling" || bad "ttl: plain 9h: rc $RC: $(echo "$OUT" | tail -2)"
touch "$R/results/stray"
crun conductor conductor-x.json
[ "$RC" = 2 ] && [[ "$OUT" == *"the whole tree must be clean"* ]] && [[ "$OUT" == *"results/stray"* ]] && ! reached_stop &&
  ok "conductor: an untracked results/ file is refused (it would be planned again)" || bad "conductor: dirty: rc $RC: $(echo "$OUT" | tail -2)"
rm -f "$R/results/stray"
( cd "$R" && echo x > notes && git add notes && git -c user.email=t@t -c user.name=t commit -qm unpushed )
crun conductor conductor-x.json
[ "$RC" = 2 ] && [[ "$OUT" == *"is not on origin; push it first"* ]] && ! reached_stop &&
  ok "conductor: a HEAD not on origin is refused" || bad "conductor: unpushed: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_FINALISED_BY=laptop" run finby-bad plain.json
[ "$RC" = 2 ] && [[ "$OUT" == *"only 'conductor'"* ]] && ! reached_stop &&
  ok "finalised_by: a value other than conductor is refused" || bad "finalised_by: bad: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_FINALISED_BY=conductor" run finby-norun plain.json
[ "$RC" = 2 ] && [[ "$OUT" == *"needs AK2_CONDUCTOR_RUN_ID"* ]] && ! reached_stop &&
  ok "finalised_by: conductor without the conductor's run id is refused" || bad "finalised_by: no run: rc $RC: $(echo "$OUT" | tail -2)"
RUN_ENV="AK2_FINALISED_BY=conductor AK2_CONDUCTOR_RUN_ID=20261014-120000-abcdef0" run finby-ok plain.json
reached_stop && ok "finalised_by: conductor with its run id passes" || bad "finalised_by: ok: rc $RC: $(echo "$OUT" | tail -2)"

# Pinned tools: only AK2_TOOLS_BIN's spawn/truffle, at scripts/conductor.tools.tsv's versions.
TOOLS_BIN="$T/nobin" run tools-missing plain.json
[ "$RC" = 2 ] && [[ "$OUT" == *"nobin/spawn is missing; run make tools"* ]] && ! reached_stop &&
  ok "tools: no pinned spawn is refused" || bad "tools: missing: rc $RC: $(echo "$OUT" | tail -2)"
TOOLS_BIN="$T/wrongbin" run tools-wrong plain.json
[ "$RC" = 2 ] && [[ "$OUT" == *"reports version '0.128.2', want 0.123.0"* ]] && ! reached_stop &&
  ok "tools: a pinned dir holding spawn 0.128.2 is refused" || bad "tools: wrong: rc $RC: $(echo "$OUT" | tail -2)"
OUT=$(cd "$R" && PATH="$T/brew:$T/bin:$PATH" K2_SHARED_ROOT="$R" AK2_TOOLS_BIN="$T/bin" scripts/run.sh t runs/plain.json 2>&1); RC=$?; rm -rf "$R/results/t"
reached_stop && [[ "$OUT" != *"brew spawn ran"* ]] &&
  ok "tools: a Homebrew spawn 0.128.2 first on PATH is never used (the pinned one is)" || bad "tools: brew: rc $RC: $(echo "$OUT" | tail -2)"
UD=$(awk '$1=="require" && $2=="github.com/spore-host/spawn"{sub(/^v/,"",$3); print $3}' "$HERE/scripts/udsize/go.mod")
TV=$(awk -F'\t' '$1=="spawn"{print $2; exit}' "$HERE/scripts/conductor.tools.tsv")
[ -n "$UD" ] && [ "$UD" = "$TV" ] && ok "tools: the pinned spawn ($TV) is the one scripts/udsize measures ($UD)" ||
  bad "tools: scripts/conductor.tools.tsv pins spawn $TV but scripts/udsize/go.mod has $UD"

# ---- launch failure (B2): run.sh past every pre-launch step, to a spawn task run that fails.
D="$T/deep"; mkdir -p "$D/bin" "$D/s3"
cat > "$D/bin/spawn" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "version "*) echo "Version: 0.123.0" ;;
  "task run")
    case " $* " in *" --dry-run "*) printf 'Instance: c8g.large (2 vCPU, 4 GiB)\nMax cost: $0.02\n' ;;
      *) echo "launch task: InsufficientInstanceCapacity: We currently do not have sufficient c8g.large capacity" >&2; exit 1 ;; esac ;;
  *) exit 2 ;;
esac
EOF
cat > "$D/bin/truffle" <<'EOF'
#!/usr/bin/env bash
case "$1" in version) echo "Version: 0.57.1" ;; find) printf '[{"instance_type":"%s","on_demand_price":0.07976}]\n' "$2" ;; esac
EOF
cat > "$D/bin/aws" <<'EOF'
#!/usr/bin/env bash
pos=(); skip=0
for a in "$@"; do if [ $skip = 1 ]; then skip=0; continue; fi
  case $a in --region|--query|--output|--expires-in|--filters|--bucket|--key|--tagging|--instance-types|--service-code|--quota-code) skip=1 ;; --*) ;; *) pos+=("$a") ;; esac; done
loc() { echo "$AK2T_S3/${1#s3://}"; }
case "${pos[0]} ${pos[1]}" in
  "s3 presign") echo "https://b.s3.us-west-2.amazonaws.com/x?sig" ;;
  "s3 cp") if [ "${pos[3]}" = - ]; then cat "$(loc "${pos[2]}")"; else mkdir -p "$(dirname "$(loc "${pos[3]}")")"; cp "${pos[2]}" "$(loc "${pos[3]}")"; fi ;;
  "s3api get-object-tagging") echo '{"TagSet":[]}' ;;
  "s3api put-object-tagging") ;;
  "ec2 describe-regions") echo us-west-2 ;;
  "ec2 describe-instances") case " $* " in *" json "*) [ -e "$AK2T_S3/alive" ] && cat "$AK2T_S3/alive" || echo '{"Reservations":[]}' ;; *) ;; esac ;;
  "ec2 describe-instance-types") printf 'c8g.large\t2\n' ;;
  "service-quotas get-service-quota") echo 640.0 ;;
  *) echo "deep aws stub: unexpected $*" >&2; exit 2 ;;
esac
EOF
cp "$T/bin/curl" "$D/bin/"
chmod +x "$D/bin/"*
deep() {  # deep [ENV...]: run.sh on runs/deep.json with the deep stubs; OUT, RC, DM (the manifest)
  rm -rf "$R/results/t"
  OUT=$(cd "$R" && env "$@" PATH="$D/bin:$PATH" K2_SHARED_ROOT="$R" AK2_TOOLS_BIN="$D/bin" AK2T_S3="$D/s3" scripts/run.sh t runs/deep.json 2>&1); RC=$?
  DM=$(ls "$R"/results/t/*/manifest.json 2>/dev/null | head -1)
}
deep AK2_FINALISED_BY=conductor AK2_CONDUCTOR_RUN_ID=20261014-120000-abcdef0
if [ "$RC" = 2 ] && [ -n "$DM" ] && [[ "$OUT" == *"launch failed (rc=1)"* ]] &&
   jq -e '.manifest_finalised_at and .instance.final_state == "never-launched" and .cost_usd == 0 and .billed_seconds == 0
          and (.launch.error | test("spawn task run failed")) and (.launch.spawn_error | test("InsufficientInstanceCapacity"))
          and .orphan_check.own_gone == true and .orphan_check.rc == 0 and .task == null
          and .finalised_by == "conductor" and .finalised_by_run_id == "20261014-120000-abcdef0"' "$DM" > /dev/null; then
  ok "launch fail: a failed spawn task run finalises the manifest as never launched (cost 0, orphan check, finalised_by)"
else bad "launch fail: rc $RC manifest '$DM': $(jq -c '{fin:.manifest_finalised_at, instance, launch, cost_usd}' "$DM" 2>/dev/null) $(echo "$OUT" | tail -3)"; fi
echo '{"Reservations":[{"Instances":[{"InstanceId":"i-x","State":{"Name":"pending"},"InstanceType":"c8g.large","LaunchTime":"2026-10-14T00:00:00Z","Tags":[{"Key":"spawn:task-id","Value":"TASK"}]}]}]}' > "$D/s3/alive.tmpl"
# The scoped check matches the run's task id, known only once run.sh has chosen it: the spawn
# wrapper below writes the "alive" answer under the spec's task id.
mv "$D/bin/spawn" "$D/bin/spawn.real"
cat > "$D/bin/spawn" <<'EOF'
#!/usr/bin/env bash
# As the deep spawn, but the failed launch "leaves" an instance under the spec's task id.
if [ "$1 $2" = "task run" ] && [[ " $* " != *" --dry-run "* ]]; then
  for a in "$@"; do [ "$prev" = --spec ] && spec=$a; prev=$a; done
  sed "s/TASK/$(jq -r .task_id "$spec")/" "$AK2T_S3/alive.tmpl" > "$AK2T_S3/alive"
fi
exec "$(dirname "$0")/spawn.real" "$@"
EOF
chmod +x "$D/bin/spawn"
deep
rm -f "$D/s3/alive"
if [ "$RC" = 3 ] && [ -n "$DM" ] && jq -e '(.manifest_finalised_at | not) and .orphan_check.own_gone == false' "$DM" > /dev/null &&
   [[ "$OUT" == *"MAY BE ALIVE after a failed launch"* ]]; then
  ok "launch fail: when the failed launch's task is alive, the manifest is left unfinalised and run.sh exits 3"
else bad "launch fail (alive): rc $RC: $(jq -c '{fin:.manifest_finalised_at, oc:.orphan_check}' "$DM" 2>/dev/null) $(echo "$OUT" | tail -3)"; fi
rm -rf "$R/results/t"

echo "run_sh_test: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
