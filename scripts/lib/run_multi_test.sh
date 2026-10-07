#!/usr/bin/env bash
# Stub simulation of scripts/run-multi.sh (make test): no AWS. A stubbed `aws` keeps instance
# state in files; a stub member driver (in place of run.sh) runs a foreground "spawn task run"
# child that launches its instance after a delay (sizing takes minutes for real), ignores INT as
# a background job does, then waits for its instance to end. Each scenario checks that no
# instance is left alive, what cohort.json records, and the exit status:
#   term / int   TERM or INT during the launches, before the late launches land: exit 143 / 130,
#                and no instance appears afterwards (the drivers' process groups were stopped);
#   normal       every member completes: exit 0, nothing terminated early;
#   failfast     rank 1 fails while rank 0 runs and rank 2 has not launched yet: both are
#                terminated (rank 2 by a later sweep), exit 1;
#   describe     describe-instances fails during the sweeps: recorded, exit 6;
#   uploads      an unfinished multipart upload under the cohort prefix is aborted.
set +e
set -uo pipefail
HERE=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/run-multi-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
PASS=0; FAILN=0
ok() { echo "run_multi_test: ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "run_multi_test: FAIL $*"; FAILN=$((FAILN + 1)); }

mkdir -p "$T/bin"
cat > "$T/bin/aws" <<'EOF'
#!/usr/bin/env bash
# Stub aws. State: $AK2T_STATE/inst/<id> = "<task-id> <state>"; uploads in $AK2T_STATE/uploads.
S=$AK2T_STATE
arg() { local want=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "ec2 describe-vpcs") echo vpc-test ;;
  "ec2 describe-security-groups")
    echo '{"GroupId":"sg-t","IpPermissions":[{"IpProtocol":"-1","UserIdGroupPairs":[{"GroupId":"sg-t"}],"IpRanges":[],"Ipv6Ranges":[],"PrefixListIds":[]},{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]}' ;;
  "ec2 describe-instances")
    [ -e "$S/fail-describe" ] && { echo "An error occurred (RequestLimitExceeded)" >&2; exit 255; }
    f=$(arg --filters "$@"); task=${f#Name=tag:spawn:task-id,Values=}
    for i in "$S"/inst/*; do [ -e "$i" ] || continue
      read -r t st < "$i"; [ "$t" = "$task" ] && [ "$st" != terminated ] && basename "$i"; done | tr '\n' ' ' ;;
  "ec2 terminate-instances")
    shift 2; seen=0
    while [ $# -gt 0 ]; do case $1 in --instance-ids) shift; while [ $# -gt 0 ] && [[ $1 != --* ]]; do
      read -r t st < "$S/inst/$1"; echo "$t terminated" > "$S/inst/$1"; echo "terminate $1" >> "$S/log"; shift; done ;; *) shift ;; esac; done ;;
  "ec2 wait")
    for i in "$S"/inst/*; do [ -e "$i" ] || continue; read -r t st < "$i"; [ "$st" = terminated ] || exit 255; done ;;
  "s3api list-multipart-uploads") if [ -s "$S/uploads" ]; then cat "$S/uploads"; fi; exit 0 ;;
  "s3api abort-multipart-upload") echo "abort $(arg --key "$@") $(arg --upload-id "$@")" >> "$S/log"; : > "$S/uploads" ;;
  "s3 cp") exit 0 ;;
  *) echo "stub aws: unexpected $*" >&2; exit 2 ;;
esac
EOF
cat > "$T/driver.sh" <<'EOF'
#!/usr/bin/env bash
# Stub member driver. Behaviour per rank from $AK2T_STATE/behave-r<k>: LAUNCH_AFTER RUN_S EXIT.
trap '' INT
S=$AK2T_STATE; k=$AK2_COHORT_RANK
read -r LAUNCH_AFTER RUN_S EXIT < "$S/behave-r$k"
TASK="ak2-${1}-${AK2_COHORT_ID}-r$k"
# The foreground "spawn task run": sizing, then the launch.
bash -c "sleep $LAUNCH_AFTER; echo '$TASK running' > '$S/inst/i-$k'; echo 'launch i-$k' >> '$S/log'"
for ((t = 0; t < RUN_S * 2; t++)); do
  read -r _ st < "$S/inst/i-$k"; [ "$st" = terminated ] && exit "$EXIT"
  sleep 0.5
done
echo "$TASK terminated" > "$S/inst/i-$k"
exit "$EXIT"
EOF
cat > "$T/orphans.sh" <<'EOF'
#!/usr/bin/env bash
n=0; for i in "$AK2T_STATE"/inst/*; do [ -e "$i" ] || continue; read -r t st < "$i"; [ "$st" = terminated ] || { echo "alive $i"; n=1; }; done; exit $n
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/tag.sh"
chmod +x "$T/bin/aws" "$T/driver.sh" "$T/orphans.sh" "$T/tag.sh"

# A scratch repo holding run-multi.sh, ak2.env and a cohort spec.
R="$T/repo"; mkdir -p "$R/scripts" "$R/runs"
cp "$HERE/scripts/run-multi.sh" "$HERE/scripts/ak2.env" "$R/scripts/"
echo '{"env":{"AK2_REGION":"us-west-2"},"resources":{"instance_type":"c8g.large"},"placement":{"availability_zone":"us-west-2a"},"lifecycle":{"cost_limit":0.1}}' > "$R/runs/t.json"
( cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm t ) || { echo "run_multi_test: cannot make the scratch repo"; exit 1; }

# scenario NAME SIGNAL WHEN BEHAVE0 BEHAVE1 BEHAVE2 [setup]: run a 3-member cohort.
run_scenario() {
  local name=$1 sig=$2 when=$3 b0=$4 b1=$5 b2=$6 setup=${7:-}
  S="$T/state-$name"; mkdir -p "$S/inst"; : > "$S/log"; : > "$S/uploads"
  echo "$b0" > "$S/behave-r0"; echo "$b1" > "$S/behave-r1"; echo "$b2" > "$S/behave-r2"
  [ -n "$setup" ] && eval "$setup"
  # Job control on: a background job of a non-interactive shell would otherwise start with SIGINT
  # ignored (and bash cannot trap a signal ignored on entry); a terminal's Ctrl-C does reach it.
  set -m
  ( cd "$R" && PATH="$T/bin:$PATH" AK2T_STATE="$S" AK2_MULTI_RUN_SH="$T/driver.sh" AK2_MULTI_ORPHANS_SH="$T/orphans.sh" \
      AK2_MULTI_TAG_SH="$T/tag.sh" AK2_MULTI_POLL_S=1 exec scripts/run-multi.sh t runs/t.json 3 ) > "$S/out" 2>&1 &
  local pid=$!
  set +m
  if [ "$sig" != none ]; then sleep "$when"; kill -"$sig" "$pid"; fi
  wait "$pid"; RC=$?
  sleep 6  # any late launch would land in here
  ALIVE=$(for i in "$S"/inst/*; do [ -e "$i" ] || continue; read -r t st < "$i"; [ "$st" = terminated ] || basename "$i"; done | tr '\n' ' ')
  COHORT=$(ls -d "$R"/results/t/*/cohort.json 2>/dev/null | tail -1)
  CJ=$(cat "$COHORT" 2>/dev/null); rm -rf "$R/results"
}
expect() {  # name rc_want
  local name=$1 want=$2
  if [ "$RC" = "$want" ] && [ -z "${ALIVE// /}" ] && [ -n "$CJ" ]; then ok "$name: exit $RC, nothing alive, cohort.json written"
  else bad "$name: exit $RC (want $want), alive '${ALIVE}', cohort.json $([ -n "$CJ" ] && echo present || echo MISSING)"; tail -20 "$S/out"; fi
}

