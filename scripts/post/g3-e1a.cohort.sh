#!/usr/bin/env bash
# Cohort post script for runs/g3-e1a.json (scripts/run-multi.sh runs scripts/post/<spec>.cohort.sh
# with the cohort dir): tables/tidy.tsv over every member and tables/rates.tsv, the measured rates
# E1 reports against the sweep estimate's basis (scripts/lib/tidy.py). It reads the cohort dir
# and the member run dirs cohort.json names.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/tidy.py cohort "$1"
