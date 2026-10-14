#!/usr/bin/env bash
# scripts/orphans.sh and the conductor (docs/conductor.md, "Orphans and quota"; in make test), with
# a stub aws on PATH: a conductor within its TTL is named CONDUCTOR and not counted, globally and in a
# member's scoped check; past its TTL + 15 min, or with no deadline, it counts; any other ak2
# instance still counts.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *describe-regions*) echo "us-west-2" ;;
  *describe-instances*) cat "$AK2T_INSTANCES" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/bin/aws"
iso() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + int(sys.argv[1]))))' "$1"; }
inst() {  # id task deadline-offset-seconds (or "none")
  local dl=""
  [ "$3" = none ] || dl='"Value":"'"$(iso "$3")"'"'
  printf '{"InstanceId":"%s","State":{"Name":"running"},"InstanceType":"m8g.medium","LaunchTime":"2026-10-14T00:00:00Z","Tags":[{"Key":"spawn:task-id","Value":"%s"},{"Key":"ak2:project","Value":"aws-kraken2"}%s]}' \
    "$1" "$2" "$([ -n "$dl" ] && echo ',{"Key":"spawn:ttl-deadline",'"$dl"'}')"
}
world() { printf '{"Reservations":[{"Instances":[%s]}]}\n' "$(IFS=,; echo "$*")" > "$T/inst.json"; }
PASS=0; FAIL=0
check() {  # name want_rc needle -- args
  local name=$1 want=$2 needle=$3; shift 4
  local out rc
  out=$(PATH="$T/bin:$PATH" AK2T_INSTANCES="$T/inst.json" AWS_PROFILE=x bash "$ROOT/scripts/orphans.sh" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want" ] && grep -q -- "$needle" <<< "$out"; then PASS=$((PASS + 1)); echo "orphans_conductor_test: ok   $name"
  else FAIL=$((FAIL + 1)); echo "orphans_conductor_test: FAIL $name (rc $rc, want $want; want '$needle')"; sed 's/^/  | /' <<< "$out"; fi
}
C=ak2-conductor-20261014-120000-abcdef0
M=ak2-g3-20261014-120500-abcdef0-1a2b-n1-r0
world "$(inst i-c "$C" 3600)"
check "global: a conductor within its TTL is named and not counted" 0 "CONDUCTOR (gate conductor" --
check "global: ... and the summary says so" 0 "1 conductor(s) running within TTL" --
world "$(inst i-c "$C" -3600)"
check "global: a conductor past its TTL + 15 min counts (PROBABLE ORPHAN)" 1 "PROBABLE ORPHAN" --
world "$(inst i-c "$C" none)"
check "global: a conductor with no deadline counts" 1 "still alive" --
world "$(inst i-c "$C" 3600)" "$(inst i-m "$M" 3600)"
check "global: another ak2 instance still counts with a conductor alive" 1 "still alive" --
world "$(inst i-c "$C" 3600)" "$(inst i-m "$M" 3600)"
AK2_ORPHANS_JSON="$T/own.json" check "scoped: a member whose own instance is alive fails" 1 "THIS run's instance" -- --own "$M" i-m
world "$(inst i-c "$C" 3600)"
AK2_ORPHANS_JSON="$T/own.json" check "scoped: a member's check with only the conductor alive passes" 0 "are gone" -- --own "$M" i-m
if [ "$(jq -r '.others[0].flag' "$T/own.json" 2>/dev/null)" = conductor ] && [ "$(jq -r .own_gone "$T/own.json")" = true ]; then
  PASS=$((PASS + 1)); echo "orphans_conductor_test: ok   scoped: the manifest's orphan_check flags it conductor"
else FAIL=$((FAIL + 1)); echo "orphans_conductor_test: FAIL scoped: orphan_check JSON: $(cat "$T/own.json" 2>/dev/null)"; fi
echo "orphans_conductor_test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
