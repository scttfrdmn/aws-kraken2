#!/usr/bin/env bash
# Cohort post script for runs/stage-cohort.json run as make run ... NODES=n (scripts/run-multi.sh
# runs it with the cohort dir): merges every member's out/staged.tsv into
# results/cohort/PRJNA398089/staged.tsv and checks ranks 11..1000 (scripts/lib/stage_merge.py;
# tables/staged-check.tsv). Then tag the objects from the launch host:
# make tag-objects PREFIX=aws-kraken2/data/cohort/.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
python3 scripts/lib/stage_merge.py "$1" PRJNA398089 11 1000
