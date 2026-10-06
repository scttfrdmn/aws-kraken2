#!/usr/bin/env bash
# Build upstream kraken2 at the pin, exactly as its install script ships it (including the
# Makefile's default -DLINEAR_PROBING), into the shared .oracle/<pin>/ (scripts/paths.sh: the
# main checkout's, which worktrees share). Idempotent. Prints the install dir.
# Compiler: scripts/cxx.sh (system g++ with OpenMP on Linux, Homebrew g++ on macOS).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
. scripts/paths.sh
SRC="$ORACLE_SRC"
DST="$ORACLE_DST"
if [ -x "$DST/classify" ] && [ -x "$DST/kraken2" ] && [ -s "$DST/BUILD" ]; then echo "$DST"; exit 0; fi
mkdir -p "$(dirname "$DST")"
if [ ! -d "$SRC/.git" ]; then
  git clone -q "$UPSTREAM_REPO" "$SRC"
fi
git -C "$SRC" fetch -q origin "$UPSTREAM_PIN" 2>/dev/null || true
git -C "$SRC" checkout -q --detach "$UPSTREAM_PIN"
test "$(git -C "$SRC" rev-parse HEAD)" = "$UPSTREAM_PIN"
git -C "$SRC" diff --quiet HEAD -- || { echo "oracle-build: $SRC has tracked modifications" >&2; exit 1; }
. scripts/cxx.sh
LOG="$(dirname "$DST")/build-$UPSTREAM_PIN.log"
make -C "$SRC/src" clean >/dev/null
(cd "$SRC" && ./install_kraken2.sh "$DST") >"$LOG" 2>&1 \
  || { tail -30 "$LOG" >&2; exit 1; }
{
  echo "pin $UPSTREAM_PIN"
  echo "describe $(git -C "$SRC" describe --tags)"
  echo "cxx $CXX ($("$CXX" --version | head -1))"
  echo "version $("$DST/kraken2" --version | head -1)"
  echo "built $(date -u +%FT%TZ) $(uname -sm)"
} > "$DST/BUILD"
echo "$DST"
