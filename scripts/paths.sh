# Shared-resource locations, sourced by scripts after scripts/pin.env.
# The upstream checkout, the oracle build, databases and reads are large and live once in the main
# checkout; git worktrees find them through the common git dir. Override with K2_SHARED_ROOT.
# What a script builds or dumps (harness binaries, key streams) stays in the current checkout.
if [ -z "${K2_SHARED_ROOT:-}" ]; then
  K2_SHARED_ROOT=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
fi
ORACLE_SRC="$K2_SHARED_ROOT/.oracle/src-$UPSTREAM_PIN"
ORACLE_DST="$K2_SHARED_ROOT/.oracle/$UPSTREAM_PIN"
K2_DB_ROOT="$K2_SHARED_ROOT/.cache/db"
K2_READS="$K2_SHARED_ROOT/.cache/reads"
