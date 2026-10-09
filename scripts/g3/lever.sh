# shellcheck shell=bash
# shellcheck disable=SC2015,SC2024,SC2034  # A && B || C is meant (C on either failure); logs are the caller's; LV_* are read by the body
# The ladder lever library (#50; the #25 ladder build, WP-6; runbook docs/ladder.md). Shared by
# both arms (stock and ours): every deployment lever a ladder rung switches is one call here, and
# every call records what it did. Sourced by a spec body after the preamble and the clone:
#
#   cd "$W/repo" && . scripts/g3/lever.sh || exit 1
#
# It needs the preamble's helpers (ak2_say, ak2_err, ak2_phase, ak2_req, ak2_push) and refuses to
# load without them. It never turns errexit on, never sets shell options and never exports
# AWS_CONFIG_FILE: a private config is passed to the one command that uses it.
#
# ---- Contract (other code is written against these signatures; change them only with #51) ----
# Every function returns 0 on success. On failure it returns non-zero AND records the failure
# with ak2_err, so the run's exit status carries it even if the body ignores the return code.
# Every function appends one or more JSON lines to $LV_REC (also echoed into the run log as
# "lever {json}" and pushed to out/lever.jsonl), and counts its S3 requests with ak2_req.
# Lever choices are arguments (they travel in the payload), never environment variables.
#
#   lv_nvme single|raid MOUNT
#       Instance-store NVMe as one xfs (noatime, mode 1777) at MOUNT. single: the first
#       instance-store device only (the others are recorded as unused); raid: mdadm RAID0
#       (chunk 512K) over every instance-store device (one device: that device, recorded).
#       Installs mdadm/xfsprogs if missing. Records devices, read_ahead_kb and scheduler (the
#       AMI defaults: lv_nvme changes neither). Fails if the type has no instance store (x8g).
#       Sets LV_NVME=MOUNT.
#   lv_stage_db awscp-default|awscp-classic|s5cmd SRC_URL DEST_DIR [FILE...]
#       A database into DEST_DIR. SRC_URL is s3://BUCKET/PREFIX/ (ending in /); FILE defaults to
#       opts.k2d taxo.k2d hash.k2d, staged one after another. Each object is head-object'ed
#       first (signed, then anonymous: the same signing is used for the copy), its ETag and size
#       recorded in DEST_DIR/SOURCE (TSV: file, etag, bytes, url, mode; pushed), the copy's size
#       checked. awscp-default (stock, S0): `aws s3 cp` exactly as the AMI ships it, with any
#       AWS_CONFIG_FILE the body set removed for the call. awscp-classic (available, not S0):
#       `aws s3 cp` with preferred_transfer_client = classic forced in a private AWS_CONFIG_FILE
#       ($LV_DIR/aws-classic.config). The aws client is recorded (see "aws clients"). s5cmd: lv_s5
#       --numworkers 256 cp --concurrency 128 --part-size 64 (probe (a)'s flags). No ETag check:
#       that is lv_etag's own phase.
#   lv_db_etag DEST_DIR FILE
#       Prints the ETag lv_stage_db recorded for FILE (for lv_etag).
#   lv_etag FILE EXPECTED
#       Opens phase etag-<basename FILE> (the caller opens its next phase afterwards) and runs
#       scripts/lib/etagcheck.py FILE EXPECTED; records its JSON and seconds; fails on mismatch.
#   lv_fetch_inputs serial|lanes<K> default|classic|crt DEST MANIFEST
#       The inputs MANIFEST lists (one s3://BUCKET/PREFIX/FILE per line; # comments and blank
#       lines skipped; one bucket and one prefix; basenames unique) into DEST (NVMe or tmpfs: its
#       fs type is recorded), through scripts/g3/fetch.sh: K lanes (serial = 1), each file checked
#       against its Metadata.sha256. The second argument is the aws client (see "aws clients"),
#       so a lanes rung can keep the client the stock rung used and vary the lane count only.
#       Under `timeout
#       $LV_FETCH_LIMIT` (seconds, default 3600). Fails unless every file verified.
#   lv_upload_start awscp-default|awscp-classic|s5cmd-overlap   (awscp-serial = awscp-classic)
#   lv_upload_enqueue LOCAL S3URL
#   lv_upload_drain
#       One upload session. enqueue computes LOCAL's sha256 on the node and records it (lever
#       line kind upload-enqueue) BEFORE the upload starts. awscp-default (stock) and
#       awscp-classic: enqueue uploads at once (`aws s3 cp` with that client) and returns when it
#       is done. awscp-serial, the name in the first contract, is accepted and recorded as
#       awscp-classic. s5cmd-overlap: start launches
#       one background lane (a subshell, waited on by PID) that uploads the queue in enqueue
#       order with lv_s5 --numworkers 256 cp --concurrency 16 --part-size 64; enqueue returns at
#       once (it fails if the lane has died). drain waits for the lane by PID and fails if the
#       lane failed, any upload failed or any is missing. Every upload is a row of
#       $LV_DIR/uploads.tsv (seq, mode, local, url, bytes, sha256, t_enqueue, t_start, t_end,
#       rc), pushed to out/lever-uploads.tsv at drain; drain records the session summary
#       (overlap_s: upload seconds before drain was called; drain_wait_s). The bucket must be in
#       AK2_ALLOWED_BUCKETS (checked at enqueue). Upload requests count in whatever phase the
#       body is in when the lane makes them. One session at a time. While an s5cmd-overlap
#       session is open the body must not run a bare `wait` (it would wait for the lane, which
#       waits for drain): wait for its own jobs by PID.
#   lv_gunzip_shim gzip|rapidgzip-P<k>
#       gzip: no shim (any earlier shim taken off PATH); records which gzip and its version.
#       rapidgzip-P<k>: rapidgzip 0.14.5 (pip, binary wheel, in $LV_DIR/rg-venv; version
#       checked) and a `gzip` first on PATH (exported) that, for exactly `gzip -dc FILE` (or
#       -d -c, -cd, --decompress --stdout), execs `rapidgzip -d -c -P k FILE`, and execs the real
#       gzip for anything else. Every shim call is a line of $LV_DIR/gzip-shim.calls (t, tool,
#       args). Records both versions and the shim's sha256.
#   lv_s5 ARGS...
#       The only way s5cmd is called. Refuses (rc 126, ak2_err) any s3://BUCKET in any argument
#       whose BUCKET is not in AK2_ALLOWED_BUCKETS, and the `run` subcommand (its commands are in
#       a file it cannot check). Installs s5cmd 2.3.0 on first use (the release tarball, checked
#       against the release's sha256 list). Counts requests with ak2_req, derived from the
#       call: cp download = HeadObject 1 + GetObject ceil(bytes/part); cp upload = PutObject 1
#       (bytes <= part) or CreateMultipartUpload 1 + UploadPart ceil(bytes/part) +
#       CompleteMultipartUpload 1 (part = --part-size MiB, default 50); anything else (or a
#       failed call) = op s5cmd-<sub>[-failed] 1, a lower bound. Records each call.
#
# aws clients (lv_stage_db awscp-*, lv_fetch_inputs, lv_upload_start awscp-*):
#   default  `aws` as shipped: no config override (env -u AWS_CONFIG_FILE for the call).
#   classic  AWS_CONFIG_FILE=$LV_DIR/aws-classic.config: preferred_transfer_client = classic.
#   crt      AWS_CONFIG_FILE=$LV_DIR/aws-crt.config: preferred_transfer_client = crt.
#   The first use of each records a line kind aws-client: the CLI version, the config (none for
#   default) and its content, `aws configure get default.s3.preferred_transfer_client` under it
#   (may be empty: the CLI then uses its built-in default, auto on v2), the instance type, and
#   resolved = classic|crt|unknown with how it was found: the configured value if it names a
#   client; classic for CLI v1 (no CRT); for v2 with auto/empty, the CLI's auto rule
#   (awscrt.s3.is_optimized_for_system()) evaluated with the CLI's own python when the CLI is a
#   python script (AL2023's rpm); otherwise unknown ("could not determine", with the reason).
#
# State: LV_DIR (work dir; default ${W:-$HOME/ak2}/lever; set it before sourcing to move it),
# LV_REC ($LV_DIR/lever.jsonl), LV_NVME, LV_S5 (the s5cmd binary once installed), LV_RG
# (rapidgzip), LV_GZIP_MODE, LV_UP_MODE / LV_UP_PID (the upload session).
# make rehearse seams (AK2_REHEARSE_*, which run.sh refuses in a spec's env, so on AWS they are
# unset): AK2_REHEARSE_NVME=DIR (lv_nvme uses DIR, no device), AK2_REHEARSE_S5CMD=PATH,
# AK2_REHEARSE_RAPIDGZIP=PATH (the binaries are not downloaded; their versions are still checked).
# Request-count basis for the aws CLI (every client: classic's default of 8 MiB parts, assumed for
# CRT too): 8 MiB multipart threshold and
# chunk size: download = HeadObject 1 + GetObject max(1, ceil(bytes/8 MiB)); upload = PutObject 1
# (< 8 MiB) or CreateMultipartUpload 1 + UploadPart ceil(bytes/8 MiB) + CompleteMultipartUpload 1.
# Tested by make lever-test (scripts/tests/lever_test.sh, AL2023 in podman).

