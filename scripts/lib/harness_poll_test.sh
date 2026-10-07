#!/usr/bin/env bash
# make test: scripts/run.sh's aws_try classification and scripts/refinalise.sh, against a stubbed
# `aws` on PATH (no AWS access). Checks that only s3 404/NoSuchKey and ec2
# InvalidInstanceID.NotFound / a None query count as "absent", that a generic ec2 404 is a
# failed call, and that refinalise refuses a second repair, appends with --force, treats an
# empty final_state as unset, and states the right cost_basis.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FAIL=0
ok() { echo "harness_poll_test: ok   $*"; }
bad() { echo "harness_poll_test: FAIL $*"; FAIL=1; }

# ---- the stub: behaviour from STUB_EC2 / STUB_S3 / STUB_PREFIX_DIR ----
mkdir -p "$T/bin"
cat > "$T/bin/aws" <<'STUB'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *" ec2 describe-regions "*) echo us-west-2; exit 0 ;;
  *" ec2 describe-instances "*"--filters"*) echo '{"Reservations":[]}'; exit 0 ;;
  *" ec2 describe-instances "*)
    case "${STUB_EC2:-}" in
      notfound) echo "An error occurred (InvalidInstanceID.NotFound) when calling the DescribeInstances operation: The instance ID 'i-1' does not exist" >&2; exit 254 ;;
      none) echo None; exit 0 ;;
      404) echo "An error occurred (404) when calling the DescribeInstances operation: Not Found" >&2; exit 254 ;;
      running) echo '{"ImageId":"ami-1","State":{"Name":"running"},"StateTransitionReason":""}'; exit 0 ;;
      down) echo "Could not connect to the endpoint URL: \"https://ec2.us-west-2.amazonaws.com/\"" >&2; exit 255 ;;
      terminated) case "$args" in *State.Name*) echo terminated ;; *)
          echo '{"ImageId":"ami-1","Placement":{"AvailabilityZone":"us-west-2b"},"LaunchTime":"2026-10-07T01:00:00+00:00","Architecture":"arm64","State":{"Name":"terminated"},"StateTransitionReason":"User initiated (2026-10-07 02:00:00 GMT)"}' ;; esac; exit 0 ;;
    esac ;;
  *" s3api list-objects-v2 "*) echo '[]'; exit 0 ;;
  *" s3 cp "*"--recursive"*)
    dst=${*: -1}; cp -R "$STUB_PREFIX_DIR/." "$dst/"; exit 0 ;;
  *" s3 cp "*)
    case "${STUB_S3:-}" in
      missing) echo "fatal error: An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 1 ;;
      down) echo "fatal error: Could not connect to the endpoint URL: \"https://b.s3.us-west-2.amazonaws.com/k\"" >&2; exit 1 ;;
      present) echo '{}' > "${*: -1}"; exit 0 ;;
    esac ;;
esac
echo "stub aws: unhandled: $*" >&2; exit 99
STUB
chmod +x "$T/bin/aws"
export PATH="$T/bin:$PATH"

# ---- aws_try, taken verbatim from run.sh ----
sed -n '/^AWS_TO=/,/^poll_sleep()/p' "$ROOT/scripts/run.sh" > "$T/aws_try.sh"
grep -q '^aws_try()' "$T/aws_try.sh" || { echo "harness_poll_test: cannot extract aws_try from run.sh"; exit 1; }
say() { echo "  (say) $*" >/dev/null; }
# shellcheck source=/dev/null
. "$T/aws_try.sh"
expect() {  # expect WANT_RC LABEL ARGS...
  local want=$1 label=$2 got; shift 2
  aws_try OUT "$@"; got=$?
  [ "$got" = "$want" ] && ok "$label -> $got" || bad "$label -> $got (want $want; err: $AWS_TRY_ERR)"
}
STUB_EC2=notfound expect 1 "ec2 InvalidInstanceID.NotFound is absent" ec2 describe-instances --instance-ids i-1 --query x --output text
STUB_EC2=none expect 1 "ec2 query printing None is absent" ec2 describe-instances --instance-ids i-1 --query x --output text
STUB_EC2=404 expect 2 "ec2 generic (404) is a failed call, not gone" ec2 describe-instances --instance-ids i-1 --query x --output text
STUB_EC2=down expect 2 "ec2 unreachable is a failed call" ec2 describe-instances --instance-ids i-1 --query x --output text
STUB_EC2=terminated expect 0 "ec2 terminated is observed" ec2 describe-instances --instance-ids i-1 --query State.Name --output text
STUB_S3=missing expect 1 "s3 404 is absent" s3 cp s3://b/k "$T/x"
STUB_S3=down expect 2 "s3 unreachable is a failed call" s3 cp s3://b/k "$T/x"
STUB_S3=present expect 0 "s3 present" s3 cp s3://b/k "$T/x"

