#!/usr/bin/env bash
# Post script for runs/g3-e1.json, per member (run.sh): tables/tidy.tsv from the member's pushed
# engine stderr (scripts/lib/tidy.py). The cohort-level tables come from g3-e1.cohort.sh.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/tidy.py member "$1"
