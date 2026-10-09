#!/usr/bin/env bash
# scripts/lib/mkstub.sh [STUB] [SAMPLER]: print the user-data stub with the utilisation sampler
# spliced in (docs/run.md, "Utilisation"). scripts/run.sh puts this output in command[2] (and
# keeps a copy as the run dir's stub.sh); scripts/lib/util_stream_test.sh runs the same output.
# The marker line `#@AK2_UTIL_SAMPLER@` in the stub is replaced by the sampler with its
# full-line comments and blank lines removed (user data is capped; the stub sits in a quoted
# heredoc, so nothing in it is expanded). Exits 2 if the marker is missing or the sampler
# contains the heredoc's terminator.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
STUB=${1:-$ROOT/scripts/stub.sh}; SAMPLER=${2:-$ROOT/scripts/util-sampler.sh}
[ "$(grep -c '^#@AK2_UTIL_SAMPLER@$' "$STUB")" = 1 ] || { echo "mkstub: $STUB must hold the marker line exactly once" >&2; exit 2; }
grep -q '^AK2UTIL$' "$SAMPLER" && { echo "mkstub: $SAMPLER contains the heredoc terminator AK2UTIL" >&2; exit 2; }
awk -v s="$SAMPLER" '
  $0 == "#@AK2_UTIL_SAMPLER@" { while ((getline l < s) > 0) if (l !~ /^[[:space:]]*(#|$)/) print l; next }
  { print }' "$STUB"
