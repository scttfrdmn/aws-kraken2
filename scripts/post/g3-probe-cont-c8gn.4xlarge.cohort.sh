#!/usr/bin/env bash
# Cohort post script for runs/g3-probe-cont-c8gn.4xlarge.json (run-multi.sh): scripts/lib/probe_tables.py cont
# on the cohort dir (the members' pushed out/cont-<rank>.jsonl).
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/probe_tables.py cont "$1"
