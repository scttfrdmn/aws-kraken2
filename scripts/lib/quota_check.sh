#!/usr/bin/env bash
# Pre-launch on-demand vCPU quota check (docs/run.md, "vCPU quota"):
#
#   scripts/lib/quota_check.sh REGION INSTANCE_TYPE COUNT
#
# Maps the type to its EC2 on-demand quota family, sums the vCPUs of COUNT new instances and of
# every on-demand instance of the same family already pending/running/stopping/shutting-down in
# the region (any owner tag: the quota is per account and region), and compares the sum with the
# family's applied quota from Service Quotas. Read-only calls only (describe-instance-types,
# describe-instances, service-quotas get-service-quota), under the caller's AWS_PROFILE.
#
# stdout: one JSON object (the record run.sh / run-multi.sh keep). stderr: the verdict.
# exit 0: within quota; 1: over quota (refuse); 2: cannot judge (refuse too: unknown family, a
# failed call, an unparsable answer).
set +e
set -uo pipefail
REGION=${1:-}; TYPE=${2:-}; COUNT=${3:-}
die() { echo "quota_check: $*" >&2; exit 2; }
[ -n "$REGION" ] && [ -n "$TYPE" ] && [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] ||
  die "usage: quota_check.sh REGION INSTANCE_TYPE COUNT (COUNT >= 1)"
command -v aws >/dev/null || die "aws not on PATH"
command -v jq >/dev/null || die "jq not on PATH"

# family_of TYPE -> "<quota code> <family name>", or nothing if no on-demand family is known.
# The letters before the first digit select the family (x8g -> x, im4gn -> im, trn1 -> trn,
# u7i-12tb -> u). Codes as listed by `aws service-quotas list-service-quotas --service-code ec2`.
family_of() {
  local p=${1%%.*}
  p=${p%%[0-9]*}
  case $p in
    a|c|d|h|i|m|r|t|z|im|is) echo "L-1216C47A Standard(A,C,D,H,I,M,R,T,Z)" ;;
    x)      echo "L-7295265B X" ;;
    u)      echo "L-43DA4232 HighMemory" ;;
    f)      echo "L-74FC7D96 F" ;;
    g|gr|vt) echo "L-DB2E81BA G+VT" ;;
    p)      echo "L-417A185B P" ;;
    inf)    echo "L-1945791B Inf" ;;
    trn)    echo "L-2C3B7624 Trn" ;;
    dl)     echo "L-6E869C2A DL" ;;
    hpc)    echo "L-F7808C92 HPC" ;;
    *) ;;
  esac
}

FAM=$(family_of "$TYPE")
[ -n "$FAM" ] || die "no on-demand vCPU quota family is known for $TYPE; add its prefix to family_of in scripts/lib/quota_check.sh"
CODE=${FAM%% *}; FNAME=${FAM#* }

# Every on-demand instance alive in the region (spot and capacity blocks have their own quotas).
LIVE=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=instance-state-name,Values=pending,running,stopping,shutting-down \
  --query 'Reservations[].Instances[].[InstanceType,InstanceLifecycle]' --output text 2>&1) ||
  die "describe-instances failed in $REGION: $(echo "$LIVE" | tr '\n' ' ' | cut -c1-200)"
SAME=$(echo "$LIVE" | awk 'NF >= 1 && $1 != "None" && $2 != "spot" && $2 != "capacity-block" {print $1}' |
  while read -r t; do f=$(family_of "$t"); [ "${f%% *}" = "$CODE" ] && echo "$t"; done)
TYPES=$(printf '%s\n' "$TYPE" $SAME | sort -u)

# vCPUs per type (the default count: the quota counts it, whatever CpuOptions an instance has).
# shellcheck disable=SC2086
VC=$(aws ec2 describe-instance-types --region "$REGION" --instance-types $TYPES \
  --query 'InstanceTypes[].[InstanceType,VCpuInfo.DefaultVCpus]' --output text 2>&1) ||
  die "describe-instance-types failed in $REGION: $(echo "$VC" | tr '\n' ' ' | cut -c1-200)"
vcpus_of() { echo "$VC" | awk -v t="$1" '$1 == t && $2 ~ /^[0-9]+$/ {print $2; exit}'; }
PER=$(vcpus_of "$TYPE")
[ -n "$PER" ] || die "describe-instance-types gave no vCPU count for $TYPE in $REGION"
RUN_VCPU=0; RUN_N=0
for t in $SAME; do
  v=$(vcpus_of "$t"); [ -n "$v" ] || die "describe-instance-types gave no vCPU count for running type $t"
  RUN_VCPU=$((RUN_VCPU + v)); RUN_N=$((RUN_N + 1))
done
REQ=$((PER * COUNT))

QV=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code "$CODE" \
  --query Quota.Value --output text 2>&1) ||
  die "service-quotas get-service-quota $CODE failed in $REGION: $(echo "$QV" | tr '\n' ' ' | cut -c1-200)"
[[ "$QV" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "service-quotas returned '$QV' for $CODE in $REGION"
QUOTA=${QV%%.*}
TOTAL=$((REQ + RUN_VCPU))
OKAY=true; [ "$TOTAL" -le "$QUOTA" ] || OKAY=false

jq -nc --arg region "$REGION" --arg type "$TYPE" --argjson count "$COUNT" --arg code "$CODE" --arg fam "$FNAME" \
  --argjson quota "$QUOTA" --argjson per "$PER" --argjson req "$REQ" --argjson run "$RUN_VCPU" --argjson runn "$RUN_N" \
  --argjson total "$TOTAL" --argjson ok "$OKAY" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{
    region:$region, instance_type:$type, count:$count, quota_code:$code, family:$fam, quota_vcpus:$quota,
    vcpus_per_instance:$per, requested_vcpus:$req, running_vcpus:$run, running_instances:$runn,
    total_vcpus:$total, within_quota:$ok, checked_at:$at}'

MSG="$COUNT x $TYPE = $REQ vCPU, plus $RUN_VCPU vCPU already running in $RUN_N on-demand $FNAME instance(s) = $TOTAL of the $FNAME on-demand quota $CODE ($QUOTA vCPU) in $REGION"
if [ "$OKAY" = true ]; then
  echo "quota_check: ok: $MSG" >&2; exit 0
fi
echo "quota_check: REFUSED: $MSG. Lower NODES, wait for the running instances to end, or request a quota increase (Service Quotas, $CODE)." >&2
exit 1
