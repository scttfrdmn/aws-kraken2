#!/usr/bin/env bash
# make rehearse-conductor (docs/conductor.md, "The rehearsal"): the conductor end to end on Amazon
# Linux 2023 containers (podman), no AWS. Each round runs exactly what run.sh launches for a
# runs/conductor*.json spec (scripts/lib/mkstub.sh's stub under `bash -e -c`, which fetches and
# execs scripts/preamble.sh + scripts/conductor.body.sh with a parameter block), with stand-ins only
# at the edges:
#   curl   IMDS (region, instance id, iam/info: the ak2-conductor profile, or spawn's when the round
#          says so), the bucket-region HEAD and the payload GET;
#   aws    s3 cp/sync into a shared directory (the "bucket"), sts (the assumed ak2-conductor role),
#          ec2 describe-tags (spawn:ttl-deadline), get-bucket-request-payment;
#   spawn, truffle, go   version stubs (the pinned versions); sudo runs the command;
#   the campaign's make run / make orphans / make g3-ladder / quota_check.sh   the AK2_CAMPAIGN_*
#          seams: the run stub writes a cohort dir as run-multi.sh does, finalised_by from the env.
# The repo is cloned from a bare copy of HEAD (commit first); upstream from the shared checkout.
# Rounds (each check on observed output):
#   full     COHORT=1 RUNGS=S2a,S5 REPS=1: the body exits 0, conductor.json ended with campaign rc 0,
#            both cohort dirs staged with changes.tsv; make harvest (AK2_HARVEST_SRC) installs them
#            into a scratch clone of the repo, prints the git add, and the tree then shows exactly that;
#            harvest again is a no-op that passes; a tampered staged file and a manifest without
#            finalised_by are each refused, nothing installed (negative controls);
#   drain    REPS=2, runs of 6 s: DRAIN written to the staging prefix once the first launch shows in
#            the staged campaign log: the campaign exits 4, the body 0, fewer than 4 launches, every
#            launched run finalised and staged; the harvest verifies;
#   early    DRAIN set before start: the body exits 0 without cloning (state drained-before-start);
#   plan     DRY_RUN=1 with the real make g3-ladder on the clone's record (python 3.9): the plan is
#            printed, exit 0, nothing staged under tree/;
#   norole   iam/info keeps spawn's profile: the body fails (exit 1) after AK2C_ROLE_WAIT tries,
#            conductor.json still staged and ended (negative control for the role wait);
#   launchfail (review B2) every launch fails at spawn task run (InsufficientInstanceCapacity), the
#            member manifest finalised as never launched, as run.sh now leaves it: the campaign
#            records capacity, retries in the documented AZ, stops the rung (exit 1) and appends its
#            g3_defects.tsv rows; every cohort dir and member is staged, harvest verifies, installs
#            them and applies the g3_defects.tsv patch;
#   transient (review B1) a launch whose run dir appears unfinalised and is then deleted, as run.sh
#            and run-multi.sh do on DRY_RUN and on refusals, while staging passes run: with the
#            filter, harvest verifies; with AK2C_STAGE_UNFILTERED=1 (the old staging) harvest refuses
#            "staged but not in changes.tsv" (the bug, reproduced as a negative control).
# Record: results/rehearse/conductor-<UTC>-<commit>.log (AK2T_REC overrides).
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
command -v podman >/dev/null || { echo "rehearse-conductor: need podman" >&2; exit 1; }
[ -z "$(git status --porcelain -- scripts runs Makefile)" ] || { echo "rehearse-conductor: commit scripts/ runs/ Makefile first (the container clones HEAD)" >&2; exit 1; }
PODMAN=(podman)
CONN=$(podman system connection list --format '{{.Name}}' 2>/dev/null | grep -- '-root$' | head -1)
[ -n "$CONN" ] && PODMAN=(podman --connection "$CONN")
BASE=public.ecr.aws/amazonlinux/amazonlinux:2023
IMG=localhost/ak2-conductor-rehearse:al2023
SHA=$(git rev-parse --short=7 HEAD)
REC=${AK2T_REC:-results/rehearse/conductor-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log}
mkdir -p "$(dirname "$REC")" || exit 1
exec > >(tee "$REC") 2>&1
echo "rehearse-conductor: at $SHA; shell flags $-; record $REC"
T=$(mktemp -d "$HOME/.ak2-conductor-rehearse.XXXXXX") || exit 1
cleanup() { "${PODMAN[@]}" rm -f $("${PODMAN[@]}" ps -aq --filter "name=ak2c-$$-") >/dev/null 2>&1
  [ "${KEEP:-0}" = 1 ] && echo "rehearse-conductor: kept $T" || rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/tools" "$T/bucket"
if ! "${PODMAN[@]}" image exists "$IMG"; then
  printf 'FROM %s\nRUN dnf install -y -q git jq make tar gzip findutils perl-Digest-SHA python3 util-linux-core procps-ng && dnf clean all\n' "$BASE" > "$T/Containerfile"
  "${PODMAN[@]}" build -q -t "$IMG" -f "$T/Containerfile" "$T" > /dev/null || { echo "rehearse-conductor: could not build $IMG" >&2; exit 1; }
fi
echo "rehearse-conductor: image $IMG ($("${PODMAN[@]}" image inspect --format '{{.Id}}' "$IMG" | cut -c1-12)), $([ -n "$CONN" ] && echo "rootful ($CONN)" || echo rootless)"
git clone -q --bare "$ROOT" "$T/origin.git" || exit 1
# The c1 record already holds every rung, so the campaign would skip them all: a scratch commit
# (in the scratch origin only, never pushed anywhere) drops the S2a and S5 c1 runs from the record.
git clone -q "$T/origin.git" "$T/src" || exit 1
DROP=$(cd "$T/src" && python3 -c '
import glob, json, os
for c in glob.glob("results/g3/*/cohort.json"):
    j = json.load(open(c)); p = j.get("params") or {}
    if p.get("cohort") == 1 and p.get("rung") in ("S2a", "S5"):
        d = os.path.dirname(c); print(d); [print(m) for m in glob.glob(d + "-r*")]')
[ -n "$DROP" ] || { echo "rehearse-conductor: no c1 S2a/S5 runs in the record to drop" >&2; exit 1; }
( cd "$T/src" && git rm -rq $DROP && git -c user.email=rehearse@aws-kraken2 -c user.name=rehearse-conductor \
    commit -qm "scratch: the record without c1 S2a and S5 (make rehearse-conductor; never pushed)" && git push -q origin HEAD ) ||
  { echo "rehearse-conductor: scratch commit failed" >&2; exit 1; }
SHA=$(git -C "$T/src" rev-parse --short=7 HEAD)
echo "rehearse-conductor: scratch commit $SHA drops $(echo "$DROP" | wc -l | tr -d ' ') run dir(s) of c1 S2a/S5 from the record"
# shellcheck source=/dev/null
. scripts/pin.env; . scripts/paths.sh
[ -d "$ORACLE_SRC/.git" ] || { echo "rehearse-conductor: no upstream checkout at $ORACLE_SRC (make oracle)" >&2; exit 1; }
git clone -q --bare "$ORACLE_SRC" "$T/upstream.git" || exit 1
RB=aws-kraken2-942542972736-us-west-2

# ---- stand-ins ----
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
out=""; url=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; case $a in http*) url=$a ;; esac; prev=$a; done
case $url in
  *169.254.169.254*/api/token) echo tok ;;
  *meta-data/placement/region) echo us-west-2 ;;
  *meta-data/placement/availability-zone) echo us-west-2a ;;
  *meta-data/instance-id) echo i-0c0nduct0r ;;
  *meta-data/instance-type) echo m8g.medium ;;
  *meta-data/ami-id) echo ami-test ;;
  *meta-data/iam/info) printf '{"InstanceProfileArn":"arn:aws:iam::942542972736:instance-profile/%s"}\n' "${AK2T_PROFILE:-ak2-conductor}" ;;
  https://*.s3.*amazonaws.com/) printf 'HTTP/1.1 200 OK\r\nx-amz-bucket-region: us-west-2\r\n\r\n' ;;
  https://*.s3.us-west-2.amazonaws.com/*) cp /work/payload.sh "$out" ;;
  *) exec /usr/bin/curl "$@" ;;
