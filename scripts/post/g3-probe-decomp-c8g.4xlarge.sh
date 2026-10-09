#!/usr/bin/env bash
# Post script for runs/g3-probe-decomp-c8g.4xlarge.json (run.sh): scripts/lib/probe_tables.py decomp on the run dir.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/probe_tables.py decomp "$1"