run_scenario term TERM 3 "4 30 0" "4 30 0" "4 30 0"
expect term 143
echo "$CJ" | jq -e '.ended | startswith("interrupted")' >/dev/null && ok "term: ended recorded as interrupted" || bad "term: ended $(echo "$CJ" | jq -c .ended)"
grep -q 'launch i-2' "$S/log" && bad "term: rank 2 launched after the cohort ended" || ok "term: the late launch never happened"

run_scenario int INT 3 "4 30 0" "4 30 0" "4 30 0"
expect int 130
grep -q 'launch i-2' "$S/log" && bad "int: rank 2 launched after the cohort ended" || ok "int: the late launch never happened"

run_scenario int-late INT 9 "1 30 0" "1 30 0" "1 30 0"
expect int-late 130
[ "$(echo "$CJ" | jq '.terminated_early | length')" -ge 3 ] && ok "int-late: all 3 launched instances terminated" || bad "int-late: terminated_early $(echo "$CJ" | jq -c .terminated_early)"

run_scenario normal none 0 "1 2 0" "1 2 0" "1 2 0"
expect normal 0
[ "$(echo "$CJ" | jq '.terminated_early | length')" = 0 ] && ok "normal: nothing terminated early" || bad "normal: terminated_early $(echo "$CJ" | jq -c .terminated_early)"

run_scenario failfast none 0 "1 60 0" "1 2 1" "12 60 0"
expect failfast 1
echo "$CJ" | jq -e '[.terminated_early[].rank] | (index(0) != null) and (index(2) != null)' >/dev/null &&
  ok "failfast: rank 0 and the late rank 2 terminated" || bad "failfast: terminated_early $(echo "$CJ" | jq -c .terminated_early)"

run_scenario describe none 0 "1 2 0" "1 2 0" "1 2 0" ': > "$S/fail-describe"'
# The members still end (their instances end themselves); the sweeps cannot see, so: exit 6.
expect describe 6
[ "$(echo "$CJ" | jq '.sweep_failures | length')" -gt 0 ] && ok "describe: sweep failures recorded" || bad "describe: sweep_failures $(echo "$CJ" | jq -c .sweep_failures)"

run_scenario uploads none 0 "1 2 0" "1 2 0" "1 2 0" 'printf "aws-kraken2/t/x/out/o.txt\tUPLOAD1\n" > "$S/uploads"'
expect uploads 0
grep -q 'abort aws-kraken2/t/x/out/o.txt UPLOAD1' "$S/log" && [ "$(echo "$CJ" | jq .multipart_aborted)" = 1 ] &&
  ok "uploads: the unfinished upload was aborted" || bad "uploads: log $(grep abort "$S/log"), multipart_aborted $(echo "$CJ" | jq .multipart_aborted)"

echo "run_multi_test: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
