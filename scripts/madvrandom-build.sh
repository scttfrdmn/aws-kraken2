#!/usr/bin/env bash
# Build kraken2-madvrandom (#23, docs/g2.md): upstream at the pin plus upstream/madvrandom.patch
# (madvise(MADV_RANDOM) on every MMapFile mapping), a DIAGNOSTIC build for the H-knee sweep's
# regime (c). Never the oracle, never the baseline: the pristine checkout and the oracle build
# (scripts/oracle-build.sh) are untouched. The source is exported from the pinned commit with
# `git archive` into its own directory, patched there, and installed into
# .oracle/<pin>-madvrandom/. Idempotent. Prints the install dir.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/pin.env
. scripts/paths.sh
PATCH="$PWD/upstream/madvrandom.patch"
SRC="$ORACLE_SRC-madvrandom"
DST="$ORACLE_DST-madvrandom"
PSHA=$( (sha256sum "$PATCH" 2>/dev/null || shasum -a 256 "$PATCH") | cut -d' ' -f1)
if [ -x "$DST/classify" ] && [ -x "$DST/kraken2" ] && grep -qx "patch_sha256 $PSHA" "$DST/BUILD" 2>/dev/null; then
  echo "$DST"; exit 0
fi
# The pristine checkout supplies the pinned tree (cloned by oracle-build.sh if missing).
scripts/oracle-build.sh >/dev/null
test "$(git -C "$ORACLE_SRC" rev-parse HEAD)" = "$UPSTREAM_PIN"
rm -rf "$SRC" "$DST"
mkdir -p "$SRC"
git -C "$ORACLE_SRC" archive "$UPSTREAM_PIN" | tar -x -C "$SRC"
(cd "$SRC" && patch -p1 --forward --quiet < "$PATCH")
grep -q MADV_RANDOM "$SRC/src/mmap_file.cc"
. scripts/cxx.sh
LOG="$(dirname "$DST")/build-$UPSTREAM_PIN-madvrandom.log"
(cd "$SRC" && ./install_kraken2.sh "$DST") >"$LOG" 2>&1 || { tail -30 "$LOG" >&2; exit 1; }
{
  echo "pin $UPSTREAM_PIN"
  echo "variant madvrandom (diagnostic; not the oracle or the baseline)"
  echo "patch upstream/madvrandom.patch"
  echo "patch_sha256 $PSHA"
  echo "cxx $CXX ($("$CXX" --version | head -1))"
  echo "version $("$DST/kraken2" --version | head -1)"
  echo "built $(date -u +%FT%TZ) $(uname -sm)"
} > "$DST/BUILD"
echo "$DST"
