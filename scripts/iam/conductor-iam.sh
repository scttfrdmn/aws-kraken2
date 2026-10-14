#!/usr/bin/env bash
# make conductor-iam (docs/conductor.md, "IAM"): create or update, idempotently, the conductor's IAM
# from the committed documents in scripts/iam/, then verify it by simulation and record it in
# results/iam/conductor-<UTC ts>.json. Run on the laptop (AWS_PROFILE=aws), never on an instance.
#
#   1. scripts/iam/conductor_policy_check.py check (offline: the documents against the committed specs);
#   2. managed policy ak2-spawn-instance-boundary <- spawn-instance-boundary.json (a new default
#      version when the document changed; the oldest non-default version is deleted at 5);
#   3. role ak2-conductor <- conductor-trust.json, inline policy ak2-conductor-policy <-
#      conductor-policy.json;
#   4. instance profile ak2-conductor holding the role;
#   5. the boundary on each run role (spawn-instance-<hash>) the ladder specs launch under. The
#      conductor may refresh that role's policies (spawn task run does it on every launch) only while
#      the boundary is attached, so the conductor cannot widen what it passes to an instance. The
#      boundary covers everything spawn attaches (checked live here, against the role's actual
#      policies), so attaching it changes nothing a run can do; still, it is attached only when no
#      instance is using the role: otherwise this step is reported PENDING and the conductor cannot
#      launch rungs until make conductor-iam is run again with nothing in flight;
#   6. tags project=aws-kraken2 on the policy, role and profile;
#   7. scripts/iam/conductor-iam-verify.sh: the role's policies through the IAM policy simulator,
#      each expected allow with its negative control.
# Exit 0: all done and verified; 3: done except the boundary (PENDING); 1: a verification failed;
# 2: refused or an AWS call failed.
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
echo "conductor-iam: shell flags $-" >&2
# shellcheck source=/dev/null
. scripts/ak2.env
export AWS_PROFILE
die() { echo "conductor-iam: $*" >&2; exit 2; }
say() { echo "conductor-iam: $*" >&2; }
[ "${AK2_INSTANCE_ROLE:-}" != 1 ] || die "run this on the laptop (it creates IAM), not on an instance"
for t in aws jq python3 git; do command -v "$t" >/dev/null || die "$t not on PATH"; done
python3 scripts/iam/conductor_policy_check.py check >&2 || die "the committed documents are inconsistent (above)"
ACCT=$(aws sts get-caller-identity --query Account --output text) || die "sts get-caller-identity failed"
[ "$ACCT" = "$AK2_ACCOUNT" ] || die "credentials are for account $ACCT, not $AK2_ACCOUNT"
WHO=$(aws sts get-caller-identity --query Arn --output text)
ROLE=$AK2_CONDUCTOR_ROLE; PROFILE=$AK2_CONDUCTOR_PROFILE; BNAME=ak2-spawn-instance-boundary
BARN="arn:aws:iam::$ACCT:policy/$BNAME"
TAGS=(Key=project,Value="$AK2_TAG_PROJECT" Key=ak2:project,Value="$AK2_TAG_PROJECT")
TS=$(date -u +%Y%m%d-%H%M%S)
mkdir -p results/iam || die "cannot create results/iam"
REC="results/iam/conductor-$TS.json"
TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
canon() { jq -S -c . "$1"; }

# ---- 2. the boundary policy ----
if aws iam get-policy --policy-arn "$BARN" > "$TMP/bp.json" 2> "$TMP/err"; then
  V=$(jq -r .Policy.DefaultVersionId "$TMP/bp.json")
  aws iam get-policy-version --policy-arn "$BARN" --version-id "$V" --query PolicyVersion.Document --output json > "$TMP/bcur.json" ||
    die "cannot read $BARN $V"
  if [ "$(canon "$TMP/bcur.json")" = "$(canon scripts/iam/spawn-instance-boundary.json)" ]; then
    say "boundary $BARN: unchanged ($V)"; BACT=unchanged
  else
    N=$(aws iam list-policy-versions --policy-arn "$BARN" --query 'length(Versions)' --output text) || die "list-policy-versions failed"
    if [ "$N" -ge 5 ]; then
      OLD=$(aws iam list-policy-versions --policy-arn "$BARN" --query 'Versions[?IsDefaultVersion==`false`]|[-1].VersionId' --output text)
      aws iam delete-policy-version --policy-arn "$BARN" --version-id "$OLD" || die "cannot delete $BARN $OLD"
    fi
    aws iam create-policy-version --policy-arn "$BARN" --set-as-default \
      --policy-document file://scripts/iam/spawn-instance-boundary.json > /dev/null || die "create-policy-version failed"
    say "boundary $BARN: new default version"; BACT=updated
  fi
  aws iam tag-policy --policy-arn "$BARN" --tags "${TAGS[@]}" || die "tag-policy failed"
