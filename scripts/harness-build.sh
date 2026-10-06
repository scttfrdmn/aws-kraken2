#!/usr/bin/env bash
# Build every oracle harness upstream/*.cc against the pinned upstream sources, with the compiler
# and CXXFLAGS that upstream's src/Makefile ships (read from that Makefile, so -DLINEAR_PROBING is
# included exactly when upstream's default build has it).
#
# Two variants per harness, into .oracle/harness/ of this checkout:
#   <name>      upstream's default flags (the oracle)
#   <name>.dh   the same flags minus -DLINEAR_PROBING (upstream's double-hashing build)
# Upstream's own library sources are compiled out of tree (the shared checkout is never written).
# Usage: scripts/harness-build.sh            Prints the harness directory.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
. scripts/paths.sh
SRC="$ORACLE_SRC/src"
OUT="$PWD/.oracle/harness"
[ -f "$SRC/compact_hash.h" ] || { echo "harness-build: no upstream source at $SRC (run make oracle)" >&2; exit 1; }
HEAD=$(git -C "$ORACLE_SRC" rev-parse HEAD)
[ "$HEAD" = "$UPSTREAM_PIN" ] || { echo "harness-build: $ORACLE_SRC is at $HEAD, not the pin" >&2; exit 1; }

# Same compiler choice as scripts/oracle-build.sh.
if [ "$(uname -s)" = Darwin ]; then
  CXX=$(ls /opt/homebrew/bin/g++-[0-9]* 2>/dev/null | sort -V | tail -1)
  [ -n "$CXX" ] || { echo "harness-build: need Homebrew gcc (brew install gcc)" >&2; exit 1; }
fi
CXX=${CXX:-g++}
# Ask upstream's Makefile for its CXXFLAGS rather than restating them.
FLAGS=$(make -s -C "$SRC" -f Makefile -f /dev/stdin print-cxxflags <<'EOF'
print-cxxflags: ; @echo $(CXXFLAGS)
EOF
)
case " $FLAGS " in *" -DLINEAR_PROBING "*) ;; *) echo "harness-build: upstream CXXFLAGS lack -DLINEAR_PROBING: $FLAGS" >&2 ;; esac
FLAGS_DH=$(echo " $FLAGS " | sed 's/ -DLINEAR_PROBING / /g; s/^ //; s/ $//')

# Upstream library objects a harness may link (classify's objects minus classify.o).
LIB="mmap_file compact_hash taxonomy seqreader mmscanner omp_hack utilities reports hyperloglogplus aa_translate fast_reader"

build_variant() {  # $1 = suffix ("" or .dh), $2 = flags
  local sfx=$1 flags=$2 obj="$OUT/obj${1:-.lp}"
  mkdir -p "$obj"
  local objs=() pids=() p
  for f in $LIB; do
    "$CXX" $flags -c "$SRC/$f.cc" -o "$obj/$f.o" 2>>"$OUT/build.log" &
    pids+=($!)
    objs+=("$obj/$f.o")
  done
  for p in "${pids[@]}"; do wait "$p" || { tail -30 "$OUT/build.log" >&2; exit 1; }; done
  rm -f "$obj/libk2.a"
  ar rcs "$obj/libk2.a" "${objs[@]}"
  for h in upstream/*.cc; do
    local name; name=$(basename "$h" .cc)
    "$CXX" $flags -I"$SRC" -o "$OUT/$name$sfx" "$h" "$obj/libk2.a"
  done
}

mkdir -p "$OUT"
: > "$OUT/build.log"  # upstream library warnings go here, not to the terminal
build_variant "" "$FLAGS"
build_variant ".dh" "$FLAGS_DH"
{
  echo "pin $UPSTREAM_PIN"
  echo "src $ORACLE_SRC"
  echo "cxx $CXX ($("$CXX" --version | head -1))"
  echo "cxxflags $FLAGS"
  echo "cxxflags.dh $FLAGS_DH"
  echo "harnesses $(cd upstream && ls *.cc | tr '\n' ' ')"
  echo "built $(date -u +%FT%TZ) $(uname -sm)"
} > "$OUT/BUILD"
echo "$OUT"
