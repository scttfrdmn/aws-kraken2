# shellcheck shell=bash disable=SC2034
# Shared by scripts/inputpath/preflight.sh and prep.sh (#90, G2 input-path sweep I0-I4; runbook
# docs/inputpath.md, "Pre-flight and inputs"). Sourced after scripts/pin.env and scripts/paths.sh.
# Defines the tool pins (htslib's bgzip, rapidgzip), sha256 helpers, the tool installers and the
# ISA-L check. Nothing here touches AWS except ip_bucket_check.

# ---- pins ---------------------------------------------------------------------------------------
# htslib (bgzip, I4's BGZF re-encode): the 1.24 release tarball. Its sha256 was computed from the
# download on 2026-10-18 and equals the digest GitHub publishes for the release asset.
IP_HTSLIB_VERSION=1.24
IP_HTSLIB_SHA256=28a8de191381c7a97a35675ceac76fa1ea95e7b678d6a2e9d600a7874e4077de
IP_HTSLIB_URL=https://github.com/samtools/htslib/releases/download/$IP_HTSLIB_VERSION/htslib-$IP_HTSLIB_VERSION.tar.bz2
# Only zlib: no libdeflate (its output differs from zlib's), no bz2/lzma/curl/S3 (bgzip needs none).
IP_HTSLIB_CONFIGURE=(--disable-bz2 --disable-lzma --disable-libcurl --disable-gcs --disable-s3 --without-libdeflate)
IP_BGZIP_LEVEL=6
# rapidgzip: the version and the manylinux wheel hashes are lever.sh's (LV_RG_VERSION, LV_RG_HASHES),
# read from that file so the node pin has one home. The macOS wheels below are for the laptop's
# pre-flight only (PyPI's sha256 for rapidgzip 0.14.5, 2026-10-18); no AWS node uses them.
IP_RG_MACOS_HASHES=(
  3d2c764de740c96f0fb3dcd12e1bec3141792d2d0ce056ce19b5f4965921fd68  # cp310 macosx_11_0_arm64
  34bc9e42b5895685dea55ed2da51847e5c831a258f00f175a85970c619aa4b32  # cp311 macosx_11_0_arm64
  1a2aee2f7cb83c7e6e8c60ed5f8cf2faa9abb9f80835f2220664accc7dadfaf7  # cp312 macosx_11_0_arm64
  8e4bfbd8ae6f94126f5927adf0c3f70341538f79c2fea31af413b5c3634baf71  # cp313 macosx_11_0_arm64
  8bf819fd97cc722a54f8aa19c431745fcbb38b61b6f0624a289949649a71c63d  # cp310 macosx_10_15_x86_64
  6cc801e09cb17468e474fa3f0db0e6529ace7ff987671029e5ea64e963011369  # cp311 macosx_10_15_x86_64
  ec34c5d7a7ea09d86af93493ec951b1b585ff7fcf19ea53d815fa07eb35d04bd  # cp312 macosx_10_15_x86_64
  b972746f01bd76a5169029bd26f52cfe2d87f397f579ea3265454545f538ec2a  # cp313 macosx_10_15_x86_64
)
# The I2 decoder-thread sweep (#90); every identity check runs at each of them.
IP_RG_PS=(1 2 4 8 16)
# I3's index: exported at this -P and chunk size (the seek-point spacing depends on -P; measured:
# 1, 4 and 16 give three different indexes for the same file), in rapidgzip's default format.
IP_RG_EXPORT_P=16
IP_RG_CHUNK_KIB=4096
IP_RG_INDEX_FORMAT=indexed_gzip
IP_BUCKET=${AK2_RESULTS_BUCKET_us_west_2:-aws-kraken2-942542972736-us-west-2}
IP_REGION=us-west-2
IP_PREFIX=aws-kraken2/data/inputpath

ip_rg_version() { sed -n 's/^LV_RG_VERSION=\([0-9.]*\).*/\1/p' scripts/g3/lever.sh | head -1; }
ip_rg_linux_hashes() { sed -n '/^LV_RG_HASHES=(/,/^)/p' scripts/g3/lever.sh | grep -oE '^ *[0-9a-f]{64}' | tr -d ' '; }

# ---- helpers ------------------------------------------------------------------------------------
if command -v sha256sum >/dev/null; then
  ip_sha() { sha256sum "$1" | cut -d' ' -f1; }
  ip_sha_in() { sha256sum | cut -d' ' -f1; }
else
  ip_sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
  ip_sha_in() { shasum -a 256 | cut -d' ' -f1; }