elif grep -q NoSuchEntity "$TMP/err"; then
  aws iam create-policy --policy-name "$BNAME" --description "aws-kraken2: the most a spawn run role may do (docs/conductor.md)" \
    --policy-document file://scripts/iam/spawn-instance-boundary.json --tags "${TAGS[@]}" > /dev/null || die "create-policy $BNAME failed"
  say "boundary $BARN: created"; BACT=created
else
  die "get-policy $BARN failed: $(cat "$TMP/err")"
fi
BVER=$(aws iam get-policy --policy-arn "$BARN" --query Policy.DefaultVersionId --output text)

# ---- 3. the role and its policy ----
if aws iam get-role --role-name "$ROLE" > "$TMP/role.json" 2> "$TMP/err"; then
  if [ "$(jq -S -c .Role.AssumeRolePolicyDocument "$TMP/role.json")" != "$(canon scripts/iam/conductor-trust.json)" ]; then
    aws iam update-assume-role-policy --role-name "$ROLE" --policy-document file://scripts/iam/conductor-trust.json ||
      die "update-assume-role-policy failed"
    say "role $ROLE: trust policy updated"
  fi
  RACT=exists
elif grep -q NoSuchEntity "$TMP/err"; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document file://scripts/iam/conductor-trust.json \
    --description "aws-kraken2 conductor: runs make ladder-campaign off the laptop (docs/conductor.md)" \
    --max-session-duration 3600 --tags "${TAGS[@]}" > /dev/null || die "create-role $ROLE failed"
  say "role $ROLE: created"; RACT=created
else
  die "get-role $ROLE failed: $(cat "$TMP/err")"
fi
aws iam tag-role --role-name "$ROLE" --tags "${TAGS[@]}" || die "tag-role failed"
aws iam put-role-policy --role-name "$ROLE" --policy-name ak2-conductor-policy \
  --policy-document file://scripts/iam/conductor-policy.json || die "put-role-policy failed"
