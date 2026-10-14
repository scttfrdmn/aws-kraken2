#!/usr/bin/env bash
# make conductor-iam-verify [ROLE_ARN] (docs/conductor.md, "IAM"): the conductor role's policies, and
# the run role's, through the IAM policy simulator (scripts/iam/conductor_iam_verify.py). stdout: JSON.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
# shellcheck source=/dev/null
. scripts/ak2.env
export AWS_PROFILE
if [ "${CUSTOM:-}" = 1 ]; then ARN=--custom; else ARN=${1:-arn:aws:iam::$AK2_ACCOUNT:role/$AK2_CONDUCTOR_ROLE}; fi
python3 scripts/iam/conductor_iam_verify.py "$ARN"
