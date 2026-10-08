#!/usr/bin/env bash
# Post script for runs/g3-u1-x8g.24xlarge.json (run.sh): scripts/lib/u1_tables.py on the run dir.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/u1_tables.py "$1"
