#!/usr/bin/env bash
# Post script for runs/inputpath-<family>-<engine>.json (run.sh runs scripts/post/<spec name>.sh,
# a symlink to this): tables/inputpath.tsv and tables/inputpath-defects.tsv from out/points.jsonl
# (scripts/inputpath/tables.py; docs/inputpath.md).
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/inputpath/tables.py --run "$1"
