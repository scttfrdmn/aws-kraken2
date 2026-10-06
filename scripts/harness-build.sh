#!/usr/bin/env bash
# Build an oracle harness, upstream/<name>.cc, against upstream's own sources at the pin with
# src/Makefile's flags (-fopenmp -Wall -std=c++11 -O3 -fPIC -g -DLINEAR_PROBING). Objects and the
# binary go to <oracle>/harness/<name>/. The oracle root defaults to the main checkout's .oracle,
# which worktrees share. Prints the binary path.
# Usage: scripts/harness-build.sh <name> [upstream-module ...]
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
NAME=${1:?usage: harness-build.sh <name> [upstream-module ...]}
shift
MODS=("$@")
if [ ${#MODS[@]} -eq 0 ]; then
  MODS=(mmscanner compact_hash taxonomy mmap_file utilities seqreader fast_reader omp_hack)
fi
MAIN=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
ROOT=${ORACLE_ROOT:-$MAIN/.oracle}
SRC="$ROOT/src-$UPSTREAM_PIN/src"
[ -d "$SRC" ] || { echo "harness-build: no upstream source at $SRC (run make oracle)" >&2; exit 1; }
test "$(git -C "$SRC" rev-parse HEAD)" = "$UPSTREAM_PIN"
if [ "$(uname -s)" = Darwin ] && [ -z "${CXX:-}" ]; then
  CXX=$(ls /opt/homebrew/bin/g++-[0-9]* 2>/dev/null | sort -V | tail -1)
  [ -n "$CXX" ] || { echo "harness-build: need Homebrew gcc (brew install gcc)" >&2; exit 1; }
fi
CXX=${CXX:-g++}
CXXFLAGS="-fopenmp -Wall -std=c++11 -O3 -fPIC -g -DLINEAR_PROBING"
OUT="$ROOT/harness/$NAME"
mkdir -p "$OUT/obj"
OBJS=()
for m in "${MODS[@]}"; do
  o="$OUT/obj/$m.o"
  if [ ! -s "$o" ] || [ "$SRC/$m.cc" -nt "$o" ]; then
    # shellcheck disable=SC2086
    "$CXX" $CXXFLAGS -c "$SRC/$m.cc" -o "$o"
  fi
  OBJS+=("$o")
done
# shellcheck disable=SC2086
"$CXX" $CXXFLAGS -I"$SRC" -o "$OUT/$NAME" "upstream/$NAME.cc" "${OBJS[@]}"
echo "pin $UPSTREAM_PIN cxx $("$CXX" --version | head -1) flags $CXXFLAGS" > "$OUT/BUILD"
echo "$OUT/$NAME"