EXTRA=$(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[?@!=`ak2-conductor-policy`]' --output text)
ATT=$(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[].PolicyArn' --output text)
[ -z "$EXTRA" ] && [ -z "$ATT" ] || die "role $ROLE carries policies this script does not manage (inline: '$EXTRA', attached: '$ATT'); remove them by hand"
RARN=$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)
say "role $RARN: inline policy ak2-conductor-policy = scripts/iam/conductor-policy.json"

# ---- 4. the instance profile ----
if aws iam get-instance-profile --instance-profile-name "$PROFILE" > "$TMP/ip.json" 2> "$TMP/err"; then PACT=exists
elif grep -q NoSuchEntity "$TMP/err"; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE" --tags "${TAGS[@]}" > /dev/null || die "create-instance-profile failed"
  aws iam get-instance-profile --instance-profile-name "$PROFILE" > "$TMP/ip.json" || die "get-instance-profile failed"
  PACT=created; say "instance profile $PROFILE: created"
else
  die "get-instance-profile failed: $(cat "$TMP/err")"
fi
HAS=$(jq -r --arg r "$ROLE" '[.InstanceProfile.Roles[].RoleName] | index($r) != null' "$TMP/ip.json")
NR=$(jq -r '.InstanceProfile.Roles | length' "$TMP/ip.json")
if [ "$HAS" != true ]; then
  [ "$NR" = 0 ] || die "instance profile $PROFILE holds another role: $(jq -c '[.InstanceProfile.Roles[].RoleName]' "$TMP/ip.json")"
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" || die "add-role-to-instance-profile failed"
  say "instance profile $PROFILE: role $ROLE added"
fi
aws iam tag-instance-profile --instance-profile-name "$PROFILE" --tags "${TAGS[@]}" || die "tag-instance-profile failed"
PARN=$(aws iam get-instance-profile --instance-profile-name "$PROFILE" --query InstanceProfile.Arn --output text)

# ---- 5. the boundary on each run role ----
BOUND='[]'; PENDING=0
for R in $(python3 scripts/iam/conductor_policy_check.py roles); do
  aws iam get-role --role-name "$R" > "$TMP/r.json" || die "get-role $R failed (spawn creates it on the first laptop launch of a spec that needs it)"
  CUR=$(jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // empty' "$TMP/r.json")
  # What the role carries now must lie inside the boundary, or attaching it would narrow the runs.
  docs=()
  for p in $(aws iam list-role-policies --role-name "$R" --query PolicyNames --output text); do
    aws iam get-role-policy --role-name "$R" --policy-name "$p" --query PolicyDocument --output json > "$TMP/$R-$p.json" || die "get-role-policy $R $p failed"
    docs+=("$TMP/$R-$p.json")
  done
  for a in $(aws iam list-attached-role-policies --role-name "$R" --query 'AttachedPolicies[].PolicyArn' --output text); do
    v=$(aws iam get-policy --policy-arn "$a" --query Policy.DefaultVersionId --output text) || die "get-policy $a failed"
    aws iam get-policy-version --policy-arn "$a" --version-id "$v" --query PolicyVersion.Document --output json > "$TMP/$R-att-${a##*/}.json" ||
      die "get-policy-version $a failed"
    docs+=("$TMP/$R-att-${a##*/}.json")
  done
  COVER=$(python3 scripts/iam/conductor_policy_check.py covers "${docs[@]}" 2>&1); CRC=$?
  USERS=$(aws ec2 describe-instances --region us-west-2 \
    --filters "Name=iam-instance-profile.arn,Values=arn:aws:iam::$ACCT:instance-profile/$R" \
              Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    --query 'Reservations[].Instances[].InstanceId' --output text) || die "describe-instances (users of $R) failed"
  if [ "$CUR" = "$BARN" ]; then
    ST=attached; NOTE="already attached"
    [ "$CRC" = 0 ] || { ST=attached-narrowing; NOTE="attached, but the role's policies allow more than the boundary: $COVER"; }
  elif [ -n "$CUR" ]; then
    die "run role $R has another permissions boundary ($CUR); not replacing it"
  elif [ "$CRC" != 0 ]; then
    ST=pending; PENDING=1; NOTE="not attached: the role's policies allow more than the boundary ($COVER); extend scripts/iam/spawn-instance-boundary.json first"
  elif [ -n "$USERS" ]; then
    ST=pending; PENDING=1; NOTE="not attached: instance(s) $USERS use the role now; run make conductor-iam again when nothing is in flight"
  else
    aws iam put-role-permissions-boundary --role-name "$R" --permissions-boundary "$BARN" || die "put-role-permissions-boundary $R failed"
    ST=attached; NOTE="attached now (no instance was using the role; its policies lie inside the boundary)"
  fi
  say "run role $R: boundary $ST: $NOTE"
  BOUND=$(jq -c --arg r "$R" --arg s "$ST" --arg n "$NOTE" --arg u "$USERS" '. + [{role:$r, boundary:$s, note:$n, in_use_by:($u|split("\t")|map(select(.!="")))}]' <<< "$BOUND")
done

# ---- 7. verify by simulation; then the record ----
VER="$TMP/verify.json"
scripts/iam/conductor-iam-verify.sh "$RARN" > "$VER"; VRC=$?
jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg who "$WHO" --arg sha "$(git rev-parse HEAD)" \
  --argjson dirty "$([ -z "$(git status --porcelain -- scripts/iam)" ] && echo false || echo true)" \
  --arg rarn "$RARN" --arg parn "$PARN" --arg barn "$BARN" --arg bver "$BVER" --arg bact "$BACT" --arg ract "$RACT" --arg pact "$PACT" \
  --arg psha "$(shasum -a 256 scripts/iam/conductor-policy.json | cut -d' ' -f1)" \
  --arg tsha "$(shasum -a 256 scripts/iam/conductor-trust.json | cut -d' ' -f1)" \
  --arg bsha "$(shasum -a 256 scripts/iam/spawn-instance-boundary.json | cut -d' ' -f1)" \
  --argjson bound "$BOUND" --slurpfile ver "$VER" --argjson vrc "$VRC" '{
    made_by:"make conductor-iam (scripts/iam/conductor-iam.sh)", at:$at, caller:$who, commit:$sha, scripts_iam_dirty:$dirty,
    role:{arn:$rarn, action:$ract, inline_policy:"ak2-conductor-policy", policy_file:"scripts/iam/conductor-policy.json", policy_sha256:$psha,
          trust_file:"scripts/iam/conductor-trust.json", trust_sha256:$tsha},
    instance_profile:{arn:$parn, action:$pact},
    boundary:{arn:$barn, version:$bver, action:$bact, file:"scripts/iam/spawn-instance-boundary.json", sha256:$bsha},
    run_roles:$bound, tags:{project:"aws-kraken2", "ak2:project":"aws-kraken2"},
    simulation:($ver[0] // null), simulation_rc:$vrc}' > "$REC" || die "could not write $REC"
say "record: $REC"
[ "$VRC" = 0 ] || { say "VERIFY FAILED (simulation above; $REC)"; exit 1; }
[ "$PENDING" = 0 ] || { say "PENDING: the boundary is not on every run role (above): the conductor can plan and dry-run, but its rung launches would be refused at PutRolePolicy until it is"; exit 3; }
say "done: role, profile, policy and boundary in place and verified"
exit 0