[ -n "${LV_LOADED:-}" ] && return 0
for lv_f in ak2_say ak2_err ak2_phase ak2_req ak2_push; do
  declare -F "$lv_f" > /dev/null || { echo "lever.sh: needs the preamble ($lv_f is not defined)" >&2; return 1; }
done
unset lv_f
LV_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LV_DIR=${LV_DIR:-${W:-$HOME/ak2}/lever}
mkdir -p "$LV_DIR" || { ak2_err 1 "lever: cannot create $LV_DIR"; return 1; }
LV_REC=$LV_DIR/lever.jsonl
LV_CLASSIC_CFG=$LV_DIR/aws-classic.config
LV_CRT_CFG=$LV_DIR/aws-crt.config
declare -A LV_CLIENT_DONE=()
LV_S5_VERSION=2.3.0
LV_RG_VERSION=0.14.5
LV_S5_STAGE_ARGS=(--numworkers 256 cp --concurrency 128 --part-size 64)
LV_S5_UP_ARGS=(--numworkers 256 cp --concurrency 16 --part-size 64)
LV_MIB=1048576
LV_S5="" LV_RG="" LV_NVME="" LV_GZIP_MODE="" LV_UP_MODE="" LV_UP_PID="" LV_UP_N=0
: >> "$LV_REC"