fi
ip_size() { wc -c < "$1" | tr -d ' '; }
ip_now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
ip_say() { echo "$(date -u +%H:%M:%SZ) $*"; }
# GNU gzip first on PATH when present (the oracle's rule, scripts/oracle.sh); any gzip -dc decodes
# the same bytes, and the one used is recorded.
ip_gzip_path() {
  if [ -n "${DECOMP_BIN:-}" ]; then PATH="$DECOMP_BIN:$PATH"
  elif [ -x /tmp/gnugzip/inst/bin/gzip ]; then PATH="/tmp/gnugzip/inst/bin:$PATH"; fi
  export PATH
}
# The sha256 of everything that decides what the checks are; prep.sh only uploads after a passing
# pre-flight record with the same value.
ip_checks_sha256() {
  cat scripts/inputpath/lib.sh scripts/inputpath/preflight.sh scripts/g3/lever.sh | ip_sha_in
}
ip_free_gb() { df -Pk "${1:-/}" | awk 'NR==2{printf "%d\n", $4/1048576}'; }

# ---- tools --------------------------------------------------------------------------------------
# ip_bgzip_ensure DIR: htslib $IP_HTSLIB_VERSION's bgzip at DIR/htslib-<v>/bgzip, built from the
# pinned tarball (a mismatching tarball is refused). Sets IP_BGZIP and IP_BGZIP_INFO (JSON).
ip_bgzip_ensure() {
  local d=$1 src tb got cc zv
  src=$d/htslib-$IP_HTSLIB_VERSION; tb=$d/htslib-$IP_HTSLIB_VERSION.tar.bz2
  mkdir -p "$d" || return 1
  if [ ! -x "$src/bgzip" ]; then
    [ -s "$tb" ] || curl -fsSL --retry 3 -o "$tb" "$IP_HTSLIB_URL" || { echo "inputpath: htslib download failed" >&2; return 1; }
    got=$(ip_sha "$tb")
    [ "$got" = "$IP_HTSLIB_SHA256" ] || { echo "inputpath: $tb sha256 $got != pinned $IP_HTSLIB_SHA256" >&2; rm -f "$tb"; return 1; }
    rm -rf "$src"; tar -xjf "$tb" -C "$d" || return 1
    (cd "$src" && ./configure "${IP_HTSLIB_CONFIGURE[@]}" > ../htslib-configure.log 2>&1 && make -j4 bgzip > ../htslib-make.log 2>&1) ||
      { tail -20 "$d/htslib-configure.log" "$d/htslib-make.log" 2>/dev/null; echo "inputpath: htslib build failed (needs a C compiler, make and zlib headers)" >&2; return 1; }
  fi
  [ "$(ip_sha "$tb")" = "$IP_HTSLIB_SHA256" ] || { echo "inputpath: $tb no longer matches the pin" >&2; return 1; }
  "$src/bgzip" --version 2>&1 | head -1 | grep -qx "bgzip (htslib) $IP_HTSLIB_VERSION" ||
    { echo "inputpath: $src/bgzip is not htslib $IP_HTSLIB_VERSION" >&2; return 1; }
  IP_BGZIP=$src/bgzip
  cc=$(grep -m1 '^CC *=' "$src/config.mk" 2>/dev/null | sed 's/^CC *= *//')
  zv=$(python3 -I -c 'import zlib; print(zlib.ZLIB_RUNTIME_VERSION)' 2>/dev/null)
  IP_BGZIP_INFO=$(jq -nc --arg v "$IP_HTSLIB_VERSION" --arg url "$IP_HTSLIB_URL" --arg tsha "$IP_HTSLIB_SHA256" \
    --arg bsha "$(ip_sha "$IP_BGZIP")" --arg cc "$cc" --arg ccv "$(${cc:-cc} --version 2>&1 | head -1)" \
    --arg zlib "$zv" --arg lvl "$IP_BGZIP_LEVEL" --arg cfg "${IP_HTSLIB_CONFIGURE[*]}" \
    '{name:"bgzip (htslib)", version:$v, tarball:$url, tarball_sha256:$tsha, binary_sha256:$bsha,
      configure:($cfg | split(" ")), cc:$cc, cc_version:$ccv, zlib_runtime_python:$zlib, level:($lvl|tonumber)}')
}

# ip_python: a python3 between 3.9 and 3.13 (rapidgzip 0.14.5 has wheels for these).
ip_python() {
  local p v
  for p in python3 python3.13 python3.12 python3.11 python3.10 python3.9; do
    command -v "$p" >/dev/null || continue
    v=$("$p" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
    case "$v" in 3.9|3.1[0-3]) command -v "$p"; return 0 ;; esac
  done
  return 1
}

