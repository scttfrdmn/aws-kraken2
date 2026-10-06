#!/usr/bin/env bash
# Build oracle harnesses (upstream/<name>.cc) against upstream's own sources at the pin, with the
# compiler choice of scripts/oracle-build.sh (scripts/cxx.sh) and the CXXFLAGS and LDFLAGS that
# upstream's src/Makefile computes (read from that Makefile, not restated here).
#
# Usage: scripts/harness-build.sh [-v lp|dh|lp,dh] [name...]
#   name...  harnesses to build (default: every upstream/*.cc)
#   -v       variants (default lp):
#              lp  <name>     upstream's default flags, which include -DLINEAR_PROBING (the oracle)
#              dh  <name>.dh  the same flags minus -DLINEAR_PROBING (upstream's double-hashing build)
# stdout: one absolute path per built binary, in argument order (each <name> before <name>.dh).
#
# Layout (all in *this* checkout, since harness sources differ per branch):
#   .oracle/harness/<pin>/<name>[.dh]          the binaries
#   .oracle/harness/<pin>/<name>[.dh].BUILD    per-binary record: pin, upstream tree state,
#                                              harness source sha256, compiler, flags, archive
#   .oracle/harness/<pin>/lib-<variant>-<key>/libkraken2.a
#       upstream's library code (every src/*.cc without a main, minus the libtax shim), compiled
#       once; <key> hashes the pin, compiler version, flags and every upstream src/*.{h,cc}, so a
#       change in any of them builds a new archive.
# The shared upstream checkout (scripts/paths.sh) is only read: it must be at the pin with no
# tracked modifications, and every object is written into our own directory.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
. scripts/paths.sh
. scripts/pin-identity.sh
pin_identity || { echo "$(basename "$0"): cannot establish the upstream pin identity" >&2; exit 1; }
usage() { echo "usage: $0 [-v lp|dh|lp,dh] [name...]" >&2; exit 2; }
VARIANTS=lp
NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -v) [ $# -ge 2 ] || usage; VARIANTS=$2; shift 2 ;;
    -*) usage ;;
    *) NAMES+=("$1"); shift ;;
  esac
done
case "$VARIANTS" in lp|dh|lp,dh|dh,lp) ;; *) usage ;; esac
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
# Ask upstream's Makefile for its flags rather than restating them.
MK=$(mktemp); trap 'rm -f "$MK"' EXIT
printf 'print-%%:\n\t@echo $($*)\n' > "$MK"
FLAGS_LP=$(make -s -C "$SRC" -f Makefile -f "$MK" print-CXXFLAGS)
LDFLAGS=$(make -s -C "$SRC" -f Makefile -f "$MK" print-LDFLAGS)
case " $FLAGS_LP " in
  *" -DLINEAR_PROBING "*) ;;
  *) echo "harness-build: upstream CXXFLAGS lack -DLINEAR_PROBING ($FLAGS_LP); the dh variant would equal the oracle" >&2; exit 1 ;;
esac
FLAGS_DH=$(echo " $FLAGS_LP " | sed 's/ -DLINEAR_PROBING / /g; s/^ //; s/ $//')
CXXV=$("$CXX" --version | head -1)
SRCSUM=$(cat "$SRC"/*.h "$SRC"/*.cc | shasum -a 256 | cut -d' ' -f1)

OUT="$PWD/.oracle/harness/$UPSTREAM_PIN"
mkdir -p "$OUT"

# archive VARIANT FLAGS: echo the path of the upstream library archive, building it if needed.
archive() {
  local v=$1 flags=$2 key dir
  key=$(printf '%s\n%s\n%s\n%s\n' "$UPSTREAM_PIN" "$CXXV" "$flags" "$SRCSUM" | shasum -a 256 | cut -c1-12)
  dir="$OUT/lib-$v-$key"
  if [ ! -s "$dir/libkraken2.a" ]; then
    rm -rf "$dir.tmp"; mkdir -p "$dir.tmp"
    local f b objs=() pids=() p
    for f in "$SRC"/*.cc; do
      b=$(basename "$f" .cc)
      grep -q '^int main' "$f" && continue   # programs, not library code
      [ "$b" = libtax ] && continue          # Python-facing shared-library shim
      "$CXX" $flags -I"$SRC" -c "$f" -o "$dir.tmp/$b.o" 2>>"$dir.tmp/build.log" &
      pids+=($!); objs+=("$dir.tmp/$b.o")
    done
    for p in "${pids[@]}"; do wait "$p" || { tail -30 "$dir.tmp/build.log" >&2; exit 1; }; done
    ar rcs "$dir.tmp/libkraken2.a" "${objs[@]}"
    printf 'pin %s\ncxx %s (%s)\ncxxflags %s\nsrc_sha256 %s\n' "$UPSTREAM_PIN" "$CXX" "$CXXV" "$flags" "$SRCSUM" > "$dir.tmp/KEY"
    rm -rf "$dir"; mv "$dir.tmp" "$dir"
  fi
  echo "$dir/libkraken2.a"
}

build_one() {  # name suffix flags lib
  local name=$1 sfx=$2 flags=$3 lib=$4 bin="$OUT/$1$2" v
  "$CXX" $flags -I"$SRC" -o "$bin.tmp.$$" "upstream/$name.cc" "$lib" $LDFLAGS -lz
  mv -f "$bin.tmp.$$" "$bin"
  rm -rf "$bin.tmp.$$.dSYM"
  {
    echo "pin $UPSTREAM_SHA"
    echo "pin_describe $UPSTREAM_DESCRIBE"
    echo "src $ORACLE_SRC (HEAD $HEAD, no tracked modifications; src sha256 $SRCSUM)"
    echo "harness upstream/$name.cc sha256 $(shasum -a 256 "upstream/$name.cc" | cut -d' ' -f1)"
    v=${sfx#.}; echo "variant ${v:-lp}"
    echo "cxx $CXX ($CXXV)"
    echo "cxxflags $flags"
    echo "ldflags $LDFLAGS -lz"
    echo "archive $lib"
    echo "built $(date -u +%FT%TZ) $(uname -sm)"
  } > "$bin.BUILD"
  echo "$bin"
}

LIB_LP=""; LIB_DH=""
case ",$VARIANTS," in *,lp,*) LIB_LP=$(archive lp "$FLAGS_LP") ;; esac
case ",$VARIANTS," in *,dh,*) LIB_DH=$(archive dh "$FLAGS_DH") ;; esac
for n in "${NAMES[@]}"; do
  if [ -n "$LIB_LP" ]; then build_one "$n" "" "$FLAGS_LP" "$LIB_LP"; fi
  if [ -n "$LIB_DH" ]; then build_one "$n" .dh "$FLAGS_DH" "$LIB_DH"; fi
done
