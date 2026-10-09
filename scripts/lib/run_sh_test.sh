#!/usr/bin/env bash
# make test: scripts/run.sh's pre-launch refusals, on the real run.sh in a scratch repo (a copy of
# scripts/ and the recorded cohort's runs.tsv), with stubbed spawn, truffle, aws and curl and a
# stubbed pin identity (no AWS, no upstream checkout). Each case runs run.sh until it refuses;
# a case that must pass a check is run until a later, known stop (the stub refuses
# `aws s3 presign`: "could not presign"), which run.sh reaches only after the checks under test.
#   cohort sha   AK2_COHORT_ID naming another commit than HEAD is refused; HEAD's sha7 passes;
#   reference    an @-reference with a body that never calls accessions.sh is refused; with one,
#                it passes.
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
printf '#!/usr/bin/env bash\ncase "$1" in version) echo "Version: 0.0.0" ;; *) echo "[]" ;; esac\n' > "$T/bin/truffle"
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
( cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm t ) || { echo "run_sh_test: cannot make the scratch repo"; exit 1; }
HEAD7=$(git -C "$R" rev-parse --short=7 HEAD)
OTHER7=$(printf '%07x' $(( (16#$HEAD7 + 1) % 268435456 )))

# run NAME SPEC [COHORT_ID]: run.sh in the scratch repo; OUT and RC.
run() {
  local spec=$2 cid=${3:-}  # $1: the case name, for the reader
  if [ -n "$cid" ]; then
    OUT=$(cd "$R" && PATH="$T/bin:$PATH" K2_SHARED_ROOT="$R" AK2_COHORT_ID="$cid" AK2_COHORT_RANK=0 AK2_COHORT_N=2 \
      scripts/run.sh t "runs/$spec" 2>&1)
  else
    OUT=$(cd "$R" && PATH="$T/bin:$PATH" K2_SHARED_ROOT="$R" scripts/run.sh t "runs/$spec" 2>&1)
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

echo "run_sh_test: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
