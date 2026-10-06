#!/usr/bin/env bash
# Build an oracle harness upstream/<name>.cc against upstream's sources at the pin, with the
# CXXFLAGS src/Makefile ships (including -DLINEAR_PROBING and -fopenmp), into .oracle/harness/.
# Upstream's non-main objects are compiled once per pin into an archive the harness links to.
# Usage: scripts/harness-build.sh <name>...   Prints the path of each built harness.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
[ $# -ge 1 ] || { echo "usage: $0 <name>..." >&2; exit 2; }
# Pinned sources: this checkout's .oracle, else the main checkout's (worktrees share it).
SRC="$PWD/.oracle/src-$UPSTREAM_PIN"
if [ ! -d "$SRC/src" ]; then
  MAIN=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
  SRC="$MAIN/.oracle/src-$UPSTREAM_PIN"
fi
[ -d "$SRC/src" ] || { echo "harness-build: no pinned sources; run scripts/oracle-build.sh" >&2; exit 1; }
test "$(git -C "$SRC" rev-parse HEAD)" = "$UPSTREAM_PIN"
if [ "$(uname -s)" = Darwin ]; then
  CXX=$(ls /opt/homebrew/bin/g++-[0-9]* 2>/dev/null | sort -V | tail -1)
  [ -n "$CXX" ] || { echo "harness-build: need Homebrew gcc (brew install gcc)" >&2; exit 1; }
fi
CXX=${CXX:-g++}
OUT="$PWD/.oracle/harness"
OBJ="$OUT/obj-$UPSTREAM_PIN"
mkdir -p "$OBJ"
# CXXFLAGS exactly as src/Makefile computes them.
MK=$(mktemp); trap 'rm -f "$MK"' EXIT
printf 'print-cxxflags:\n\t@echo $(CXXFLAGS)\n' > "$MK"
CXXFLAGS=$(make -s -C "$SRC/src" -f Makefile -f "$MK" print-cxxflags)
LIB="$OBJ/libkraken2.a"
if [ ! -s "$LIB" ]; then
  objs=()
  for f in "$SRC"/src/*.cc; do
    b=$(basename "$f" .cc)
    grep -q '^int main' "$f" && continue      # programs, not library code
    [ "$b" = libtax ] && continue             # Python-facing shared-library shim
    "$CXX" $CXXFLAGS -I"$SRC/src" -c "$f" -o "$OBJ/$b.o" 2>>"$OBJ/build.log" \
      || { tail -30 "$OBJ/build.log" >&2; exit 1; }
    objs+=("$OBJ/$b.o")
  done
  ar rcs "$LIB" "${objs[@]}"
fi
for name in "$@"; do
  "$CXX" $CXXFLAGS -I"$SRC/src" -o "$OUT/$name" "upstream/$name.cc" "$LIB" -lz
  { echo "pin $UPSTREAM_PIN"; echo "cxx $("$CXX" --version | head -1)"; echo "cxxflags $CXXFLAGS"
    echo "built $(date -u +%FT%TZ) $(uname -sm)"; } > "$OUT/$name.BUILD"
  echo "$OUT/$name"
done