# ---- run.sh's final_describe: an answer always sets STATE and FINAL_BASIS=observed ----
LREGION=us-west-2 IID=i-1 FD_BACKOFF_S=0
STATE=terminated FINAL_BASIS=aged_out; STUB_EC2=running final_describe; rc=$?
[ "$rc" = 0 ] && [ "$STATE" = running ] && [ "$FINAL_BASIS" = observed ] &&
  ok "final describe answering running replaces an inferred terminated/aged_out" || bad "final_describe running: rc $rc STATE=$STATE BASIS=$FINAL_BASIS"
STATE=terminated FINAL_BASIS=aged_out; STUB_EC2=notfound final_describe; rc=$?
[ "$rc" = 1 ] && [ "$STATE" = terminated ] && [ "$FINAL_BASIS" = aged_out ] && [ -z "$FDESC" ] &&
  ok "final describe not found keeps aged_out" || bad "final_describe notfound: rc $rc STATE=$STATE BASIS=$FINAL_BASIS"
STATE="" FINAL_BASIS=""; STUB_EC2=terminated final_describe; rc=$?
[ "$rc" = 0 ] && [ "$STATE" = terminated ] && [ "$FINAL_BASIS" = observed ] && ok "final describe terminated is observed" || bad "final_describe terminated"
STATE="" FINAL_BASIS=""; STUB_EC2=down final_describe; rc=$?
[ "$rc" = 2 ] && [ -z "$STATE" ] && [ -z "$FINAL_BASIS" ] && ok "final describe failing leaves the state unknown" || bad "final_describe down: rc $rc"

# ---- run.sh's note_state: a failed describe clears the basis ----
DESC='{}'
STATE=running FINAL_BASIS=observed; STUB_EC2=down aws_try STATE ec2 describe-instances --instance-ids i-1 --query State.Name --output text; note_state $?
[ -z "$STATE" ] && [ -z "$FINAL_BASIS" ] && ok "failed poll describe: STATE and FINAL_BASIS both unknown (no stale observed)" || bad "note_state 2: STATE=$STATE BASIS=$FINAL_BASIS"
STUB_EC2=terminated aws_try STATE ec2 describe-instances --instance-ids i-1 --query State.Name --output text; note_state $?
[ "$STATE" = terminated ] && [ "$FINAL_BASIS" = observed ] && ok "poll describe answering terminated is observed" || bad "note_state 0: STATE=$STATE BASIS=$FINAL_BASIS"
STUB_EC2=notfound aws_try STATE ec2 describe-instances --instance-ids i-1 --query State.Name --output text; note_state $?
[ "$STATE" = terminated ] && [ "$FINAL_BASIS" = aged_out ] && ok "poll describe not found after launch: aged out" || bad "note_state 1: STATE=$STATE BASIS=$FINAL_BASIS"
DESC=''
STATE=running FINAL_BASIS=observed; STUB_EC2=notfound aws_try STATE ec2 describe-instances --instance-ids i-1 --query State.Name --output text; note_state $?
[ -z "$STATE" ] && [ -z "$FINAL_BASIS" ] && ok "poll describe not found before launch was seen: unknown (no stale observed)" || bad "note_state 1 without DESC: STATE=$STATE BASIS=$FINAL_BASIS"

# ---- refinalise.sh on a fixture run dir ----
fixture() {  # fixture DIR FINAL_STATE [BASIS]: a manifest as a TTL-killed / outage run leaves it
  mkdir -p "$1" "$T/prefix/spawn/ak2-g9-x/log" "$T/prefix/log" "$T/prefix/out"
  printf '{"exit_code":0,"ended_at":"2026-10-07T01:50:00Z"}\n' > "$T/prefix/spawn/ak2-g9-x/completion.json"
  printf 'ak2-phase\t2026-10-07T01:01:00Z\t1791334860\tsetup\tno\nak2-phase\t2026-10-07T01:49:00Z\t1791337740\tend\tno\n' > "$T/prefix/log/run.log"
  printf 'phase\top\tcount\tbucket\nsetup\tGetObject\t3\tb\n' > "$T/prefix/out/requests.tsv"
  jq -n --arg fs "$2" --arg fb "${3:-}" '{task_id:"ak2-g9-x", s3_prefix:"s3://cookbook-942542972736-us-west-2/aws-kraken2/g9/x",
    launch:{instance_id:"i-1", region:"us-west-2"}, truffle_price_usd_per_hour:3.6,
    instance:{type:"t", count:1, ami:"ami-1", az:"us-west-2b", launch_time:"2026-10-07T01:00:00+00:00",
              architecture:"arm64", lifecycle:"on-demand", final_state:$fs}}
    | if $fb != "" then .instance.final_state_basis = $fb else . end' > "$1/manifest.json"
}
R="$T/run"; fixture "$R" ""
export STUB_PREFIX_DIR="$T/prefix"
STUB_EC2=none "$ROOT/scripts/refinalise.sh" "$R" > "$T/out1" 2>&1 || bad "refinalise (aged out) failed: $(cat "$T/out1")"
M="$R/manifest.json"
[ "$(jq -r .instance.final_state "$M")" = terminated ] && [ "$(jq -r .instance.final_state_basis "$M")" = aged_out ] &&
  ok "empty final_state treated as unset; aged out -> terminated/aged_out" || bad "final_state $(jq -c .instance "$M")"
