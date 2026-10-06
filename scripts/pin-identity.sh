#!/usr/bin/env bash
# Upstream pin identity (CLAUDE.md: the pin's identity is the commit SHA). Every manifest records
# the full SHA and what `git describe --tags` prints for it, both computed here from
# scripts/pin.env and the oracle source checkout (scripts/paths.sh), never hard-coded.
#
# Sourced: defines pin_identity, which sets UPSTREAM_SHA and UPSTREAM_DESCRIBE and returns
# non-zero, saying why, if the oracle source checkout is missing (it never clones: run
# scripts/oracle-build.sh), if fetching the pin fails, or on any mismatch.
# Executed: prints {"repo","sha","describe"} as JSON.
#
# Upstream's tags have no "v" (2.17.2), so describe prints e.g. 2.17.2-20-g2731b35; we record
# whatever git prints.
pin_identity() {
  local here root
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  root=$(cd "$here/.." && pwd)
  # shellcheck source=/dev/null
  . "$root/scripts/pin.env" || return 1
  local src
  # shellcheck source=/dev/null
  src=$(cd "$root" && . scripts/paths.sh && echo "$ORACLE_SRC") || return 1
  if [ ! -d "$src/.git" ]; then
    echo "pin-identity: no upstream source checkout at $src; run scripts/oracle-build.sh (make oracle builds it) first" >&2
    return 1
  fi
  if ! git -C "$src" cat-file -e "$UPSTREAM_PIN^{commit}" 2>/dev/null; then
    git -C "$src" fetch -q --tags origin "$UPSTREAM_PIN" || {
      echo "pin-identity: $UPSTREAM_PIN is not in $src and fetching it from origin failed" >&2; return 1; }
  fi
  UPSTREAM_SHA=$(git -C "$src" rev-parse --verify -q "$UPSTREAM_PIN^{commit}") || {
    echo "pin-identity: $UPSTREAM_PIN is not a commit in $src" >&2; return 1; }
  [ "$UPSTREAM_SHA" = "$UPSTREAM_PIN" ] || {
    echo "pin-identity: scripts/pin.env UPSTREAM_PIN must be a full SHA (resolves to $UPSTREAM_SHA)" >&2; return 1; }
  UPSTREAM_DESCRIBE=$(git -C "$src" describe --tags "$UPSTREAM_SHA") || {
    echo "pin-identity: git describe failed for $UPSTREAM_SHA" >&2; return 1; }
  export UPSTREAM_SHA UPSTREAM_DESCRIBE
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  pin_identity || exit 1
  printf '{"repo":"%s","sha":"%s","describe":"%s"}\n' "$UPSTREAM_REPO" "$UPSTREAM_SHA" "$UPSTREAM_DESCRIBE"
fi
