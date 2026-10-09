#!/usr/bin/env bash
# make test: scripts/lib/quota_check.sh against a stubbed `aws` on PATH (no AWS access), and
# scripts/lib/accessions.sh on the recorded cohort. The stub's X quota is us-west-2's applied
# L-7295265B, 128 vCPU (x8g.24xlarge = 96 vCPU): one is allowed, two are refused.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/quota-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAILN=0; PASS=0
ok() { echo "quota_check_test: ok   $*"; PASS=$((PASS + 1)); }
bad() { echo "quota_check_test: FAIL $*"; FAILN=$((FAILN + 1)); }

mkdir -p "$T/bin"
cat > "$T/bin/aws" <<'STUB'
#!/usr/bin/env bash
# Live instances: $QT_LIVE, lines "<type> <lifecycle>". Every call is logged to $QT_LOG.
echo "$*" >> "$QT_LOG"
case "$1 $2" in
  "ec2 describe-instances") [ -n "${QT_LIVE:-}" ] && printf '%s\n' "$QT_LIVE"; exit 0 ;;
  "ec2 describe-instance-types")
    shift 2
    while [ $# -gt 0 ]; do [ "$1" = --instance-types ] && break; shift; done; shift
    while [ $# -gt 0 ] && [[ $1 != --* ]]; do
      case $1 in x8g.24xlarge) printf '%s\t96\n' "$1" ;; x8g.12xlarge) printf '%s\t48\n' "$1" ;;
        r8gd.48xlarge) printf '%s\t192\n' "$1" ;; c8g.large) printf '%s\t2\n' "$1" ;; esac; shift
    done ;;
  "service-quotas get-service-quota")
    [ -n "${QT_QUOTA_FAIL:-}" ] && { echo "An error occurred (AccessDeniedException)" >&2; exit 254; }
    case " $* " in *" L-7295265B "*) echo 128.0 ;; *" L-1216C47A "*) echo 1989.0 ;; *) echo "stub: no quota" >&2; exit 254 ;; esac ;;
  *) echo "stub aws: unexpected $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$T/bin/aws"
QC="$ROOT/scripts/lib/quota_check.sh"

# check NAME WANT_RC TYPE COUNT [LIVE]
check() {
  local name=$1 want=$2 type=$3 count=$4 live=${5:-} out rc
  : > "$T/log"
  out=$(PATH="$T/bin:$PATH" QT_LOG="$T/log" QT_LIVE="$live" "$QC" us-west-2 "$type" "$count" 2> "$T/err"); rc=$?
  if [ "$rc" = "$want" ]; then ok "$name: exit $rc ($(cut -c1-160 "$T/err"))"
  else bad "$name: exit $rc, want $want: $(cat "$T/err")"; fi
  if grep -vE '^(ec2 describe-instances|ec2 describe-instance-types|service-quotas get-service-quota) ' "$T/log" | grep -q .; then
    bad "$name: a call that is not read-only: $(cat "$T/log")"
  fi
  LAST=$out
}

check "1 x x8g.24xlarge" 0 x8g.24xlarge 1
[ "$(echo "$LAST" | jq -c '[.quota_code, .quota_vcpus, .requested_vcpus, .within_quota]')" = '["L-7295265B",128,96,true]' ] &&
  ok "1 x x8g.24xlarge: record $LAST" || bad "1 x x8g.24xlarge: record '$LAST'"
check "2 x x8g.24xlarge" 1 x8g.24xlarge 2
[ "$(echo "$LAST" | jq -c '[.total_vcpus, .within_quota]')" = '[192,false]' ] && ok "2 x x8g.24xlarge: total 192, refused" ||
  bad "2 x x8g.24xlarge: record '$LAST'"
grep -q REFUSED "$T/err" && grep -q L-7295265B "$T/err" && ok "2 x x8g.24xlarge: the message names the refusal and the quota" ||
  bad "2 x x8g.24xlarge: message $(cat "$T/err")"
check "1 x x8g.24xlarge with one already running" 1 x8g.24xlarge 1 $'x8g.24xlarge\tNone'
check "1 x x8g.24xlarge with x8g.12xlarge running (144 > 128)" 1 x8g.24xlarge 1 $'x8g.12xlarge\tNone'
check "1 x x8g.24xlarge with a spot x8g.24xlarge running (not counted)" 0 x8g.24xlarge 1 $'x8g.24xlarge\tspot'
check "1 x x8g.24xlarge with r8gd.48xlarge running (another family)" 0 x8g.24xlarge 1 $'r8gd.48xlarge\tNone'
check "2 x r8gd.48xlarge (Standard family)" 0 r8gd.48xlarge 2
check "unknown family" 2 mac2.metal 1
check "bad count" 2 x8g.24xlarge 0
: > "$T/log"
PATH="$T/bin:$PATH" QT_LOG="$T/log" QT_QUOTA_FAIL=1 "$QC" us-west-2 x8g.24xlarge 1 >/dev/null 2>&1
[ $? = 2 ] && ok "service-quotas failure: exit 2 (refuse)" || bad "service-quotas failure: not exit 2"

# accessions.sh on the recorded cohort: the reference expands to the same list mkspec.sh used to inline.
A=$("$ROOT/scripts/lib/accessions.sh" @PRJNA398089:1-1000)
B=$(awk -F'\t' 'NR>1 && $1<=1000 {printf "%s%s", (NR>2?" ":""), $2}' "$ROOT/results/cohort/PRJNA398089/runs.tsv")
[ -n "$A" ] && [ "$A" = "$B" ] && ok "accessions: @PRJNA398089:1-1000 = runs.tsv ranks 1-1000" || bad "accessions: 1-1000 differs"
[ "$("$ROOT/scripts/lib/accessions.sh" @PRJNA398089:2-3)" = "SRR5935741 SRR5935742" ] && ok "accessions: @PRJNA398089:2-3" ||
  bad "accessions: 2-3 is '$("$ROOT/scripts/lib/accessions.sh" @PRJNA398089:2-3)'"
[ "$("$ROOT/scripts/lib/accessions.sh" "  SRR1  ERR2 ")" = "SRR1 ERR2" ] && ok "accessions: a literal list passes through" || bad "accessions: literal list"
for v in @PRJNA398089:1-1001 @PRJNA398089:3-2 @PRJNA398089:0-2 @NOSUCH:1-2 '@PRJNA398089:1-2 SRR1'; do
  "$ROOT/scripts/lib/accessions.sh" "$v" >/dev/null 2>&1
  [ $? = 2 ] && ok "accessions: '$v' refused" || bad "accessions: '$v' not refused"
done

echo "quota_check_test: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