# ip_rg_ensure DIR: rapidgzip $(ip_rg_version) in a venv at DIR/rg-venv, from a wheel whose sha256
# is pinned (lever.sh's manylinux list, or IP_RG_MACOS_HASHES on macOS). Sets IP_RG, IP_RG_SO and
# IP_RG_INFO (JSON, with the wheel's name, sha256 and which list pinned it).
ip_rg_ensure() {
  local d=$1 py ver req h whl wsha pinlist so
  local -a hs
  ver=$(ip_rg_version); [ -n "$ver" ] || { echo "inputpath: no LV_RG_VERSION in scripts/g3/lever.sh" >&2; return 1; }
  mapfile -t hs < <(ip_rg_linux_hashes; [ "$(uname -s)" = Darwin ] && printf '%s\n' "${IP_RG_MACOS_HASHES[@]}" | cut -d' ' -f1)
  [ "${#hs[@]}" -ge 10 ] || { echo "inputpath: could not read lever.sh's LV_RG_HASHES" >&2; return 1; }
  if [ ! -x "$d/rg-venv/bin/rapidgzip" ]; then
    py=$(ip_python) || { echo "inputpath: need python 3.9-3.13 for rapidgzip $ver" >&2; return 1; }
    rm -rf "$d/rg-venv" "$d/rg-wheels"; mkdir -p "$d" || return 1
    "$py" -m venv "$d/rg-venv" || return 1
    req=$d/rg-requirements.txt
    { printf 'rapidgzip==%s' "$ver"; for h in "${hs[@]}"; do printf ' \\\n    --hash=sha256:%s' "$h"; done; printf '\n'; } > "$req"
    "$d/rg-venv/bin/pip" download -q --no-deps --only-binary=:all: --require-hashes -r "$req" -d "$d/rg-wheels" > "$d/rg-pip.log" 2>&1 &&
      "$d/rg-venv/bin/pip" install -q --no-deps --no-index --only-binary=:all: --require-hashes --find-links "$d/rg-wheels" -r "$req" >> "$d/rg-pip.log" 2>&1 ||
      { tail -5 "$d/rg-pip.log"; echo "inputpath: pip install --require-hashes rapidgzip==$ver failed" >&2; rm -rf "$d/rg-venv"; return 1; }
  fi
  IP_RG=$d/rg-venv/bin/rapidgzip; IP_RG_PY=$d/rg-venv/bin/python
  "$IP_RG" --version 2>&1 | grep -q "version $ver\$" || { echo "inputpath: $IP_RG is not rapidgzip $ver" >&2; return 1; }
  whl=$(find "$d/rg-wheels" -name 'rapidgzip-*.whl' 2>/dev/null | head -1); wsha=""; [ -n "$whl" ] && wsha=$(ip_sha "$whl")
  pinlist=none
  if ip_rg_linux_hashes | grep -qx "$wsha"; then pinlist="scripts/g3/lever.sh LV_RG_HASHES"
  elif printf '%s\n' "${IP_RG_MACOS_HASHES[@]}" | cut -d' ' -f1 | grep -qx "$wsha"; then pinlist="scripts/inputpath/lib.sh IP_RG_MACOS_HASHES (laptop only)"; fi
  [ "$pinlist" != none ] || { echo "inputpath: wheel $whl (sha256 $wsha) is in no pin list" >&2; return 1; }
  so=$(find "$d/rg-venv" -name 'rapidgzip*.so' | head -1); IP_RG_SO=$so
  IP_RG_INFO=$(jq -nc --arg v "$("$IP_RG" --version 2>&1 | head -1)" --arg whl "$(basename "${whl:-}")" --arg wsha "$wsha" \
    --arg pin "$pinlist" --arg so "$(basename "$so")" --arg sosha "$(ip_sha "$so")" \
    --arg isal "$(ip_isal_static "$so")" \
    '{name:"rapidgzip", version:$v, source:("PyPI wheel, pip --require-hashes; pinned by " + $pin), wheel:$whl, wheel_sha256:$wsha,
      extension:$so, extension_sha256:$sosha, isal_static:$isal}')
}