esac
EOF
cat > "$T/bin/aws" <<'EOF'
#!/bin/bash
# The bucket is /bucket/<bucket>/<key>. Options are dropped (with the value of those that take one).
pos=(); skip=0
for a in "$@"; do
  if [ $skip = 1 ]; then skip=0; continue; fi
  case $a in --region|--query|--output|--filters|--exclude|--include) skip=1 ;; --*) ;; *) pos+=("$a") ;; esac
done
loc() { case $1 in s3://*) echo "/bucket/${1#s3://}" ;; *) echo "$1" ;; esac; }
case "${pos[0]} ${pos[1]}" in
  "s3 cp") s=${pos[2]}; d=${pos[3]}
    if [ "$d" = - ]; then cat "$(loc "$s")" 2>/dev/null || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 1; }
    elif [ "$s" = - ]; then mkdir -p "$(dirname "$(loc "$d")")" && cat > "$(loc "$d")"
    else [ -e "$(loc "$s")" ] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 1; }
      mkdir -p "$(dirname "$(loc "$d")")" && cp "$(loc "$s")" "$(loc "$d")"; fi ;;
  "s3 sync") mkdir -p "$(loc "${pos[3]}")" && cp -R "$(loc "${pos[2]}")/." "$(loc "${pos[3]}")/" ;;
  "s3 rm") rm -f "$(loc "${pos[2]}")" ;;
  "s3api get-bucket-request-payment") echo BucketOwner ;;
  "sts get-caller-identity")
    if [ "${AK2T_PROFILE:-ak2-conductor}" = ak2-conductor ]; then echo "arn:aws:sts::942542972736:assumed-role/ak2-conductor/i-0c0nduct0r"
    else echo "arn:aws:sts::942542972736:assumed-role/spawn-instance-x/i-0c0nduct0r"; fi ;;
  "ec2 describe-tags") date -u -d "@$(( $(date +%s) + 86400 ))" +%Y-%m-%dT%H:%M:%SZ ;;
  *) [ "$1" = --version ] && { echo "aws-cli/stub"; exit 0; }; echo "aws stub: unhandled $*" >&2; exit 0 ;;
