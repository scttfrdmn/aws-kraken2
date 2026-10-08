#!/usr/bin/env bash
# Cohort post script for runs/g3-e1.json (scripts/run-multi.sh runs scripts/post/<spec>.cohort.sh
# with the cohort dir): tables/tidy.tsv over every member and tables/rates.tsv, the measured rates
# E1 reports against the sweep estimate's basis (scripts/lib/tidy.py), and tables/consistency.tsv
# from the launch host's listing of the outputs (outputs.tsv; scripts/lib/e1_consistency.py: one
# ETag per output across every variant of a sample). It reads the cohort dir and the member run
# dirs cohort.json names. Exits non-zero if any sample's variants differ.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/tidy.py cohort "$1"; t=$?
python3 scripts/lib/e1_consistency.py "$1"; c=$?
python3 scripts/lib/e1_batches.py "$1"; b=$?
[ "$t" = 0 ] && [ "$c" = 0 ] && [ "$b" = 0 ]