# ip_isal_static FILE: "isal" if the extension carries ISA-L's inflate (its exported symbols, or
# isa-l in the embedded OSS attributions), else "none". (The literal "isal_inflate" also appears
# in an error message compiled into every build, so that alone is not evidence.)
ip_isal_static() {
  python3 -I - "$1" <<'PY'
import re, sys
b = open(sys.argv[1], "rb").read()
sym = len(re.findall(rb"\x00_?isal_inflate_init\x00", b))
att = b"github.com/intel/isa-l" in b
print("isal" if (sym or att) else "none")
PY
}

# ip_isal_runtime RAPIDGZIP GZFILE: rapidgzip -v's "Time spent decoding with ISA-L" for a -P 2
# decode (seconds; 0 when ISA-L is absent or unused).
ip_isal_runtime() {
  "$1" -v -d -c -P 2 "$2" 2>&1 >/dev/null | sed -n 's/.*Time spent decoding with ISA-L *: *\([0-9.e+-]*\) s.*/\1/p' | head -1
}

# ip_isal_wheels DIR: the ISA-L check for every pinned manylinux aarch64 wheel (the Graviton nodes'
# wheels; AL2023's python3 is 3.9), downloaded by hash and inspected statically. Prints one JSON
# array of {wheel, sha256, isal}.
ip_isal_wheels() {
  local d=$1/isal-wheels ver cp out='[]' w s h
  ver=$(ip_rg_version); mkdir -p "$d" || return 1
  for cp in 39 310 311 312 313; do
    "$IP_RG_PY" -m pip download -q --no-deps --only-binary=:all: --platform manylinux_2_17_aarch64 \
      --python-version "${cp:0:1}.${cp:1}" --implementation cp --abi "cp$cp" "rapidgzip==$ver" -d "$d" > /dev/null 2>&1 || continue
  done
  # The positive control: the pinned cp39 x86_64 wheel, which carries ISA-L (so a "none" above is a
  # resolved answer, not a detector that cannot see it).
  "$IP_RG_PY" -m pip download -q --no-deps --only-binary=:all: --platform manylinux_2_27_x86_64 \
    --python-version 3.9 --implementation cp --abi cp39 "rapidgzip==$ver" -d "$d" > /dev/null 2>&1
  for w in "$d"/rapidgzip-*aarch64*.whl "$d"/rapidgzip-*x86_64*.whl; do
    [ -s "$w" ] || continue
    s=$(ip_sha "$w"); h=none
    if ip_rg_linux_hashes | grep -qx "$s"; then
      rm -rf "$d/x"; mkdir -p "$d/x"; python3 -I -m zipfile -e "$w" "$d/x" > /dev/null 2>&1
      h=$(ip_isal_static "$(find "$d/x" -name 'rapidgzip*.so' | head -1)")
    else h="not pinned (sha256 not in LV_RG_HASHES)"; fi
    out=$(jq -c --arg w "$(basename "$w")" --arg s "$s" --arg h "$h" '. + [{wheel:$w, sha256:$s, isal:$h}]' <<< "$out")
  done
  rm -rf "$d"
  echo "$out"
}

# ---- AWS ----------------------------------------------------------------------------------------
# ip_bucket_check: Law 4 before any S3 I/O. The bucket's region must be us-west-2 and, on an EC2
# instance, so must the instance's; records the bucket's Payer. Sets IP_BUCKET_INFO (JSON).
ip_bucket_check() {
  local loc payer ir="" tok
  loc=$(aws s3api get-bucket-location --bucket "$IP_BUCKET" --query LocationConstraint --output text 2>&1) ||
    { echo "inputpath: get-bucket-location $IP_BUCKET failed: $loc" >&2; return 1; }
  [ "$loc" = "$IP_REGION" ] || { echo "inputpath: bucket $IP_BUCKET is in '$loc', not $IP_REGION" >&2; return 1; }
  payer=$(aws s3api get-bucket-request-payment --region "$IP_REGION" --bucket "$IP_BUCKET" --query Payer --output text 2>&1) ||
    { echo "inputpath: get-bucket-request-payment failed: $payer" >&2; return 1; }
  tok=$(curl -s -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null)
  [ -n "$tok" ] && ir=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)
  if [ -n "$ir" ] && [ "$ir" != "$IP_REGION" ]; then echo "inputpath: instance region $ir != bucket region $IP_REGION" >&2; return 1; fi
  IP_BUCKET_INFO=$(jq -nc --arg b "$IP_BUCKET" --arg l "$loc" --arg p "$payer" --arg ir "${ir:-not an EC2 instance}" \
    --arg prof "${AWS_PROFILE:-}" '{bucket:$b, bucket_region:$l, payer:$p, instance_region:$ir, aws_profile:$prof}')
}