esac
EOF
printf '#!/bin/bash\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/bin/sudo"
# The pinned tools' stand-ins (AK2C_TOOLS_BIN): their own dir, which holds no aws, so putting it first
# on PATH (scripts/lib/tools_pin.sh) cannot bypass the preamble's shim.
printf '#!/bin/bash\necho "Version:    0.123.0"\n' > "$T/tools/spawn"
printf '#!/bin/bash\necho "Version:    0.57.1"\n' > "$T/tools/truffle"
chmod +x "$T/tools/"*
printf '#!/bin/bash\necho "go version go1.27.1 linux/arm64 (stub)"\n' > "$T/bin/go"
cat > "$T/bin/stub-run" <<'EOF'
#!/usr/bin/env python3
# make run GATE=g3 SPEC=... NODES=n, as run-multi.sh leaves it: a cohort dir and its finalised members.
import hashlib, json, os, random, subprocess, sys, time
a = dict(x.split("=", 1) for x in sys.argv[1:])
spec, n = a["SPEC"], int(a["NODES"])
sp = json.load(open(spec))
rep = os.environ.get("AK2_LADDER_REP", "1")
p = json.loads(subprocess.run(["python3", "scripts/lib/ladder_levers.py", "spec-params", spec, "--rep", rep], capture_output=True, text=True).stdout)
sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
if os.environ.get("AK2T_TRANSIENT"):
    # What run.sh / run-multi.sh leave for a moment and then delete (DRY_RUN, a cost or quota refusal):
    # an unfinalised run dir that lives across staging passes.
    td = "results/g3/%s-%s-dead-n1" % (time.strftime("%Y%m%d-%H%M%S", time.gmtime()), sha[:7])
    os.makedirs(td + "-r0")
    json.dump({"run_id": "x", "spec": spec}, open(td + "-r0/manifest.json", "w"))
    open(td + "-r0/spawn-plan.txt", "w").write("plan\n")
    time.sleep(float(os.environ["AK2T_TRANSIENT"]))
    import shutil
    shutil.rmtree(td + "-r0")
