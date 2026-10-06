#!/usr/bin/env bash
# Build upstream kraken2 at the pin, exactly as its install script ships it (including the
# Makefile's default -DLINEAR_PROBING), into .oracle/<pin>/. Idempotent. Prints the install dir.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
ROOT="$PWD/.oracle"
SRC="$ROOT/src-$UPSTREAM_PIN"
DST="$ROOT/$UPSTREAM_PIN"
if [ -x "$DST/classify" ] && [ -s "$DST/BUILD" ]; then echo "$DST"; exit 0; fi
mkdir -p "$ROOT"
if [ ! -d "$SRC/.git" ]; then
  git clone -q "$UPSTREAM_REPO" "$SRC"
fi
git -C "$SRC" fetch -q origin "$UPSTREAM_PIN" 2>/dev/null || true
git -C "$SRC" checkout -q --detach "$UPSTREAM_PIN"
test "$(git -C "$SRC" rev-parse HEAD)" = "$UPSTREAM_PIN"
# Apple clang has no -fopenmp; use Homebrew GCC on macOS. Linux uses the system g++.
if [ "$(uname -s)" = Darwin ]; then
  CXX=$(ls /opt/homebrew/bin/g++-[0-9]* 2>/dev/null | sort -V | tail -1)
  [ -n "$CXX" ] || { echo "oracle-build: need Homebrew gcc (brew install gcc)" >&2; exit 1; }
  export CXX
fi
make -C "$SRC/src" clean >/dev/null
(cd "$SRC" && ./install_kraken2.sh "$DST") >"$ROOT/build-$UPSTREAM_PIN.log" 2>&1 \
  || { tail -30 "$ROOT/build-$UPSTREAM_PIN.log" >&2; exit 1; }
{
  echo "pin $UPSTREAM_PIN"
  echo "describe $(git -C "$SRC" describe --tags)"
  echo "cxx $("${CXX:-g++}" --version | head -1)"
  echo "version $("$DST/kraken2" --version | head -1)"
  echo "built $(date -u +%FT%TZ) $(uname -sm)"
} > "$DST/BUILD"
echo "$DST"
