#!/usr/bin/env bash
# Post script for runs/g3-probe-tune-x8g.24xlarge.json (run.sh): scripts/lib/tune_tables.py on the run dir.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/tune_tables.py "$1"
