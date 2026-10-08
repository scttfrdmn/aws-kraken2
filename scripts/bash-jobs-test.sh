#!/usr/bin/env bash
# make bash-jobs-test (docs/cohort.md, "The G3 campaign"): the bash job-control check, in Amazon
# Linux 2023's own bash (podman, public.ecr.aws/amazonlinux/amazonlinux:2023), started as
# `bash -c` the way spored starts a body. scripts/tests/bash_jobs.sh says what it checks. The
# record goes to results/rehearse/bash-jobs-<UTC>-<commit>.txt. Needs podman and a podman machine
# that shares this checkout's path.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
command -v podman >/dev/null || { echo "bash-jobs-test: need podman" >&2; exit 1; }
SHA=$(git rev-parse --short=7 HEAD)
O=$(mktemp -d "$HOME/.ak2-bash-jobs.XXXXXX")
REC="results/rehearse/bash-jobs-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.txt"
mkdir -p results/rehearse
podman run --rm -e N="${N:-600}" -e LIMIT="${LIMIT:-60}" -v "$ROOT:/repo:ro" -v "$O:/o" \
  public.ecr.aws/amazonlinux/amazonlinux:2023 bash -c "$(cat scripts/tests/bash_jobs.sh)" > "$O/stdout" 2>&1
RC=$?
{ echo "bash-jobs-test at $SHA ($(git diff --quiet HEAD -- scripts && echo clean || echo dirty)); container exit $RC"; cat "$O/bash-jobs.txt" 2>/dev/null || cat "$O/stdout"; } | tee "$REC"
rm -rf "$O"
exit "$RC"
