#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2024  # A && B || C is meant; the log is ours
# rapidgzip 0.14.5 from its PyPI sdist with rpmalloc off (docs/probes.md, "The rapidgzip fix
# probe"): one recipe, used by probe (h) and by the input-path sweep (#90), so both run the same
# artefact. Run on the node (AL2023 aarch64; also runs in the make rehearse container).
#
#   scripts/g3/rg-build.sh OUTDIR [S3_CACHE_PREFIX]
#
# Recipe (everything pinned; the recipe's sha256 is the cache key):
#   - sdist rapidgzip-0.14.5.tar.gz, sha256 RG_SDIST_SHA256 (PyPI's JSON API, 2026-10-18), by pip
#     download --no-binary --require-hashes;
#   - build deps by --require-hashes: setuptools 71.1.0, wheel 0.44.0, Cython 3.0.12 (pure-python
#     wheels; the sdist's pyproject wants setuptools >= 61.2, < 72, wheel, cython >= 3, < 3.1);
#   - AL2023's gcc-c++ and python3-devel (dnf; versions recorded); pip wheel --no-build-isolation;
#   - RAPIDGZIP_BUILD_RPMALLOC=disable, RAPIDGZIP_BUILD_ISAL=disable. ISA-L cannot be on: 0.14.5's
#     setup.py builds it only on x86_64 (canBuildIsal = nasm and machine in x86_64/AMD64) and its
#     CMake forces WITH_ISAL OFF on ARM ("ARM compilation not yet implemented"), so on aarch64 the
#     PyPI wheel has no ISA-L either. Against that wheel this build differs by rpmalloc off and a
#     different toolchain (AL2023's gcc 11.5 and system python, not the manylinux one): not a
#     single-lever change.
# Verification, on the built .so: no rpmalloc functions (nm -D; the PyPI wheel exports 23), no ISA-L symbols
# (isal_inflate), `rapidgzip --oss-attributions` lists neither, and the version is 0.14.5. A
# build that fails verification is a failure.
# Cache: S3_CACHE_PREFIX/<recipe sha256>/{<wheel>, build.json}. A hit downloads the wheel and
# checks its sha256 against the cached build.json; a miss builds and uploads both.
# stdout: the build record (one JSON line, "rg-build {json}"); stderr: progress. OUTDIR gets the
# wheel, build.json and build.log. Exit 0 with a verified wheel in OUTDIR, else non-zero.
# make rehearse seam: AK2_REHEARSE_RGBUILD_SDIST_SHA256 (a wrong pin: the build must then fail).
set +e
set -uo pipefail
OUT=${1:?OUTDIR}; CACHE=${2:-}
RG_VERSION=0.14.5
RG_SDIST_SHA256=${AK2_REHEARSE_RGBUILD_SDIST_SHA256:-faed46013a1a62a5193c49615a896683ea5c14ed4744bcb4bd1869b1420551d8}
DEPS=(
  "setuptools==71.1.0 --hash=sha256:33874fdc59b3188304b2e7c80d9029097ea31627180896fb549c578ceb8a0855"
  "wheel==0.44.0 --hash=sha256:2376a90c98cc337d18623527a97c31797bd02bad0033d41547043a1cbfbe448f"
  "cython==3.0.12 --hash=sha256:0038c9bae46c459669390e53a1ec115f8096b2e4647ae007ff1bf4e6dee92806"
)
FLAGS="RAPIDGZIP_BUILD_RPMALLOC=disable RAPIDGZIP_BUILD_ISAL=disable"
say() { echo "rg-build: $*" >&2; }
mkdir -p "$OUT" || exit 2
LOG=$OUT/build.log; : > "$LOG"
T0=$(date +%s)
REC() {  # status note: the record, to stdout and OUTDIR/build.json
  jq -nc --arg status "$1" --arg note "$2" --arg v "$RG_VERSION" --arg sdist "$RG_SDIST_SHA256" --arg flags "$FLAGS" \
    --arg deps "${DEPS[*]}" --arg recipe "${RECIPE:-}" --arg gcc "${GCCV:-}" --arg py "${PYV:-}" --arg whl "${WHL:+$(basename "$WHL")}" \
    --arg wsha "${WSHA:-}" --arg so "${SOSHA:-}" --argjson s "$(( $(date +%s) - T0 ))" --arg cache "${CACHE_STATE:-none}" \
    --arg puts "${CACHE_PUTS:-0}" --arg rpm "${N_RPM:-}" --arg isal "${N_ISAL:-}" --arg oss "${OSS:-}" --arg rv "${RV:-}" \
    '{kind:"rg-build", status:$status, note:$note, version:$v, sdist_sha256:$sdist, flags:$flags, build_deps:$deps, recipe_sha256:$recipe,
      gcc:$gcc, python:$py, wheel:$whl, wheel_sha256:$wsha, extension_sha256:$so, seconds:$s, cache:$cache, cache_puts:($puts|tonumber),
      rpmalloc_symbols:($rpm|tonumber? // null), isal_symbols:($isal|tonumber? // null), oss_attributions:$oss, reports:$rv}' | tee "$OUT/build.json.tmp"
  mv -f "$OUT/build.json.tmp" "$OUT/build.json"
}
die() { say "FAILED: $*"; REC failed "$*" | sed 's/^/rg-build /'; exit 1; }

sudo -n dnf install -y -q gcc-c++ python3-devel binutils >> "$LOG" 2>&1 || die "dnf gcc-c++ python3-devel failed"
GCCV=$(gcc --version | head -1); PYV=$(python3 -V 2>&1)
# The recipe: this script, the pins, the toolchain. Same recipe, same cache entry.
RECIPE=$( { cat "$0"; echo "$RG_SDIST_SHA256 $FLAGS ${DEPS[*]} $GCCV $PYV $(uname -m)"; } | sha256sum | cut -d' ' -f1)
VERIFY() {  # VENV: install the wheel into it and check what it is
  local venv=$1 so
  "$venv/bin/pip" install -q --no-deps --no-index --force-reinstall "$WHL" >> "$LOG" 2>&1 || return 1
  so=$(find "$venv" -name 'rapidgzip*.so' | head -1); [ -n "$so" ] || return 1
  SOSHA=$(sha256sum "$so" | cut -d' ' -f1)
  # rpmalloc's own functions (rpmalloc_*, _rpmalloc_*, rpfree, ...), not the unused attribution
  # constant thirdparty::rpmalloc::fullLicense; the PyPI 0.14.5 aarch64 wheel exports 23 of them.
  N_RPM=$(nm -D --defined-only "$so" 2> /dev/null | awk '{print $NF}' | grep -c -E '^(_?rpmalloc|rpfree|rprealloc|rpcalloc|rpaligned|rpmemalign|rpposix)')
  N_ISAL=$(nm -D "$so" 2> /dev/null | grep -c -E 'isal_inflate|isal_deflate')
  OSS=$("$venv/bin/rapidgzip" --oss-attributions 2>&1 | grep -E '^# ' | tr '\n' ' ')
  RV=$("$venv/bin/rapidgzip" --version 2>&1 | head -1)
  [ "$N_RPM" = 0 ] && [ "$N_ISAL" = 0 ] && [[ $OSS != *rpmalloc* ]] && [[ $OSS != *ISA-L* ]] && [[ $RV == *"version $RG_VERSION"* ]]
}
V=$OUT/venv; rm -rf "$V"
python3 -m venv "$V" >> "$LOG" 2>&1 || die "venv failed"
CACHE_STATE=miss
if [ -n "$CACHE" ] && aws s3 cp --only-show-errors "$CACHE/$RECIPE/build.json" "$OUT/cached.json" >> "$LOG" 2>&1; then
  cw=$(jq -r .wheel "$OUT/cached.json"); cs=$(jq -r .wheel_sha256 "$OUT/cached.json")
  if aws s3 cp --only-show-errors "$CACHE/$RECIPE/$cw" "$OUT/$cw" >> "$LOG" 2>&1 && [ "$(sha256sum "$OUT/$cw" | cut -d' ' -f1)" = "$cs" ]; then
    WHL=$OUT/$cw; WSHA=$cs; CACHE_STATE=hit
    VERIFY "$V" || die "the cached wheel $cw fails verification (rpmalloc $N_RPM, isal $N_ISAL, '$RV')"
    say "cache hit $CACHE/$RECIPE/$cw"
    REC ok "cache hit" | sed 's/^/rg-build /'; exit 0
  fi
  say "cache entry incomplete or wrong sha256; rebuilding"
fi
REQ=$OUT/build-requirements.txt; printf '%s\n' "${DEPS[@]}" > "$REQ"
"$V/bin/pip" install -q --require-hashes --only-binary=:all: -r "$REQ" >> "$LOG" 2>&1 || die "build deps (--require-hashes) failed"
SD=$OUT/sdist; mkdir -p "$SD"
printf 'rapidgzip==%s --hash=sha256:%s\n' "$RG_VERSION" "$RG_SDIST_SHA256" > "$OUT/sdist-requirements.txt"
"$V/bin/pip" download -q --no-deps --no-binary=:all: --require-hashes -r "$OUT/sdist-requirements.txt" -d "$SD" >> "$LOG" 2>&1 ||
  die "sdist download --require-hashes failed (sha256 $RG_SDIST_SHA256)"
say "building rapidgzip $RG_VERSION from $(basename "$(find "$SD" -name '*.tar.gz' | head -1)") with $FLAGS ($GCCV)"
env RAPIDGZIP_BUILD_RPMALLOC=disable RAPIDGZIP_BUILD_ISAL=disable MAKEFLAGS="-j$(nproc)" \
  "$V/bin/pip" wheel -v --no-deps --no-build-isolation --no-index --find-links "$SD" -w "$OUT" "rapidgzip==$RG_VERSION" >> "$LOG" 2>&1 ||
  die "pip wheel failed (tail of build.log: $(tail -3 "$LOG" | tr '\n' ' ' | cut -c1-300))"
grep -q 'rpmalloc: disable' "$LOG" && grep -q 'isal: disable' "$LOG" || die "setup.py did not report rpmalloc and isal disabled"
WHL=$(find "$OUT" -maxdepth 1 -name "rapidgzip-$RG_VERSION-*.whl" | head -1); [ -n "$WHL" ] || die "no wheel"
WSHA=$(sha256sum "$WHL" | cut -d' ' -f1)
VERIFY "$V" || die "verification failed: rpmalloc symbols $N_RPM, isal symbols $N_ISAL, oss '$OSS', '$RV'"
REC ok "built" > /dev/null
if [ -n "$CACHE" ]; then
  CACHE_PUTS=1
  aws s3 cp --only-show-errors "$WHL" "$CACHE/$RECIPE/$(basename "$WHL")" >> "$LOG" 2>&1 && CACHE_PUTS=2 &&
    aws s3 cp --only-show-errors "$OUT/build.json" "$CACHE/$RECIPE/build.json" >> "$LOG" 2>&1 && CACHE_STATE=stored || CACHE_STATE="store failed"
fi
REC ok "built" | sed 's/^/rg-build /'
exit 0