cid = "%s-%s-%04x-n%d" % (time.strftime("%Y%m%d-%H%M%S", time.gmtime()), sha[:7], random.randrange(65536), n)
print("make run (multi): cohort %s: %d x %s -> stub" % (cid, n, sp["resources"]["instance_type"]), flush=True)
fin = {"finalised_by": os.environ.get("AK2_FINALISED_BY"), "finalised_by_run_id": os.environ.get("AK2_CONDUCTOR_RUN_ID")}
fin = {k: v for k, v in fin.items() if v}
cd = "results/g3/" + cid
os.makedirs(cd)
spec_sha = hashlib.sha256(open(spec, "rb").read()).hexdigest()
if os.environ.get("AK2T_LAUNCHFAIL"):
    # run-multi.sh with a member whose spawn task run failed: run.sh finalised it as never launched.
    d = cd + "-r0"
    os.makedirs(d)
    open(d + "/spec.json", "wb").write(open(spec, "rb").read())
    open(d + "/launch.err", "w").write("launch task: InsufficientInstanceCapacity: no capacity\n")
    m = dict({"run_id": cid + "-r0", "spec": spec, "spec_sha256": spec_sha, "commit": sha, "params": p, "cohort": {"id": cid},
              "launch": {"error": "spawn task run failed; launch failed (rc=1)", "spawn_error": "InsufficientInstanceCapacity"},
              "instance": {"final_state": "never-launched", "final_state_basis": "no instance was launched"}, "task": None,
              "billed_seconds": 0, "cost_usd": 0, "orphan_check": {"mode": "own", "rc": 0, "own_gone": True},
              "manifest_finalised_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, **fin)
    json.dump(m, open(d + "/manifest.json", "w"))
    open(cd + "/rank-0.run.log", "w").write("make run: launch failed (rc=1)\nInsufficientInstanceCapacity\n")
    json.dump(dict({"cohort_id": cid, "spec": spec, "params": p, "nodes": n,
                    "members": [{"rank": 0, "run_id": cid + "-r0", "exit_code": None, "own_gone": True, "cost_usd": 0, "rc": "2"}],
                    "ended": "members done (fail fast: rank 0 exited 2)", "cost_usd": 0, "prefix_fetched": True, "sweep_failures": [],
                    "multipart_abort_failures": 0, "orphans_rc": 0, "orphans_scope": "own"}, **fin), open(cd + "/cohort.json", "w"))
    print("make run (multi): rank 0: run.sh exited 2: InsufficientInstanceCapacity", flush=True)
    sys.exit(2)
time.sleep(float(os.environ.get("AK2T_RUN_S", "2")))
mem = []
for k in range(n):
    d = "%s-r%d" % (cd, k)
    os.makedirs(d + "/tables")
    open(d + "/spec.json", "wb").write(open(spec, "rb").read())
    m = dict({"run_id": "%s-r%d" % (cid, k), "spec": spec, "spec_sha256": spec_sha, "commit": sha, "params": p, "cohort": {"id": cid},
              "instance": {"type": sp["resources"]["instance_type"], "az": sp["placement"]["availability_zone"]},
              "launch": {"instance_id": "i-%d" % k}, "task": {"exit_code": 0}, "orphan_check": {"own_gone": True}, "cost_usd": 0.5,
              "manifest_finalised_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, **fin)
    json.dump(m, open(d + "/manifest.json", "w"))
    b = open(d + "/manifest.json", "rb").read()
    json.dump({"commit": sha, "inputs": [{"path": d + "/manifest.json", "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()}]},
              open(d + "/tables/util.json", "w"))
    mem.append({"rank": k, "run_id": m["run_id"], "exit_code": 0, "own_gone": True, "cost_usd": 0.5})
json.dump(dict({"cohort_id": cid, "spec": spec, "params": p, "nodes": n, "members": mem, "ended": "members done", "cost_usd": 0.5 * n,
                "prefix_fetched": True, "sweep_failures": [], "multipart_abort_failures": 0, "orphans_rc": 0, "orphans_scope": "own"}, **fin),
          open(cd + "/cohort.json", "w"))
EOF
cat > "$T/bin/stub-g3" <<'EOF'
#!/usr/bin/env python3
import glob, os, re, sys
out = dict(x.split("=", 1) for x in sys.argv[1:] if "=" in x)["OUT"]
os.makedirs(out, exist_ok=True)
ids = [os.path.basename(d) for d in glob.glob("results/g3/2*") if re.match(r"^\d{8}-\d{6}-", os.path.basename(d)) and not re.search(r"-n\d+-r\d+$", d)]
with open(os.path.join(out, "runs.tsv"), "w") as f:
    f.write("run_id\tgate\tin_attribution\n" + "".join("%s\tg3\tyes\n" % i for i in ids))
print("ladder_tables: %d ladder run(s), 1 lever row(s), 0 DEFECT(s) -> %s/" % (len(ids), out), file=sys.stderr)
EOF
printf '#!/bin/bash\necho "orphans stub: none"\n' > "$T/bin/stub-orphans"
printf '#!/bin/bash\necho "quota_check: ok: stub" >&2\n' > "$T/bin/stub-quota"
chmod +x "$T/bin/"*
scripts/lib/mkstub.sh > "$T/stub.sh" || exit 1

RC=0
ok() { echo "rehearse-conductor: ok   $*"; }
bad() { echo "rehearse-conductor: FAIL $*"; RC=1; }
# round LABEL PARAMS [env...]: one conductor container; sets RUN, STG (the staging dir), CRC.
round() {
  local label=$1 params=$2; shift 2
  RUN="$(date -u +%Y%m%d-%H%M%S)-$SHA"
  # Run ids are to the second: a round must not inherit an earlier round's staging (its DRAIN).
  while [ -e "$T/bucket/$RB/aws-kraken2/results-staging/$RUN" ]; do sleep 1; RUN="$(date -u +%Y%m%d-%H%M%S)-$SHA"; done
  STG="$T/bucket/$RB/aws-kraken2/results-staging/$RUN"
  local P="s3://$RB/aws-kraken2/conductor/$RUN"
  awk -v p="$params" '$0 == "@PARAMS@" {print "# Conductor parameters (rehearsal):"; print p; next} {print}' scripts/conductor.body.sh > "$T/body.sh"
  { cat scripts/preamble.sh; printf '\n'; cat "$T/body.sh"; } > "$T/payload.sh"
  local PSHA; PSHA=$(shasum -a 256 "$T/payload.sh" | cut -d' ' -f1)
  [ -n "${PRE_DRAIN:-}" ] && { mkdir -p "$STG"; echo "drained_at=pre by=rehearsal reason=early" > "$STG/DRAIN"; }
  echo "rehearse-conductor: round $label: run $RUN; $params"
  "${PODMAN[@]}" run --rm --name "ak2c-$$-$label" -v "$T:/work:ro" -v "$T/bucket:/bucket" \
    -v "$T/origin.git:/origin.git:ro" -v "$T/upstream.git:/upstream.git:ro" \
    -e PATH=/work/bin:/usr/local/bin:/usr/bin:/bin -e HOME=/root \
    -e AK2_EXPECT_REGION=us-west-2 -e "AK2_BUCKETS=kraken2-ncbi-refseq-complete-v205 $RB" \
    -e "AK2_ALLOWED_BUCKETS=kraken2-ncbi-refseq-complete-v205 $RB" -e AK2_S3_PREFIX="$P" -e AK2_RUN_ID="$RUN" -e AK2_GATE=conductor \
    -e AK2_PAYLOAD_URI="$P/payload.sh" -e AK2_PAYLOAD_URL="https://$RB.s3.us-west-2.amazonaws.com/aws-kraken2/conductor/$RUN/payload.sh" \
    -e AK2_PAYLOAD_SHA256="$PSHA" -e AK2C_REHEARSE=1 -e AK2C_REPO_URL=/origin.git -e AK2C_UPSTREAM_URL=/upstream.git \
    -e AK2C_TOOLS_BIN=/work/tools -e DRAIN_POLL_S=1 -e STAGE_EVERY=2 -e AK2_CAMPAIGN_POLL_S=0.2 -e AK2_CAMPAIGN_SETTLE_S=5 \
    -e AK2_CAMPAIGN_ORPHANS=/work/bin/stub-orphans -e AK2_CAMPAIGN_QUOTA=/work/bin/stub-quota "$@" \
    "$IMG" bash -e -c "$(cat "$T/stub.sh")" > "$T/$label.out" 2>&1 &
  local pid=$!
  if [ -n "${DRAIN_AFTER_LAUNCH:-}" ]; then
    for _ in $(seq 1 600); do
      grep -q 'ladder-campaign: launch ' "$STG/campaign.log" 2>/dev/null && { echo "drained_at=mid by=rehearsal reason=mid-run" > "$STG/DRAIN"; break; }
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
  fi
  wait "$pid"; CRC=$?
  echo "rehearse-conductor: round $label: container exit $CRC"
  grep -E 'ak2: \[|ladder-campaign: (launch|DRAIN|exit|ended|summary)' "$T/$label.out" | tail -25 | sed "s/^/  $label | /"
}
cj() { jq -r "$1" "$STG/conductor.json" 2>/dev/null; }
SEAMS=(-e AK2_CAMPAIGN_RUN=/work/bin/stub-run -e AK2_CAMPAIGN_G3LADDER=/work/bin/stub-g3)
LAPTOP="$T/laptop"
git clone -q "$T/origin.git" "$LAPTOP" || exit 1
harvest() {  # harvest DIR: make harvest's script in the scratch laptop clone; HOUT, HRC
  HOUT=$(cd "$LAPTOP" && AK2_HARVEST_SRC="$1" bash scripts/harvest.sh "$RUN" 2>&1); HRC=$?
}

# ---- full ----
round full 'COHORT=1; RUNGS="S2a,S5"; REPS=1; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=0; TTL_S=7200' "${SEAMS[@]}"
NC=$(ls -d "$STG"/tree/results/g3/2*-n[0-9] 2>/dev/null | grep -cv -- '-r[0-9]*$')
[ "$CRC" = 0 ] && [ "$(cj .ended)" = true ] && [ "$(cj .campaign_rc)" = 0 ] && [ "$NC" = 2 ] && [ -s "$STG/changes.tsv" ] &&
  grep -q 'ak2: \[.*\] spec body exit rc=0' "$T/bucket/$RB/aws-kraken2/conductor/$RUN/log/run.log" &&
  ok "full: body exit 0 (in the streamed log/run.log), conductor.json ended, campaign rc 0, 2 cohort dirs staged with changes.tsv" ||
  bad "full: exit $CRC, ended $(cj .ended), campaign rc $(cj .campaign_rc), $NC cohort dir(s) staged"
grep -q "role: arn:aws:sts::942542972736:assumed-role/ak2-conductor" "$T/full.out" && grep -q 'deadline: TTL ends' "$T/full.out" &&
  ok "full: the body waited for the ak2-conductor role and set the campaign's deadline from spawn:ttl-deadline" || bad "full: role/deadline lines missing"
[ -s "$STG/campaign.log" ] && grep -q '^ladder-campaign: exit 0$' "$STG/campaign.log" && ok "full: the campaign log is staged" || bad "full: campaign.log not staged"
harvest "$STG"
ADD=$(echo "$HOUT" | sed -n 's/^  git add //p')
GOT=$(git -C "$LAPTOP" status --porcelain --untracked-files=normal | awk '{print $2}' | sed 's|/$||' | sort | tr '\n' ' ')
WANT=$(echo "$ADD" | tr ' ' '\n' | grep . | sort | tr '\n' ' ')
[ "$HRC" = 0 ] && [ -n "$ADD" ] && [ "$GOT" = "$WANT" ] && echo "$HOUT" | grep -q 'harvest: verified' &&
  ok "full: make harvest verified and installed it; git status shows exactly the printed git add ($(echo "$WANT" | wc -w | tr -d ' ') path(s))" ||
  bad "full: harvest rc $HRC; add '$WANT'; status '$GOT'; $(echo "$HOUT" | tail -5)"
harvest "$STG"
[ "$HRC" = 0 ] && ok "full: harvest again is a no-op that passes (identical files)" || bad "full: second harvest rc $HRC: $(echo "$HOUT" | tail -3)"
FULLSTG="$T/stage-full"; cp -R "$STG" "$FULLSTG"
git -C "$LAPTOP" clean -qfd results >/dev/null 2>&1
TM="$T/tamper"; cp -R "$FULLSTG" "$TM"
f=$(find "$TM/tree" -name cohort.json | head -1); printf ' ' >> "$f"
harvest "$TM"
[ "$HRC" = 1 ] && echo "$HOUT" | grep -q 'changes.tsv says' && [ -z "$(git -C "$LAPTOP" status --porcelain)" ] &&
  ok "full: a tampered staged file is refused, nothing installed (negative control)" || bad "full: tamper: harvest rc $HRC: $(echo "$HOUT" | tail -3)"
rm -rf "$TM"; cp -R "$FULLSTG" "$TM"
m=$(find "$TM/tree" -path '*-r0/manifest.json' | head -1)
jq -c 'del(.finalised_by)' "$m" > "$m.x" && mv "$m.x" "$m"
rel=${m#"$TM/tree/"}
awk -F'\t' -v p="$rel" -v s="$(shasum -a 256 "$m" | cut -d' ' -f1)" -v n="$(wc -c < "$m" | tr -d ' ')" 'BEGIN{OFS="\t"} $3==p {$1=s; $2=n} {print}' \
  "$TM/changes.tsv" > "$TM/c.x" && mv "$TM/c.x" "$TM/changes.tsv"
harvest "$TM"
[ "$HRC" = 1 ] && echo "$HOUT" | grep -q 'finalised_by None' && [ -z "$(git -C "$LAPTOP" status --porcelain)" ] &&
  ok "full: a manifest without finalised_by conductor is refused (negative control)" || bad "full: finalised_by: harvest rc $HRC: $(echo "$HOUT" | tail -3)"

# ---- drain ----
DRAIN_AFTER_LAUNCH=1 round drain 'COHORT=1; RUNGS="S2a,S5"; REPS=2; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=0; TTL_S=7200' \
  "${SEAMS[@]}" -e AK2T_RUN_S=6
NL=$(grep -c 'ladder-campaign: launch ' "$T/drain.out")
NC=$(ls -d "$STG"/tree/results/g3/2*-n[0-9] 2>/dev/null | grep -cv -- '-r[0-9]*$')
[ "$CRC" = 0 ] && [ "$(cj .campaign_rc)" = 4 ] && [ "$(cj .state)" = "campaign drained" ] && [ "$NL" -ge 1 ] && [ "$NL" -lt 4 ] && [ "$NC" = "$NL" ] &&
  grep -q 'drain: .*DRAIN found' "$T/drain.out" &&
  ok "drain: DRAIN in the staging prefix reached the campaign: exit 4, body 0, $NL of 4 launched, each staged" ||
  bad "drain: exit $CRC, campaign rc $(cj .campaign_rc), state '$(cj .state)', $NL launch(es), $NC staged"
harvest "$STG"
[ "$HRC" = 0 ] && ok "drain: the drained campaign harvests (every launched run finalised, the tsv consistent)" || bad "drain: harvest rc $HRC: $(echo "$HOUT" | grep FAIL | head -5)"
git -C "$LAPTOP" clean -qfd results >/dev/null 2>&1

# ---- early ----
PRE_DRAIN=1 round early 'COHORT=1; RUNGS="S2a"; REPS=1; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=0; TTL_S=7200' "${SEAMS[@]}"
[ "$CRC" = 0 ] && [ "$(cj .state)" = drained-before-start ] && ! grep -q 'ladder-campaign: launch' "$T/early.out" &&
  ok "early: a DRAIN set before start ends the body at once (exit 0, nothing launched)" || bad "early: exit $CRC state '$(cj .state)'"

# ---- plan ----
round plan 'COHORT=1; RUNGS=""; REPS=2; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=1; DRY_MAKE_RUN=0; TTL_S=7200'
[ "$CRC" = 0 ] && grep -q 'ladder-campaign: DRY_RUN=1: nothing launched' "$T/plan.out" && grep -q 'ladder-campaign: the record, ladder runs' "$T/plan.out" && ! grep -q 'refused: make g3-ladder' "$T/plan.out" &&
  grep -E '^[0-9]+ +[0-9]+ +(S2a|S5) .* launch$' "$T/plan.out" | grep -q . &&
  [ ! -d "$STG/tree" ] && [ "$(cj .campaign_rc)" = 0 ] &&
  ok "plan: DRY_RUN=1 with the real make g3-ladder on AL2023's python: judged, S2a/S5 planned, nothing staged under tree/" ||
  bad "plan: exit $CRC; $(grep -E 'ladder-campaign|Traceback|Error' "$T/plan.out" | tail -5)"

# ---- norole ----
round norole 'COHORT=1; RUNGS="S2a"; REPS=1; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=0; TTL_S=7200' "${SEAMS[@]}" \
  -e AK2T_PROFILE=spawn-instance-27cce928 -e AK2C_ROLE_WAIT=2
[ "$CRC" = 1 ] && [ "$(cj .ended)" = true ] && cj .state | grep -q 'never got the ak2-conductor role' &&
  ok "norole: without the ak2-conductor role the body fails (exit 1) and still stages conductor.json ended (negative control)" ||
  bad "norole: exit $CRC, ended $(cj .ended), state '$(cj .state)'"

# ---- launchfail (B2): every launch fails at spawn task run; the members are finalised non-runs
round launchfail 'COHORT=1; RUNGS="S5"; REPS=1; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=0; TTL_S=7200' "${SEAMS[@]}" \
  -e AK2T_LAUNCHFAIL=1
NC=$(ls -d "$STG"/tree/results/g3/2*-n[0-9] 2>/dev/null | grep -cv -- '-r[0-9]*$')
NM=$(ls "$STG"/tree/results/g3/2*-n[0-9]-r0/manifest.json 2>/dev/null | wc -l | tr -d ' ')
[ "$CRC" = 1 ] && [ "$(cj .campaign_rc)" = 1 ] && [ "$NC" -ge 1 ] && [ "$NM" = "$NC" ] && grep -q 'class capacity' "$T/launchfail.out" &&
  [ -s "$STG/tracked.patch" ] &&
  ok "launchfail: capacity recorded, the rung stopped (campaign exit 1), all $NC cohort dir(s) and their never-launched members staged, the g3_defects.tsv patch staged" ||
  bad "launchfail: exit $CRC, campaign rc $(cj .campaign_rc), $NC cohort dir(s), $NM member manifest(s), patch $(wc -c < "$STG/tracked.patch" 2>/dev/null)"
harvest "$STG"
[ "$HRC" = 0 ] && git -C "$LAPTOP" status --porcelain | grep -q ' M scripts/lib/g3_defects.tsv' && echo "$HOUT" | grep -q 'git add .*scripts/lib/g3_defects.tsv' &&
  ok "launchfail: harvest verifies the failed launches, installs them and applies the g3_defects.tsv rows" ||
  bad "launchfail: harvest rc $HRC: $(echo "$HOUT" | grep -E 'FAIL|git add' | head -4)"
git -C "$LAPTOP" checkout -q -- scripts/lib/g3_defects.tsv; git -C "$LAPTOP" clean -qfd results >/dev/null 2>&1

# ---- transient (B1): an unfinalised run dir that appears and is deleted between staging passes
round transient 'COHORT=1; RUNGS="S2a"; REPS=1; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=0; TTL_S=7200' "${SEAMS[@]}" \
  -e AK2T_TRANSIENT=5
harvest "$STG"
[ "$CRC" = 0 ] && [ "$HRC" = 0 ] && ! find "$STG/tree" -path '*-dead-n1*' | grep -q . &&
  ok "transient: a run dir deleted before finalisation never reaches the stage; harvest verifies" ||
  bad "transient: exit $CRC, harvest rc $HRC: $(echo "$HOUT" | grep FAIL | head -3)"
git -C "$LAPTOP" clean -qfd results >/dev/null 2>&1
round transient-old 'COHORT=1; RUNGS="S2a"; REPS=1; CONCURRENCY=1; FAMILY_LIMITS=""; DRY_RUN=; DRY_MAKE_RUN=0; TTL_S=7200' "${SEAMS[@]}" \
  -e AK2T_TRANSIENT=5 -e AK2C_STAGE_UNFILTERED=1
harvest "$STG"
[ "$HRC" = 1 ] && echo "$HOUT" | grep -q 'staged but not in changes.tsv: .*-dead-n1-r0/' && [ -z "$(git -C "$LAPTOP" status --porcelain)" ] &&
  ok "transient: with the old staging (AK2C_STAGE_UNFILTERED=1) harvest refuses: B1 reproduced (negative control)" ||
  bad "transient-old: harvest rc $HRC: $(echo "$HOUT" | grep FAIL | head -3)"
git -C "$LAPTOP" clean -qfd results >/dev/null 2>&1

# ---- the tracked patch (N1): only g3_defects.tsv, with its sha256
TM="$T/tamper-patch"; cp -R "$FULLSTG" "$TM"
printf 'diff --git a/Makefile b/Makefile\n' >> "$TM/tracked.patch"
harvest "$TM"
[ "$HRC" = 1 ] && echo "$HOUT" | grep -q 'tracked.patch sha256' && ok "patch: a tracked.patch that is not its recorded sha256 is refused" ||
  bad "patch: sha: harvest rc $HRC: $(echo "$HOUT" | grep FAIL | head -3)"
shasum -a 256 "$TM/tracked.patch" | cut -d' ' -f1 > "$TM/tracked.patch.sha256"
harvest "$TM"
[ "$HRC" = 1 ] && echo "$HOUT" | grep -q 'only scripts/lib/g3_defects.tsv may change' && ok "patch: a patch touching another tracked file is refused" ||
  bad "patch: scope: harvest rc $HRC: $(echo "$HOUT" | grep FAIL | head -3)"

echo "rehearse-conductor: $([ $RC = 0 ] && echo PASS || echo FAIL) (record $REC)"
exit $RC
