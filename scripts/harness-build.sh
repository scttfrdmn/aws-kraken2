#!/usr/bin/env bash
# Build oracle harnesses (upstream/<name>.cc) against upstream's own sources at the pin, with the
# compiler and CXXFLAGS upstream's src/Makefile ships (read from that Makefile, so -DLINEAR_PROBING
# and -fopenmp are included exactly when upstream's default build has them).
#
# Usage: scripts/harness-build.sh [--dh] [name...]
#   name...  harnesses to build (default: every upstream/*.cc)
#   --dh     also build <name>.dh: the same flags minus -DLINEAR_PROBING (upstream's
#            double-hashing build)
# Prints one absolute path per built binary, in argument order (each <name> before <name>.dh).
#
# Binaries go to .oracle/harness/ of *this* checkout (harness sources differ per branch), each with
# a <name>.BUILD provenance file. Upstream's library objects (every src/*.cc without a main, minus
# the libtax shim) are compiled once per (pin, compiler, flags) into one archive under
# .oracle/harness/obj-<key>/, rebuilt when any of those change. The shared upstream checkout
# (scripts/paths.sh) is only read: it must be at the pin with no tracked modifications.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
. scripts/paths.sh
DH=0
NAMES=()
for a in "$@"; do
  case "$a" in
    --dh) DH=1 ;;
    -*) echo "usage: $0 [--dh] [name...]" >&2; exit 2 ;;
    *) NAMES+=("$a") ;;
  esac
done
if [ ${#NAMES[@]} -eq 0 ]; then
  for h in upstream/*.cc; do NAMES+=("$(basename "$h" .cc)"); done
fi
for n in "${NAMES[@]}"; do
  [ -s "upstream/$n.cc" ] || { echo "harness-build: no upstream/$n.cc" >&2; exit 1; }
done

SRC="$ORACLE_SRC/src"
[ -f "$SRC/compact_hash.h" ] || { echo "harness-build: no upstream source at $SRC (scripts/oracle-build.sh)" >&2; exit 1; }
HEAD=$(git -C "$ORACLE_SRC" rev-parse HEAD)
[ "$HEAD" = "$UPSTREAM_PIN" ] || { echo "harness-build: $ORACLE_SRC is at $HEAD, not the pin" >&2; exit 1; }
git -C "$ORACLE_SRC" diff --quiet HEAD -- || { echo "harness-build: $ORACLE_SRC has tracked modifications" >&2; exit 1; }

. scripts/cxx.sh
# Ask upstream's Makefile for its CXXFLAGS rather than restating them.
MK=$(mktemp); trap 'rm -f "$MK"' EXIT
printf 'print-cxxflags:\n\t@echo $(CXXFLAGS)\n' > "$MK"
FLAGS=$(make -s -C "$SRC" -f Makefile -f "$MK" print-cxxflags)
case " $FLAGS " in *" -DLINEAR_PROBING "*) ;; *) echo "harness-build: note: upstream CXXFLAGS lack -DLINEAR_PROBING: $FLAGS" >&2 ;; esac
FLAGS_DH=$(echo " $FLAGS " | sed 's/ -DLINEAR_PROBING / /g; s/^ //; s/ $//')
CXXV=$("$CXX" --version | head -1)

OUT="$PWD/.oracle/harness"
mkdir -p "$OUT"

# archive FLAGS: echo the path of the upstream library archive for FLAGS, building it if needed.
archive() {
  local flags=$1 key obj
  key=$(printf '%s\n%s\n%s\n' "$UPSTREAM_PIN" "$CXXV" "$flags" | shasum -a 256 | cut -c1-12)
  obj="$OUT/obj-$key"
  if [ ! -s "$obj/libk2.a" ]; then
    rm -rf "$obj.tmp"; mkdir -p "$obj.tmp"
    local f b objs=() pids=() p
    for f in "$SRC"/*.cc; do
      b=$(basename "$f" .cc)
      grep -q '^int main' "$f" && continue   # programs, not library code
      [ "$b" = libtax ] && continue          # Python-facing shared-library shim
      # -o into our own dir: the shared checkout is never written.
      "$CXX" $flags -I"$SRC" -c "$f" -o "$obj.tmp/$b.o" 2>>"$obj.tmp/build.log" &
      pids+=($!); objs+=("$obj.tmp/$b.o")
    done
    for p in "${pids[@]}"; do wait "$p" || { tail -30 "$obj.tmp/build.log" >&2; exit 1; }; done
    ar rcs "$obj.tmp/libk2.a" "${objs[@]}"
    printf 'pin %s\ncxx %s (%s)\ncxxflags %s\n' "$UPSTREAM_PIN" "$CXX" "$CXXV" "$flags" > "$obj.tmp/KEY"
    rm -rf "$obj"; mv "$obj.tmp" "$obj"
  fi
  echo "$obj/libk2.a"
}

LIB=$(archive "$FLAGS")
[ "$DH" = 1 ] && LIB_DH=$(archive "$FLAGS_DH")

build_one() {  # name suffix flags lib
  local name=$1 sfx=$2 flags=$3 lib=$4 bin="$OUT/$1$2"
  "$CXX" $flags -I"$SRC" -o "$bin.tmp.$$" "upstream/$name.cc" "$lib" -lz
  mv -f "$bin.tmp.$$" "$bin"
  rm -rf "$bin.tmp.$$.dSYM"
  {
    echo "pin $UPSTREAM_PIN"
    echo "src $ORACLE_SRC"
    echo "harness upstream/$name.cc sha256 $(shasum -a 256 "upstream/$name.cc" | cut -d' ' -f1)"
    echo "cxx $CXX ($CXXV)"
    echo "cxxflags $flags"
    echo "archive $lib"
    echo "built $(date -u +%FT%TZ) $(uname -sm)"
  } > "$bin.BUILD"
  echo "$bin"
}

for n in "${NAMES[@]}"; do
  build_one "$n" "" "$FLAGS" "$LIB"
  [ "$DH" = 1 ] && build_one "$n" .dh "$FLAGS_DH" "$LIB_DH"
done
exit 0