# ---- internals ----
lv__now() { date +%s.%3N; }
lv__js() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}
  printf '"%s"' "$s"
}
# lv__rec KIND KEY=VALUE...: one JSON line. KEY:n=number (null if not one), KEY:b=true|false,
# KEY:j=raw JSON (a string if it does not look like an object), KEY=string.
lv__rec() {
  local kind=$1 kv k v out
  shift
  out="{\"kind\":$(lv__js "$kind"),\"t\":$(lv__now)"
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    case $k in
      *:n) k=${k%:n}; [[ $v =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || v=null ;;
      *:b) k=${k%:b}; [ "$v" = true ] || v=false ;;
      *:j) k=${k%:j}; [[ $v == \{*\} ]] || v=$(lv__js "$v") ;;
      *) v=$(lv__js "$v") ;;
    esac
    out="$out,$(lv__js "$k"):$v"
  done
  out="$out}"
  printf '%s\n' "$out" >> "$LV_REC"
  printf 'lever %s\n' "$out" >&2   # stderr: into the log, and out of a caller's $(...)
}
lv__push() { ak2_push "$LV_REC" lever.jsonl > /dev/null 2>&1 || ak2_say "WARN: lever.jsonl push failed"; }
lv__fail() { ak2_err 1 "lever: $*"; return 1; }
lv__allowed() { [ -n "$1" ] && case " $AK2_ALLOWED_BUCKETS " in *" $1 "*) return 0 ;; esac; return 1; }
lv__size() { stat -c%s "$1" 2>/dev/null; }
lv__sha() { sha256sum "$1" | cut -d' ' -f1; }
lv__ceil() { echo $(( ($1 + $2 - 1) / $2 )); }
lv__secs() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", b - a}'; }
lv__gbps() { awk -v a="$1" -v b="$2" -v s="$3" 'BEGIN{d = b - a; if (d > 0) printf "%.3f", s / d / 1e9; else print "null"}'; }
# Requests of one classic aws s3 cp of BYTES (download|upload) against BUCKET.
lv__req_classic() {
  local dir=$1 n=$2 b=$3 c=8388608
  if [ "$dir" = download ]; then
    ak2_req HeadObject 1 "$b"
    ak2_req GetObject $(( n < c ? 1 : (n + c - 1) / c )) "$b"
  elif [ "$n" -lt "$c" ]; then
    ak2_req PutObject 1 "$b"
  else
    ak2_req CreateMultipartUpload 1 "$b"; ak2_req UploadPart "$(lv__ceil "$n" "$c")" "$b"; ak2_req CompleteMultipartUpload 1 "$b"
  fi
}
# lv__client CLIENT: prepare an aws client (default|classic|crt) and record it once. Sets
# LV_AWS, the command prefix that runs `aws` with that client: "${LV_AWS[@]}" s3 cp ...
lv__client() {
  local c=$1 cfg="" got ver res="unknown" how="" py
  case $c in
    default) LV_AWS=(env -u AWS_CONFIG_FILE aws) ;;
    classic) cfg=$LV_CLASSIC_CFG ;;
    crt) cfg=$LV_CRT_CFG ;;
    *) lv__fail "aws client '$c' (default|classic|crt)"; return 1 ;;
  esac
  if [ -n "$cfg" ]; then
    LV_AWS=(env "AWS_CONFIG_FILE=$cfg" aws)
    [ -s "$cfg" ] || printf '[default]\ns3 =\n  preferred_transfer_client = %s\n' "$c" > "$cfg" || { lv__fail "cannot write $cfg"; return 1; }
  fi
  [ -n "${LV_CLIENT_DONE[$c]:-}" ] && return 0
  ver=$("${LV_AWS[@]}" --version 2>&1 | head -1)
  got=$("${LV_AWS[@]}" configure get default.s3.preferred_transfer_client 2>/dev/null)
  case $got in
    classic|crt) res=$got; how="configured" ;;
    *)
      if [[ $ver == aws-cli/1.* ]]; then
        res=classic; how="CLI v1 has no CRT client"
      else
        # $(...), not < <(...): no process substitution in the body's shell (a bare wait waits for it).
        how=$(lv__auto_rule "$AK2_REAL_AWS"); res=${how%%$'\t'*}; how="${how#*$'\t'}; host ${AK2_INSTANCE_TYPE:-?}"
      fi ;;
  esac
  LV_CLIENT_DONE[$c]=1
  lv__rec aws-client client="$c" cli_version="$ver" config="${cfg:-none}" content="$([ -n "$cfg" ] && cat "$cfg")" \
    caller_config="${AWS_CONFIG_FILE:-}" configure_get="$got" instance_type="${AK2_INSTANCE_TYPE:-}" resolved="$res" how="$how"
}
# lv__auto_rule AWS: what AWS CLI v2's `auto` transfer client resolves to on this host, as
# "<classic|crt|unknown><TAB><how>". The CLI must be a python script (AL2023's rpm starts
# "#! /usr/bin/python3 -s") whose awscli/customizations/s3/factory.py resolves auto by
# awscrt.s3.is_optimized_for_system() (checked in the source, so a CLI with another rule gives
# unknown); that call is then made with the CLI's own python.
lv__auto_rule() {
  local aws=$1 py f r
  py=$(head -1 "$aws" 2>/dev/null | sed -n 's/^#! *\([^ ]*python[^ ]*\).*/\1/p')
  if [ -z "$py" ] || [ ! -x "$py" ]; then
    printf 'unknown\tcould not determine: the CLI (%s) is not a python script (a frozen build), so its auto rule cannot be evaluated\n' "$aws"; return 0
  fi
  f=$("$py" -s -c 'import awscli.customizations.s3.factory as m; print(m.__file__)' 2>/dev/null)
  if [ -z "$f" ] || ! grep -q '_resolve_transfer_client_type_for_system' "$f" || ! grep -q 'awscrt.s3.is_optimized_for_system()' "$f"; then
    printf 'unknown\tcould not determine: %s does not resolve auto by awscrt.s3.is_optimized_for_system()\n' "${f:-the CLI factory}"; return 0
  fi
  r=$("$py" -s -c 'import awscrt.s3; print("crt" if awscrt.s3.is_optimized_for_system() else "classic")' 2>/dev/null)
  case $r in
    crt|classic) printf '%s\tauto: awscrt.s3.is_optimized_for_system() (the rule in %s) with the CLI python %s\n' "$r" "$f" "$py" ;;
    *) printf 'unknown\tcould not determine: awscrt.s3 is not importable by %s\n' "$py" ;;
  esac
}
lv__s5_ensure() {
  [ -n "$LV_S5" ] && return 0
  local s5 arch t d v src
  if [ -n "${AK2_REHEARSE_S5CMD:-}" ]; then
    s5=$AK2_REHEARSE_S5CMD; src="rehearsal $AK2_REHEARSE_S5CMD"
  else
    case $(uname -m) in aarch64) arch=arm64 ;; x86_64) arch=64bit ;; *) lv__fail "s5cmd: unsupported machine $(uname -m)"; return 1 ;; esac
    d=$LV_DIR/s5cmd-$LV_S5_VERSION; t=s5cmd_${LV_S5_VERSION}_Linux-$arch.tar.gz
    mkdir -p "$d" || { lv__fail "mkdir $d"; return 1; }
    curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$LV_S5_VERSION/$t" -o "$d/$t" || { lv__fail "s5cmd download failed"; return 1; }
    curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$LV_S5_VERSION/s5cmd_checksums.txt" -o "$d/sums" || { lv__fail "s5cmd checksums download failed"; return 1; }
    grep -q " $t\$" "$d/sums" || { lv__fail "s5cmd: $t not in the release checksums"; return 1; }
    ( cd "$d" && grep " $t\$" sums | sha256sum -c - > /dev/null ) || { lv__fail "s5cmd checksum mismatch"; return 1; }
    tar -xzf "$d/$t" -C "$d" s5cmd || { lv__fail "s5cmd unpack failed"; return 1; }
    s5=$d/s5cmd; src="github.com/peak/s5cmd v$LV_S5_VERSION $t (sha256 checked against s5cmd_checksums.txt)"
  fi
  v=$("$s5" version 2>&1 | head -1)
  [[ $v == *"$LV_S5_VERSION"* ]] || { lv__fail "s5cmd at $s5 reports '$v', want $LV_S5_VERSION"; return 1; }
  LV_S5=$s5
  lv__rec tool name=s5cmd version="$v" path="$s5" sha256="$(lv__sha "$s5")" source="$src"
}
lv__rg_ensure() {
  [ -n "$LV_RG" ] && return 0
  local rg v src
  if [ -n "${AK2_REHEARSE_RAPIDGZIP:-}" ]; then
    rg=$AK2_REHEARSE_RAPIDGZIP; src="rehearsal $AK2_REHEARSE_RAPIDGZIP"
  else
    # probe (c) installed python3-pip first; without it the AMI's venv may lack pip.
    python3 -m venv "$LV_DIR/rg-venv" > /dev/null 2>&1 ||
      { rm -rf "$LV_DIR/rg-venv"; sudo -n dnf install -y -q python3-pip > "$LV_DIR/dnf-pip.log" 2>&1 && python3 -m venv "$LV_DIR/rg-venv"; } ||
      { lv__fail "venv for rapidgzip failed"; return 1; }
    "$LV_DIR/rg-venv/bin/pip" install -q --only-binary=:all: "rapidgzip==$LV_RG_VERSION" > "$LV_DIR/rg-pip.log" 2>&1 ||
      { tail -5 "$LV_DIR/rg-pip.log"; lv__fail "pip install rapidgzip==$LV_RG_VERSION failed"; return 1; }
    rg=$LV_DIR/rg-venv/bin/rapidgzip; src="pip rapidgzip==$LV_RG_VERSION (binary wheel)"
  fi
  v=$("$rg" --version 2>&1 | head -1)
  [[ $v == *"version $LV_RG_VERSION"* ]] || { lv__fail "rapidgzip at $rg reports '$v', want $LV_RG_VERSION"; return 1; }
  LV_RG=$rg
  lv__rec tool name=rapidgzip version="$v" path="$rg" source="$src"
}
# lv__head BUCKET KEY: sets LV_H_ETAG, LV_H_SIZE and LV_H_SIGN ("" signed, or --no-sign-request).
lv__head() {
  local out s
  for s in "" --no-sign-request; do
    # shellcheck disable=SC2086
    out=$(aws s3api head-object $s --bucket "$1" --key "$2" --query '[ETag,ContentLength]' --output text 2>/dev/null)
    ak2_req HeadObject 1 "$1"
    LV_H_ETAG=$(printf '%s' "$out" | awk '{print $1}' | tr -d '"'); LV_H_SIZE=$(printf '%s' "$out" | awk '{print $2}')
    if [ -n "$LV_H_ETAG" ] && [[ $LV_H_SIZE =~ ^[0-9]+$ ]]; then LV_H_SIGN=$s; return 0; fi
  done
  return 1
}

