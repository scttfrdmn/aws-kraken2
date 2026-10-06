#!/usr/bin/env bash
# Build an oracle harness upstream/<name>.cc against upstream's own sources at the pin, with the
# same compiler and flags as upstream's src/Makefile (including -DLINEAR_PROBING), into
# .oracle/harness/<name>. Prints the binary path. Needs scripts/oracle-build.sh to have run.
# Usage: scripts/harness-build.sh <name>
#
# .oracle/ lives in the main checkout; from a git worktree this script still uses the main
# checkout's .oracle/ (override with ORACLE_ROOT).
set -euo pipefail
NAME="${1:?usage: $0 <harness-name>}"
cd "$(dirname "$0")/.."
. scripts/pin.env
HERE="$PWD"
MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
ROOT="${ORACLE_ROOT:-$MAIN/.oracle}"
SRC="$ROOT/src-$UPSTREAM_PIN/src"
test -d "$SRC" || { echo "harness-build: no upstream source at $SRC (run scripts/oracle-build.sh)" >&2; exit 1; }
test "$(git -C "$SRC" rev-parse HEAD)" = "$UPSTREAM_PIN" || { echo "harness-build: $SRC is not at the pin" >&2; exit 1; }
IN="$HERE/upstream/$NAME.cc"
test -s "$IN" || { echo "harness-build: no $IN" >&2; exit 1; }

if [ "$(uname -s)" = Darwin ]; then
  CXX=$(ls /opt/homebrew/bin/g++-[0-9]* 2>/dev/null | sort -V | tail -1)
  [ -n "$CXX" ] || { echo "harness-build: need Homebrew gcc (brew install gcc)" >&2; exit 1; }
fi
CXX="${CXX:-g++}"
# Exactly src/Makefile's CXXFLAGS.
CXXFLAGS="-fopenmp -Wall -std=c++11 -O3 -fPIC -g -DLINEAR_PROBING"

# Upstream's library objects: everything `classify` links except classify.o itself.
LIB="reports hyperloglogplus mmap_file compact_hash taxonomy seqreader mmscanner omp_hack aa_translate utilities fast_reader"
OUT="$ROOT/harness"
OBJ="$OUT/obj-$UPSTREAM_PIN"
mkdir -p "$OBJ"
objs=()
for m in $LIB; do
  o="$OBJ/$m.o"
  if [ ! -s "$o" ] || [ "$SRC/$m.cc" -nt "$o" ]; then
    "$CXX" $CXXFLAGS -I"$SRC" -c "$SRC/$m.cc" -o "$o.$$" && mv -f "$o.$$" "$o"
  fi
  objs+=("$o")
done
"$CXX" $CXXFLAGS -I"$SRC" -o "$OUT/$NAME.$$" "$IN" "${objs[@]}" && mv -f "$OUT/$NAME.$$" "$OUT/$NAME"
echo "$OUT/$NAME"
