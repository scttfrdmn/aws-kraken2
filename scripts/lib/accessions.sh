#!/usr/bin/env bash
# Resolve a spec's env.AK2_ACCESSIONS (docs/run.md, "Sample accessions"):
#
#   scripts/lib/accessions.sh [-r REPO_ROOT] VALUE      -> the accessions, space-separated, on stdout
#   scripts/lib/accessions.sh [-r REPO_ROOT] -f VALUE   -> the runs.tsv path a reference names
#
# VALUE is either a literal space-separated list (printed back, whitespace normalised) or a
# reference to a recorded cohort range, @<project>:<a>-<b>: ranks a..b (inclusive, 1-based) of
# results/cohort/<project>/runs.tsv (column 1 rank, column 2 run accession). A reference must
# name ranks that exist, each exactly once, in order; anything else exits 2 with the reason.
#
# The same script runs in two places, on the same file: run.sh/run-multi.sh on the launching
# machine (into manifest.sample_accessions; run.sh refuses a runs.tsv that is not committed or has
# local changes), and a body on the node from its repo checkout at the run's commit:
#   ACC=$("$W/repo/scripts/lib/accessions.sh" -r "$W/repo" "$AK2_ACCESSIONS")
# Only the short reference travels in the spec env (and so in user data).
set +e
set -uo pipefail
ROOT=""; FILE_ONLY=0
while [ $# -gt 0 ]; do
  case $1 in
    -r) ROOT=${2:-}; shift 2 ;;
    -f) FILE_ONLY=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -eq 1 ] || { echo "accessions: usage: accessions.sh [-r REPO_ROOT] [-f] VALUE" >&2; exit 2; }
V=$1
[ -n "$ROOT" ] || ROOT=$(cd "$(dirname "$0")/../.." && pwd) || exit 2

if [[ "$V" != @* ]]; then
  [ "$FILE_ONLY" = 1 ] && exit 0
  # shellcheck disable=SC2086
  set -f; set -- $V; set +f
  echo "$*"
  exit 0
fi
[[ "$V" =~ ^@([A-Za-z0-9_.-]+):([1-9][0-9]*)-([1-9][0-9]*)$ ]] ||
  { echo "accessions: '$V' is not @<project>:<a>-<b> (ranks 1-based, a <= b)" >&2; exit 2; }
P=${BASH_REMATCH[1]}; A=${BASH_REMATCH[2]}; B=${BASH_REMATCH[3]}
[ "$A" -le "$B" ] || { echo "accessions: '$V': range start $A is after its end $B" >&2; exit 2; }
REL="results/cohort/$P/runs.tsv"
if [ "$FILE_ONLY" = 1 ]; then echo "$REL"; exit 0; fi
F="$ROOT/$REL"
[ -f "$F" ] || { echo "accessions: '$V': no $REL under $ROOT" >&2; exit 2; }
OUT=$(awk -F'\t' -v a="$A" -v b="$B" -v f="$REL" '
  NR == 1 { if ($1 != "rank" || $2 != "run") { print "header of " f " is not rank<TAB>run..." > "/dev/stderr"; bad = 1; exit } next }
  $1 >= a + 0 && $1 <= b + 0 {
    want = a + n
    if ($1 + 0 != want) { print f ": rank " $1 " where rank " want " was expected (ranks must be contiguous and in order)" > "/dev/stderr"; bad = 1; exit }
    if ($2 !~ /^[A-Z]+[0-9]+$/) { print f ": rank " $1 " has a malformed accession \"" $2 "\"" > "/dev/stderr"; bad = 1; exit }
    printf "%s%s", (n ? " " : ""), $2; n++
  }
  END { if (bad) exit 1; if (n != b - a + 1) { print f ": ranks " a "-" b " want " (b - a + 1) " rows, found " n > "/dev/stderr"; exit 1 } print "" }' "$F")
[ $? -eq 0 ] || { echo "accessions: cannot resolve '$V'" >&2; exit 2; }
echo "$OUT"