# ---- lv_s5 ----
lv_s5() {
  local a rest b bad="" sub="" prev="" t0 t1 rc
  for a in "$@"; do
    rest=$a
    while [[ $rest == *s3://* ]]; do
      rest=${rest#*s3://}; b=${rest%%/*}
      lv__allowed "$b" || bad="$bad $b"
    done
  done
  # The subcommand: the first word that is not a global flag or a global flag's value.
  for a in "$@"; do
    case $prev in --numworkers|--retry-count|-r|--endpoint-url|--log|--credentials-file|--profile|--request-payer) prev=""; continue ;; esac
    case $a in -*) prev=$a ;; *) sub=$a; break ;; esac
  done
  [ "$sub" = run ] && bad="$bad (the run subcommand: its commands cannot be checked)"
  if [ -n "$bad" ]; then
    echo "ak2: REFUSED s5cmd $* -- undeclared bucket(s):$bad" >&2
    ak2_err 126 "lever: lv_s5 REFUSED s5cmd $* -- undeclared bucket(s):$bad"
    lv__rec s5 args="$*" refused:b=true bad="${bad# }"
    return 126
  fi
  lv__s5_ensure || return 1
  t0=$(lv__now)
  "$LV_S5" "$@"
  rc=$?
  t1=$(lv__now)
  lv__s5_count "$rc" "$sub" "$@"
  lv__rec s5 args="$*" rc:n="$rc" seconds:n="$(lv__secs "$t0" "$t1")" requests="$LV_S5_COUNTED"
  return "$rc"
}
# lv__s5_count RC SUB ARGS...: the derived request counts of one s5cmd call (see the contract).
lv__s5_count() {
  local rc=$1 sub=$2 a seen=0 part=50 prev="" src dst n f b k p
  local -a pos=()
  shift 2
  for a in "$@"; do
    if [ "$seen" = 0 ]; then [ "$a" = "$sub" ] && seen=1; continue; fi
    case $prev in
      --part-size|-p) part=$a; prev=""; continue ;;
      --concurrency|-c|--storage-class|--content-type|--content-encoding|--content-disposition|--cache-control|--expires|--acl|--sse|--sse-kms-key-id|--metadata|--metadata-directive|--exclude|--include|--version-id|--source-region|--destination-region) prev=""; continue ;;
    esac
    case $a in
      --part-size=*) part=${a#--part-size=} ;;
      -*=*) ;;
      -*) prev=$a ;;
      *) pos+=("$a") ;;
    esac
  done
  b=""; for a in "${pos[@]}"; do case $a in s3://*) b=${a#s3://}; b=${b%%/*}; break ;; esac; done
  [[ $part =~ ^[0-9]+$ ]] && [ "$part" -gt 0 ] || part=50
  p=$((part * LV_MIB))
  LV_S5_COUNTED=""
  if [ "$rc" = 0 ] && [ "$sub" = cp ] && [ "${#pos[@]}" = 2 ] && [[ ${pos[0]} != *'*'* ]]; then
    src=${pos[0]} dst=${pos[1]}
    if [[ $src == s3://* ]] && [[ $dst != s3://* ]]; then
      f=$dst; [ -d "$dst" ] && f=$dst/${src##*/}
      n=$(lv__size "$f")
      if [[ $n =~ ^[0-9]+$ ]]; then
        k=$(( n == 0 ? 1 : (n + p - 1) / p ))
        ak2_req HeadObject 1 "$b"; ak2_req GetObject "$k" "$b"
        LV_S5_COUNTED="HeadObject 1 GetObject $k (part ${part} MiB, $n bytes)"; return 0
      fi
    elif [[ $src != s3://* ]] && [[ $dst == s3://* ]]; then
      n=$(lv__size "$src")
      if [[ $n =~ ^[0-9]+$ ]]; then
        if [ "$n" -le "$p" ]; then
          ak2_req PutObject 1 "$b"; LV_S5_COUNTED="PutObject 1 ($n bytes)"
        else
          k=$(lv__ceil "$n" "$p")
          ak2_req CreateMultipartUpload 1 "$b"; ak2_req UploadPart "$k" "$b"; ak2_req CompleteMultipartUpload 1 "$b"
          LV_S5_COUNTED="CreateMultipartUpload 1 UploadPart $k CompleteMultipartUpload 1 (part ${part} MiB, $n bytes)"
        fi
        return 0
      fi
    fi
  fi
  [ -n "$sub" ] || sub=none
  local op="s5cmd-$sub"; [ "$rc" = 0 ] || op="$op-failed"
  ak2_req "$op" 1 "$b"
  LV_S5_COUNTED="$op 1 (a lower bound)"
}

# ---- lv_nvme ----
lv_nvme() {
  local mode=$1 mnt=$2 dev d devs="" unused="" ra="" sch="" note=""
  local -a NV
  case $mode in single|raid) ;; *) lv__fail "lv_nvme: mode '$mode' (single|raid)"; return 1 ;; esac
  [[ $mnt == /* ]] || { lv__fail "lv_nvme: MOUNT must be an absolute path ('$mnt')"; return 1; }
  if [ -n "${AK2_REHEARSE_NVME:-}" ]; then
    mkdir -p "$AK2_REHEARSE_NVME" || { lv__fail "lv_nvme: rehearsal dir $AK2_REHEARSE_NVME"; return 1; }
    LV_NVME=$AK2_REHEARSE_NVME
    lv__rec nvme mode="$mode" mount="$LV_NVME" requested_mount="$mnt" storage="rehearsal directory" fstype="$(stat -f -c %T "$LV_NVME")"
    lv__push; return 0
  fi
  for d in mdadm:mdadm mkfs.xfs:xfsprogs lsblk:util-linux; do
    command -v "${d%%:*}" > /dev/null || sudo -n dnf install -y -q "${d#*:}" > "$LV_DIR/dnf-nvme.log" 2>&1 ||
      { lv__fail "lv_nvme: cannot install ${d#*:}"; return 1; }
  done
  mapfile -t NV < <(lsblk -dpno NAME,MODEL | awk '/Instance Storage/{print $1}')
  [ "${#NV[@]}" -gt 0 ] || { lv__fail "lv_nvme: no instance-store NVMe device on $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)"; return 1; }
  if [ "$mode" = single ] || [ "${#NV[@]}" = 1 ]; then
    dev=${NV[0]}; devs=${dev#/dev/}
    for d in "${NV[@]:1}"; do unused="$unused ${d#/dev/}"; done
    [ "$mode" = raid ] && note="raid requested; one device, so no array"
  else
    for d in "${NV[@]}"; do devs="$devs,${d#/dev/}"; done
    sudo -n mdadm --create /dev/md0 --run --level=0 --chunk=512 --raid-devices="${#NV[@]}" "${NV[@]}" > "$LV_DIR/mdadm.log" 2>&1 ||
      { cat "$LV_DIR/mdadm.log"; lv__fail "lv_nvme: mdadm --create failed"; return 1; }
    dev=/dev/md0; devs="md0$devs"
  fi
  sudo -n mkfs.xfs -f -q "$dev" || { lv__fail "lv_nvme: mkfs.xfs $dev failed"; return 1; }
  sudo -n mkdir -p "$mnt" && sudo -n mount -o noatime "$dev" "$mnt" || { lv__fail "lv_nvme: mount $dev at $mnt failed"; return 1; }
  sudo -n chmod 1777 "$mnt" || { lv__fail "lv_nvme: chmod $mnt failed"; return 1; }
  for d in ${devs//,/ }; do
    ra="$ra $d=$(cat "/sys/block/$d/queue/read_ahead_kb" 2>/dev/null)"
    sch="$sch $d=$(tr -d ' ' < "/sys/block/$d/queue/scheduler" 2>/dev/null)"
  done
  LV_NVME=$mnt
  lv__rec nvme mode="$mode" mount="$mnt" device="$dev" devices="$devs" unused="${unused# }" devices_found:n="${#NV[@]}" \
    model="$(lsblk -dno SIZE,MODEL "${NV[0]}" | tr -s ' ')" fs=xfs mount_opts=noatime read_ahead_kb="${ra# }" scheduler="${sch# }" \
    bytes:n="$(df -B1 --output=size "$mnt" | tail -1 | tr -d ' ')" note="$note"
  lv__push
}

# ---- lv_stage_db / lv_db_etag ----
lv_stage_db() {
  local mode=$1 src=$2 dst=$3 b pfx f t0 t1 n ok=0
  shift 3
  case $mode in awscp-default|awscp-classic|s5cmd) ;; *) lv__fail "lv_stage_db: mode '$mode' (awscp-default|awscp-classic|s5cmd)"; return 1 ;; esac
  [[ $src =~ ^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/(.+/)$ ]] || { lv__fail "lv_stage_db: SRC_URL must be s3://BUCKET/PREFIX/ ('$src')"; return 1; }
  b=${BASH_REMATCH[1]}; pfx=${BASH_REMATCH[2]}
  lv__allowed "$b" || { lv__fail "lv_stage_db: bucket $b is not in AK2_ALLOWED_BUCKETS"; return 1; }
  [ -n "$dst" ] && mkdir -p "$dst" || { lv__fail "lv_stage_db: cannot create '$dst'"; return 1; }
  [ $# -gt 0 ] || set -- opts.k2d taxo.k2d hash.k2d
  if [ "$mode" = s5cmd ]; then lv__s5_ensure || return 1; else lv__client "${mode#awscp-}" || return 1; fi
  for f in "$@"; do
    lv__head "$b" "$pfx$f" || { lv__fail "lv_stage_db: head-object s3://$b/$pfx$f failed (signed and anonymous)"; return 1; }
    t0=$(lv__now)
    if [ "$mode" != s5cmd ]; then
      # shellcheck disable=SC2086
      "${LV_AWS[@]}" s3 cp --only-show-errors $LV_H_SIGN "s3://$b/$pfx$f" "$dst/$f"
      ok=$?
      [ "$ok" = 0 ] && lv__req_classic download "$LV_H_SIZE" "$b"
    else
      # shellcheck disable=SC2086
      lv_s5 $LV_H_SIGN "${LV_S5_STAGE_ARGS[@]}" "s3://$b/$pfx$f" "$dst/$f"
      ok=$?
    fi
    t1=$(lv__now)
    n=$(lv__size "$dst/$f")
    lv__rec stage-db mode="$mode" file="$f" url="s3://$b/$pfx$f" dest="$dst/$f" etag="$LV_H_ETAG" object_bytes:n="$LV_H_SIZE" \
      bytes:n="$n" anonymous:b="$([ -n "$LV_H_SIGN" ] && echo true)" rc:n="$ok" seconds:n="$(lv__secs "$t0" "$t1")" \
      gbps:n="$(lv__gbps "$t0" "$t1" "${n:-0}")" fstype="$(stat -f -c %T "$dst")" \
      client="$([ "$mode" = s5cmd ] && echo "s5cmd ${LV_S5_STAGE_ARGS[*]}" || echo "${LV_AWS[*]} s3 cp (client ${mode#awscp-})")"
    [ "$ok" = 0 ] || { lv__fail "lv_stage_db: $mode copy of s3://$b/$pfx$f failed (rc $ok)"; lv__push; return 1; }
    [ "$n" = "$LV_H_SIZE" ] || { lv__fail "lv_stage_db: $dst/$f has $n bytes, the object $LV_H_SIZE"; lv__push; return 1; }
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$LV_H_ETAG" "$n" "s3://$b/$pfx$f" "$mode" >> "$dst/SOURCE"
  done
  ak2_push "$dst/SOURCE" "lever-db-$(basename "$dst")-SOURCE" > /dev/null 2>&1 || ak2_say "WARN: SOURCE push failed"
  lv__push
}
lv_db_etag() { awk -F'\t' -v f="$2" '$1 == f {e = $2} END {if (e == "") exit 1; print e}' "$1/SOURCE" 2>/dev/null; }

# ---- lv_etag ----
lv_etag() {
  local file=$1 want=$2 t0 t1 j rc
  [ -f "$file" ] && [ -n "$want" ] || { lv__fail "lv_etag: want FILE EXPECTED ('$file' '$want')"; return 1; }
  ak2_phase "etag-$(basename "$file")"
  t0=$(lv__now)
  j=$(python3 "$LV_ROOT/scripts/lib/etagcheck.py" "$file" "$want")
  rc=$?
  t1=$(lv__now)
  lv__rec etag file="$file" expected="$want" ok:b="$([ "$rc" = 0 ] && echo true)" rc:n="$rc" seconds:n="$(lv__secs "$t0" "$t1")" check:j="$j"
  lv__push
  [ "$rc" = 0 ] || { lv__fail "lv_etag: $file does not match ETag $want (etagcheck rc $rc)"; return 1; }
}

# ---- lv_fetch_inputs ----
LV_FETCH_LIMIT=${LV_FETCH_LIMIT:-3600}
lv_fetch_inputs() {
  local mode=$1 cl=$2 dest=$3 man=$4 k u b="" pfx="" ub up t0 t1 rc out ok bytes gets
  local -a files=()
  case $mode in
    serial) k=1 ;;
    lanes[1-9]*) k=${mode#lanes}; [[ $k =~ ^[0-9]+$ ]] || { lv__fail "lv_fetch_inputs: mode '$mode' (serial|lanes<K>)"; return 1; } ;;
    *) lv__fail "lv_fetch_inputs: mode '$mode' (serial|lanes<K>)"; return 1 ;;
  esac
  [ -s "$man" ] || { lv__fail "lv_fetch_inputs: no manifest '$man'"; return 1; }
  while IFS= read -r u || [ -n "$u" ]; do
    u=${u%%$'\r'}
    case $u in ''|'#'*) continue ;; esac
    [[ $u =~ ^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/(.+)/([^/]+)$ ]] || { lv__fail "lv_fetch_inputs: bad manifest line '$u' (s3://BUCKET/PREFIX/FILE)"; return 1; }
    ub=${BASH_REMATCH[1]}; up=${BASH_REMATCH[2]}
    [ -z "$b" ] && { b=$ub; pfx=$up; }
    [ "$ub" = "$b" ] && [ "$up" = "$pfx" ] || { lv__fail "lv_fetch_inputs: one bucket and prefix per manifest (s3://$b/$pfx/ and '$u')"; return 1; }
    files+=("${BASH_REMATCH[3]}")
  done < "$man"
  [ "${#files[@]}" -gt 0 ] || { lv__fail "lv_fetch_inputs: manifest $man lists no objects"; return 1; }
  [ "$(printf '%s\n' "${files[@]}" | sort | uniq -d | wc -l)" = 0 ] || { lv__fail "lv_fetch_inputs: duplicate basenames in $man"; return 1; }
  lv__allowed "$b" || { lv__fail "lv_fetch_inputs: bucket $b is not in AK2_ALLOWED_BUCKETS"; return 1; }
  mkdir -p "$dest" || { lv__fail "lv_fetch_inputs: cannot create $dest"; return 1; }
  lv__client "$cl" || return 1
  out=$LV_DIR/fetch-$(date +%s%N).txt
  t0=$(lv__now)
  "${LV_AWS[@]:0:${#LV_AWS[@]}-1}" timeout -s TERM "$LV_FETCH_LIMIT" "$LV_ROOT/scripts/g3/fetch.sh" "$b" "$pfx" "$dest" "$k" "${files[@]}" > "$out" 2>&1 < /dev/null
  rc=$?
  t1=$(lv__now)
  # fetch.sh prints "<file> <bytes>" per verified file (and the CLI's own error text, if any, as is).
  ok=$(awk 'NF == 2 && $2 ~ /^[0-9]+$/' "$out" | wc -l | tr -d ' ')
  bytes=$(awk 'NF == 2 && $2 ~ /^[0-9]+$/ {s += $2} END {printf "%d", s}' "$out")
  gets=$(awk 'NF == 2 && $2 ~ /^[0-9]+$/ {n += ($2 < 8388608 ? 1 : int(($2 + 8388607) / 8388608))} END {print n + 0}' "$out")
  ak2_req GetObject "$gets" "$b"
  ak2_req HeadObject $((2 * ok)) "$b"   # the cp's own and fetch.sh's head-object (Metadata.sha256)
  grep ERROR "$out" | head -5
  lv__rec fetch-inputs mode="$mode" lanes:n="$k" dest="$dest" fstype="$(stat -f -c %T "$dest")" manifest="$man" prefix="s3://$b/$pfx/" \
    files:n="${#files[@]}" verified:n="$ok" bytes:n="$bytes" rc:n="$rc" seconds:n="$(lv__secs "$t0" "$t1")" \
    gbps:n="$(lv__gbps "$t0" "$t1" "$bytes")" check="sha256 against Metadata.sha256 (scripts/g3/fetch.sh)" \
    client="$cl" client_env="${LV_AWS[*]:0:${#LV_AWS[@]}-1}" limit_s:n="$LV_FETCH_LIMIT"
  lv__push
  [ "$rc" = 0 ] && [ "$ok" = "${#files[@]}" ] ||
    { lv__fail "lv_fetch_inputs: $ok of ${#files[@]} verified (fetch rc $rc$([ "$rc" = 124 ] && echo ", stopped at ${LV_FETCH_LIMIT} s"))"; return 1; }
}

# ---- uploads ----
LV_UP_TSV=$LV_DIR/uploads.tsv
LV_UP_Q=$LV_DIR/upq
lv_upload_start() {
  local mode=$1
  [ "$mode" = awscp-serial ] && mode=awscp-classic   # the first contract's name
  case $mode in awscp-default|awscp-classic|s5cmd-overlap) ;; *) lv__fail "lv_upload_start: mode '$mode' (awscp-default|awscp-classic|s5cmd-overlap)"; return 1 ;; esac
  [ -z "$LV_UP_MODE" ] || { lv__fail "lv_upload_start: a $LV_UP_MODE session is open (lv_upload_drain first)"; return 1; }
  rm -rf "$LV_UP_Q"; mkdir -p "$LV_UP_Q" || { lv__fail "lv_upload_start: cannot create $LV_UP_Q"; return 1; }
  [ -s "$LV_UP_TSV" ] || printf 'seq\tmode\tlocal\turl\tbytes\tsha256\tt_enqueue\tt_start\tt_end\trc\n' > "$LV_UP_TSV"
  LV_UP_N=0 LV_UP_PID="" LV_UP_T0=$(lv__now) LV_UP_SESSION=$(date +%s%N)
  if [ "$mode" != s5cmd-overlap ]; then
    lv__client "${mode#awscp-}" || return 1
    LV_UP_AWS=("${LV_AWS[@]}")   # the session's client, whatever later calls set LV_AWS to
  else
    lv__s5_ensure || return 1
  fi
  LV_UP_MODE=$mode   # before the lane forks: it reads the mode
  if [ "$mode" = s5cmd-overlap ]; then
    ( lv__up_lane ) < /dev/null &
    LV_UP_PID=$!
  fi
  lv__rec upload-start mode="$mode" session="$LV_UP_SESSION" lane_pid="$LV_UP_PID" \
    client="$([ "$mode" = s5cmd-overlap ] && echo "s5cmd ${LV_S5_UP_ARGS[*]}, one background lane" || echo "${LV_AWS[*]} s3 cp (client ${mode#awscp-}), in the caller")"
}
# One upload: lv__up_one SEQ LOCAL URL BYTES SHA TENQ. Appends its row to uploads.tsv.
lv__up_one() {
  local seq=$1 l=$2 url=$3 n=$4 sha=$5 te=$6 b t0 t1 rc
  b=${url#s3://}; b=${b%%/*}
  t0=$(lv__now)
  if [ "$LV_UP_MODE" != s5cmd-overlap ]; then
    "${LV_UP_AWS[@]}" s3 cp --only-show-errors "$l" "$url"
    rc=$?
    [ "$rc" = 0 ] && lv__req_classic upload "$n" "$b"
  else
    lv_s5 "${LV_S5_UP_ARGS[@]}" "$l" "$url"
    rc=$?
  fi
  t1=$(lv__now)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$LV_UP_MODE" "$l" "$url" "$n" "$sha" "$te" "$t0" "$t1" "$rc" >> "$LV_UP_TSV"
  lv__rec upload seq:n="$seq" mode="$LV_UP_MODE" local="$l" url="$url" bytes:n="$n" sha256="$sha" t_enqueue:n="$te" \
    t_start:n="$t0" t_end:n="$t1" rc:n="$rc" session="$LV_UP_SESSION"
  [ "$rc" = 0 ] || { lv__fail "upload of $l to $url failed (rc $rc)"; return 1; }
}
# The overlap lane: uploads $LV_UP_Q/<seq>.job in order until drain writes END with the count.
# It stops if the body's shell is gone (so it cannot outlive a killed run).
lv__up_lane() {
  local i=1 job rc=0 n l url sz sha te
  while :; do
    job=$(printf '%s/%06d.job' "$LV_UP_Q" "$i")
    if [ -e "$job" ]; then
      IFS=$'\t' read -r l url sz sha te < "$job"
      lv__up_one "$i" "$l" "$url" "$sz" "$sha" "$te" || rc=1
      i=$((i + 1)); continue
    fi
    if [ -e "$LV_UP_Q/END" ]; then
      n=$(cat "$LV_UP_Q/END")
      [ "$((i - 1))" = "$n" ] || { lv__fail "upload lane: job $i missing (END says $n)"; rc=1; }
      break
    fi
    kill -0 "$AK2_MAIN_PID" 2> /dev/null || { lv__fail "upload lane: the body's shell is gone after $((i - 1)) uploads"; exit 1; }
    sleep 0.2
  done
  exit "$rc"
}
lv_upload_enqueue() {
  local l=$1 url=$2 b n sha te
  [ -n "$LV_UP_MODE" ] || { lv__fail "lv_upload_enqueue: no session (lv_upload_start first)"; return 1; }
  [ -f "$l" ] || { lv__fail "lv_upload_enqueue: no file '$l'"; return 1; }
  [[ $url =~ ^s3://([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])/.*[^/]$ ]] || { lv__fail "lv_upload_enqueue: S3URL must be s3://BUCKET/KEY ('$url')"; return 1; }
  b=${BASH_REMATCH[1]}
  lv__allowed "$b" || { lv__fail "lv_upload_enqueue: bucket $b is not in AK2_ALLOWED_BUCKETS"; return 1; }
  if [ "$LV_UP_MODE" = s5cmd-overlap ] && ! kill -0 "$LV_UP_PID" 2> /dev/null; then
    lv__fail "lv_upload_enqueue: the upload lane (pid $LV_UP_PID) has died"; return 1
  fi
  te=$(lv__now)
  n=$(lv__size "$l"); sha=$(lv__sha "$l")
  [[ $sha =~ ^[0-9a-f]{64}$ ]] || { lv__fail "lv_upload_enqueue: sha256 of $l failed"; return 1; }
  LV_UP_N=$((LV_UP_N + 1))
  lv__rec upload-enqueue seq:n="$LV_UP_N" mode="$LV_UP_MODE" local="$l" url="$url" bytes:n="$n" sha256="$sha" \
    sha256_seconds:n="$(lv__secs "$te" "$(lv__now)")" session="$LV_UP_SESSION"
  if [ "$LV_UP_MODE" != s5cmd-overlap ]; then
    lv__up_one "$LV_UP_N" "$l" "$url" "$n" "$sha" "$te"
    return
  fi
  local job; job=$(printf '%s/%06d.job' "$LV_UP_Q" "$LV_UP_N")
  printf '%s\t%s\t%s\t%s\t%s\n' "$l" "$url" "$n" "$sha" "$te" > "$job.tmp" && mv "$job.tmp" "$job" ||
    { lv__fail "lv_upload_enqueue: cannot queue $l"; return 1; }
}
lv_upload_drain() {
  local td t1 rc=0 rows bad sum ov
  [ -n "$LV_UP_MODE" ] || { lv__fail "lv_upload_drain: no session"; return 1; }
  td=$(lv__now)
  if [ "$LV_UP_MODE" = s5cmd-overlap ]; then
    echo "$LV_UP_N" > "$LV_UP_Q/END.tmp" && mv "$LV_UP_Q/END.tmp" "$LV_UP_Q/END" || lv__fail "lv_upload_drain: cannot write END"
    wait "$LV_UP_PID"; rc=$?
  fi
  t1=$(lv__now)
  # This session's rows: seq <= N and t_enqueue >= the session start.
  rows=$(awk -F'\t' -v t0="$LV_UP_T0" 'NR > 1 && $7 >= t0' "$LV_UP_TSV" | wc -l | tr -d ' ')
  bad=$(awk -F'\t' -v t0="$LV_UP_T0" 'NR > 1 && $7 >= t0 && $10 != 0' "$LV_UP_TSV" | wc -l | tr -d ' ')
  sum=$(awk -F'\t' -v t0="$LV_UP_T0" 'NR > 1 && $7 >= t0 {s += $9 - $8} END {printf "%.3f", s}' "$LV_UP_TSV")
  ov=$(awk -F'\t' -v t0="$LV_UP_T0" -v td="$td" 'NR > 1 && $7 >= t0 {e = ($9 < td ? $9 : td); if (e > $8) s += e - $8} END {printf "%.3f", s}' "$LV_UP_TSV")
  lv__rec upload-drain mode="$LV_UP_MODE" session="$LV_UP_SESSION" enqueued:n="$LV_UP_N" uploaded:n="$rows" failed:n="$bad" \
    lane_rc:n="$rc" bytes:n="$(awk -F'\t' -v t0="$LV_UP_T0" 'NR > 1 && $7 >= t0 {s += $5} END {printf "%d", s}' "$LV_UP_TSV")" \
    upload_s:n="$sum" overlap_s:n="$ov" t_drain:n="$td" drain_wait_s:n="$(lv__secs "$td" "$t1")"
  ak2_push "$LV_UP_TSV" lever-uploads.tsv > /dev/null 2>&1 || ak2_say "WARN: uploads.tsv push failed"
  lv__push
  local m=$LV_UP_MODE
  LV_UP_MODE="" LV_UP_PID=""
  [ "$rc" = 0 ] && [ "$rows" = "$LV_UP_N" ] && [ "$bad" = 0 ] ||
    { lv__fail "lv_upload_drain: $m: $rows of $LV_UP_N uploaded, $bad failed, lane rc $rc"; return 1; }
}

# ---- lv_gunzip_shim ----
lv_gunzip_shim() {
  local mode=$1 k real gb=$LV_DIR/gzbin p
  # PATH without the shim directory.
  p=":$PATH:"; p=${p//:$gb:/:}; p=${p#:}; p=${p%:}
  case $mode in
    gzip)
      export PATH="$p"; hash -r
      LV_GZIP_MODE=gzip
      lv__rec gunzip-shim mode=gzip gzip="$(command -v gzip)" gzip_version="$(gzip --version 2>&1 | head -1)" shim:b=false
      lv__push; return 0 ;;
    rapidgzip-P*) k=${mode#rapidgzip-P}; [[ $k =~ ^[1-9][0-9]*$ ]] || { lv__fail "lv_gunzip_shim: mode '$mode' (gzip|rapidgzip-P<k>)"; return 1; } ;;
    *) lv__fail "lv_gunzip_shim: mode '$mode' (gzip|rapidgzip-P<k>)"; return 1 ;;
  esac
  real=$(PATH="$p" command -v gzip) || { lv__fail "lv_gunzip_shim: no real gzip on PATH"; return 1; }
  lv__rg_ensure || return 1
  mkdir -p "$gb" || { lv__fail "lv_gunzip_shim: cannot create $gb"; return 1; }
  cat > "$gb/gzip.tmp" << LVSHIM
#!/bin/bash
# lever.sh gunzip shim ($mode): \`gzip -dc FILE\` (upstream's kraken2 wrapper) -> rapidgzip; all else -> the real gzip.
d=0 c=0 o=0 f=()
for a in "\$@"; do
  case \$a in
    -dc|-cd) d=1; c=1 ;;
    -d|--decompress|--uncompress) d=1 ;;
    -c|--stdout|--to-stdout) c=1 ;;
    -*) o=1 ;;
    *) f+=("\$a") ;;
  esac
done
if [ \$d = 1 ] && [ \$c = 1 ] && [ \$o = 0 ] && [ \${#f[@]} = 1 ]; then
  printf '%s\trapidgzip\t%s\n' "\$(date +%s.%3N)" "\$*" >> "$LV_DIR/gzip-shim.calls"
  exec "$LV_RG" -d -c -P $k "\${f[0]}"
fi
printf '%s\tgzip\t%s\n' "\$(date +%s.%3N)" "\$*" >> "$LV_DIR/gzip-shim.calls"
exec "$real" "\$@"
LVSHIM
  chmod 0555 "$gb/gzip.tmp" && mv -f "$gb/gzip.tmp" "$gb/gzip" || { lv__fail "lv_gunzip_shim: cannot install $gb/gzip"; return 1; }
  export PATH="$gb:$p"; hash -r
  [ "$(command -v gzip)" = "$gb/gzip" ] || { lv__fail "lv_gunzip_shim: the shim is not first on PATH"; return 1; }
  LV_GZIP_MODE=$mode
  lv__rec gunzip-shim mode="$mode" threads:n="$k" shim:b=true shim_path="$gb/gzip" shim_sha256="$(lv__sha "$gb/gzip")" \
    rapidgzip="$LV_RG" rapidgzip_version="$("$LV_RG" --version 2>&1 | head -1)" gzip="$real" gzip_version="$("$real" --version 2>&1 | head -1)" \
    calls="$LV_DIR/gzip-shim.calls"
  lv__push
}

LV_LOADED=1
readonly LV_LOADED LV_ROOT LV_REC LV_CLASSIC_CFG LV_CRT_CFG LV_S5_VERSION LV_RG_VERSION LV_MIB LV_UP_TSV LV_UP_Q
readonly -a LV_S5_STAGE_ARGS LV_S5_UP_ARGS
# The guard and its counting cannot be redefined by the body.
readonly -f lv_s5 lv__s5_count lv__allowed lv__s5_ensure
case $- in *e*) ak2_err 97 "lever: errexit is on after sourcing lever.sh (\$-=$-)" ;; esac
ak2_say "lever.sh loaded from $LV_ROOT (LV_DIR=$LV_DIR; s5cmd $LV_S5_VERSION, rapidgzip $LV_RG_VERSION pins)"