[ "$(jq -r .stop_basis "$M")" = "completion ended_at" ] && [ "$(jq -r .billed_seconds "$M")" = 3000 ] &&
  ok "stop from the completion record (3000 s)" || bad "stop $(jq -c '{stop,stop_basis,billed_seconds}' "$M")"
jq -r .cost_basis "$M" | grep -q 'completion ended_at - launch_time' && jq -r .cost_basis "$M" | grep -q undercounts &&
  ok "cost_basis names the completion ended_at" || bad "cost_basis: $(jq -r .cost_basis "$M")"
[ "$(jq -r .manifest_repair.object_tags.ok "$M")" = true ] && ok "tag result under the repair record" || bad "repair tags $(jq -c .manifest_repair.object_tags "$M")"
[ "$(jq -r .task.exit_code "$M")" = 0 ] && [ "$(jq -r .requests.total "$M")" = 3 ] && ok "task and requests filled" || bad "task/requests"
[ "$(jq -r .orphan_check.own_gone "$M")" = true ] && [ -s "$R/orphans.txt" ] && ok "orphan check recorded" || bad "orphan_check $(jq -c .orphan_check "$M")"
cp "$M" "$T/m1"
STUB_EC2=none "$ROOT/scripts/refinalise.sh" "$R" > "$T/out2" 2>&1 && bad "second repair was not refused" ||
  { cmp -s "$M" "$T/m1" && ok "second repair refused, manifest untouched" || bad "refused but manifest changed"; }
STUB_EC2=404 "$ROOT/scripts/refinalise.sh" --force "$R" > "$T/out3" 2>&1 || bad "--force failed: $(cat "$T/out3")"
[ "$(jq '.manifest_repairs | length' "$M")" = 1 ] && [ "$(jq -r .manifest_repair.at "$M")" = "$(jq -r .manifest_repair.at "$T/m1")" ] &&
  ok "--force appends to .manifest_repairs[], first repair kept" || bad "repairs $(jq -c '{manifest_repair,manifest_repairs}' "$M")"
jq -r '.manifest_repairs[0].gaps[]' "$M" | grep -q 'describe-instances failed' && [ "$(jq -r .instance.final_state_basis "$M")" = aged_out ] &&
  ok "a generic ec2 404 under --force is a gap, not a state; set fields kept" || bad "forced 404: $(jq -c '.manifest_repairs[0]' "$M")"
[ "$(jq -r .stop_basis "$M")" = "completion ended_at" ] && [ "$(jq -r .cost_basis "$M")" = "$(jq -r .cost_basis "$T/m1")" ] &&
  ok "--force does not overwrite stop_basis or cost_basis" || bad "forced overwrite"

R2="$T/run2"; fixture "$R2" ""
STUB_EC2=terminated "$ROOT/scripts/refinalise.sh" "$R2" > "$T/out4" 2>&1 || bad "refinalise (observed) failed: $(cat "$T/out4")"
M2="$R2/manifest.json"
[ "$(jq -r .instance.final_state_basis "$M2")" = observed ] && [ "$(jq -r .stop_basis "$M2")" = terminated_at ] &&
  [ "$(jq -r .billed_seconds "$M2")" = 3600 ] && jq -r .cost_basis "$M2" | grep -q '(terminated_at - launch_time)' &&
  ok "observed termination: terminated_at stop, 3600 s, terminated_at cost_basis" || bad "observed: $(jq -c '{instance,stop_basis,billed_seconds,cost_basis}' "$M2")"

R3="$T/run3"; fixture "$R3" running unknown
STUB_EC2=none "$ROOT/scripts/refinalise.sh" "$R3" > "$T/out5" 2>&1 || bad "refinalise (basis unknown) failed: $(cat "$T/out5")"
[ "$(jq -r .instance.final_state "$R3/manifest.json")" = terminated ] && [ "$(jq -r .instance.final_state_basis "$R3/manifest.json")" = aged_out ] &&
  ok "final_state with basis unknown counts as unset (filled: terminated/aged_out)" || bad "basis unknown: $(jq -c .instance "$R3/manifest.json")"

[ "$FAIL" = 0 ] && echo "harness_poll_test: all passed" || { echo "harness_poll_test: FAILED"; exit 1; }
