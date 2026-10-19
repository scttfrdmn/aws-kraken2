#!/usr/bin/env bash
# make inputpath-preflight [PART=local|inputs] [DB=viral|standard8]  (#90; docs/inputpath.md,
# "Pre-flight and inputs"). The no-spend checks that come before the input-path sweep's first AWS
# session. Upstream's kraken2 wrapper at the pin is the engine throughout.
#
#   PART=local (default; CI): the Viral DB and the G1 oracle's sample S1 (SRR062634_200000, both
#     mates, paired and single-end). Builds its own BGZF re-encode and rapidgzip index of S1 in a
#     fresh /tmp directory, then checks:
#       devfd     the wrapper reads /dev/fd paths from <(...) for both mates (a pipe cannot seek,
#                 and the wrapper's format detection skips non-regular files) and its outputs equal
#                 I0's; the negative control (the same /dev/fd paths with --gzip-compressed) must
#                 come out different, showing the comparison can see a wrong input path;
#       gzflag    no I2-I4 command line passes --gzip-compressed (a static scan of the sweep's
#                 files; the commands built here are asserted as they are built);
#       identity  rapidgzip (lever.sh's pin) decodes every .gz, BGZF and indexed .gz to the same
#                 sha256 as gzip -dc, at every -P of the I2 sweep (IP_RG_PS), with exit 0;
#       arms      I1-I4 (at every -P) give --output and --report byte-identical to I0;
#       g1        I0's --output and --report equal the latest G1 oracle record's upstream hashes for
#                 the same input (results/g1/oracle-viral-*, cases pe-default-gz-S1, se-default-S1);
#       isal      ISA-L in the rapidgzip used here and in every pinned manylinux aarch64 wheel
#                 (recorded; the node's answer goes in the sweep's manifests).
#   PART=inputs: the sweep's own inputs (scripts/inputpath/inputs.tsv, written by make inputpath-prep).
#     Every object is found locally (INPUTPATH_DIR, then .cache/reads) or fetched from the project
#     bucket into a fresh /tmp directory, its sha256 checked against the table, and every
#     decodable kind put through the identity check. With DB=viral|standard8, also runs I0-I4 (at
#     PREFLIGHT_PS, default 4) on the pe and se roles and records I0's hashes (the reference the
#     node's I0 must equal), comparing them with a G1 oracle record when one exists for the input.
#
# Env: PREFLIGHT_THREADS (kraken2 --threads, default 8), PREFLIGHT_PS (the -P values the kraken2
#      arms run at; default all of IP_RG_PS for PART=local, 4 for PART=inputs), INPUTPATH_TOOLS
#      (tool cache, default /tmp/ak2-inputpath-tools), INPUTPATH_DIR (where prep left its outputs),
#      INPUTPATH_KEEP=1 (keep the /tmp work directory), DECOMP_BIN (as make oracle).
# Writes results/inputpath/preflight-<part>-<UTC>-<commit>/{manifest.json,checks.tsv,runs.tsv,run.log}.
# Exits non-zero if any check fails.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. scripts/pin.env
. scripts/paths.sh
. scripts/ak2.env
. scripts/pin-identity.sh
. scripts/inputpath/lib.sh
export AWS_PROFILE

PART=${1:-${PART:-local}}
case "$PART" in local|inputs) ;; *) echo "usage: $0 [local|inputs]" >&2; exit 2 ;; esac
DBSEL=${DB:-}; [ "$PART" = local ] && DBSEL=${DBSEL:-viral}
case "$DBSEL" in ""|viral|standard8) ;; *) echo "inputpath-preflight: DB=$DBSEL: want viral or standard8" >&2; exit 2 ;; esac
TH=${PREFLIGHT_THREADS:-8}
if [ "$PART" = local ]; then read -r -a KPS <<< "${PREFLIGHT_PS:-${IP_RG_PS[*]}}"; else read -r -a KPS <<< "${PREFLIGHT_PS:-4}"; fi
TOOLS=${INPUTPATH_TOOLS:-/tmp/ak2-inputpath-tools}
TS=$(date -u +%Y%m%dT%H%M%SZ)
COMMIT=$(git rev-parse HEAD); DIRTY=$([ -n "$(git status --porcelain -- scripts)" ] && echo true || echo false)
RES=results/inputpath/preflight-$PART-$TS-${COMMIT:0:7}
mkdir -p "$RES" || exit 1
LOG=$RES/run.log
exec > >(tee -a "$LOG") 2>&1
echo "inputpath-preflight: PART=$PART DB=${DBSEL:-none} shell flags $- (results $RES)"
START=$(date -u +%FT%TZ)
W=$(mktemp -d /tmp/ak2-inputpath-preflight.XXXXXX) || exit 1
cleanup() { [ "${INPUTPATH_KEEP:-0}" = 1 ] && { echo "inputpath-preflight: kept $W"; return; }; rm -rf "$W"; }
trap cleanup EXIT
ip_gzip_path
for t in jq perl gzip curl python3 git; do command -v "$t" > /dev/null || { echo "inputpath-preflight: need $t" >&2; exit 1; }; done

CHECKS=$RES/checks.tsv; RUNS=$RES/runs.tsv
printf 'check\tsubject\texpected\tobserved\tpass\n' > "$CHECKS"
printf 'tag\tlayout\tarm\tp\tdb\texit\tdecoder_exits\tseconds\tsequences\toutput_sha256\treport_sha256\tcommand\n' > "$RUNS"
FAILED=0
ck() {  # ck NAME SUBJECT EXPECTED OBSERVED [ne]: equal (or, with ne, different) passes
  local p=yes
  if [ "${5:-eq}" = ne ]; then [ "$3" != "$4" ] || p=no; else [ "$3" = "$4" ] || p=no; fi
  [ "$p" = yes ] || FAILED=$((FAILED + 1))
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$p" >> "$CHECKS"
  [ "$p" = yes ] && echo "  ok   $1 $2" || echo "  FAIL $1 $2: expected ${5:+not }'$3', observed '$4'"
}
info() { printf '%s\t%s\t-\t%s\tinfo\n' "$1" "$2" "$3" >> "$CHECKS"; echo "  info $1 $2: $3"; }

# ---- tools and pin ------------------------------------------------------------------------------
pin_identity || exit 1
K2DIR=$(scripts/oracle-build.sh) || { echo "inputpath-preflight: upstream build failed" >&2; exit 1; }
UP=$K2DIR/kraken2
for t in gzip bzip2; do [ ! -e "$K2DIR/$t" ] || { echo "inputpath-preflight: $K2DIR/$t exists (shims go on PATH)" >&2; exit 1; }; done
ip_rg_ensure "$TOOLS" || exit 1
ip_bgzip_ensure "$TOOLS" || exit 1
ip_say "upstream $UPSTREAM_DESCRIBE at $UP; $("$IP_RG" --version | head -1); $("$IP_BGZIP" --version | head -1); gzip: $(command -v gzip) ($(gzip --version 2>&1 | head -1))"
DEVFD_EXAMPLE=$(echo <(true))
dbdir() { case "$1" in viral) echo "$K2_DB_ROOT/k2_viral_20260626" ;; standard8) echo "$K2_DB_ROOT/k2_standard_08_GB_20260626" ;; esac; }
DBDIR=""
if [ -n "$DBSEL" ]; then
  DBDIR=$(dbdir "$DBSEL")
  [ -s "$DBDIR/hash.k2d" ] || scripts/fetch-db.sh "$DBSEL" > /dev/null || { echo "inputpath-preflight: cannot fetch db $DBSEL" >&2; exit 1; }
fi

# ---- the kraken2 arms ---------------------------------------------------------------------------
# Inputs per mate m (1, 2) in the associative array SRC: SRC[fq$m] SRC[gz$m] SRC[bgzf$m] SRC[idx$m].
declare -A SRC=() I0OUT=() I0REP=()
DK="" DP="" DTAG=""
dec() {  # the decoder behind <(...) for mate $1; its exit status goes to $W/$DTAG.dec$1
  local m=$1 rc
  case "$DK" in
    gzip)  gzip -dc "${SRC[gz$m]}"; rc=$? ;;
    rg)    "$IP_RG" -d -c -P "$DP" "${SRC[gz$m]}"; rc=$? ;;
    rgidx) "$IP_RG" -d -c -P "$DP" --import-index "${SRC[idx$m]}" "${SRC[gz$m]}"; rc=$? ;;
    bgzf)  "$IP_RG" -d -c -P "$DP" "${SRC[bgzf$m]}"; rc=$? ;;
  esac
  echo "$rc" > "$W/$DTAG.dec$m"
}
# k2 TAG LAYOUT ARM P: one wrapper run. ARM: I0 (plain files), I1 (.gz, auto-detected), I1f (.gz with
# --gzip-compressed), devfd (<(gzip -dc)), I2 (<(rapidgzip -P p)), I3 (<(rapidgzip -P p
# --import-index)), I4 (<(rapidgzip -P p) on BGZF), neg (devfd plus --gzip-compressed: must differ).
k2() {
  local tag=$1 lay=$2 arm=$3 p=$4 o r e t0 t1 rc decs="" seqs m
  local -a base=(--db "$DBDIR" --threads "$TH") fin=()
  [ "$lay" = pe ] && base+=(--paired)
  o=$W/$tag.out r=$W/$tag.rep e=$W/$tag.err
  base+=(--output "$o" --report "$r")
  DTAG=$tag DP=$p
  case "$arm" in
    I0) fin=("${SRC[fq1]}"); [ "$lay" = pe ] && fin+=("${SRC[fq2]}") ;;
    I1|I1f) fin=("${SRC[gz1]}"); [ "$lay" = pe ] && fin+=("${SRC[gz2]}"); [ "$arm" = I1f ] && base+=(--gzip-compressed) ;;
    devfd|neg) DK=gzip ;;
    I2) DK=rg ;; I3) DK=rgidx ;; I4) DK=bgzf ;;
  esac
  [ "$arm" = neg ] && base+=(--gzip-compressed)
  # The sweep's rule, asserted on every command built here: I2-I4 never pass --gzip-compressed.
  case "$arm" in I2|I3|I4|devfd)
    [[ " ${base[*]} " != *" --gzip-compressed "* ]] || { ck gzflag "$tag" absent present; return 1; } ;;
  esac
  rm -f "$o" "$r" "$W/$tag".dec?
  t0=$(ip_now)
  if [ "${#fin[@]}" -gt 0 ]; then "$UP" "${base[@]}" "${fin[@]}" 2> "$e"; rc=$?
  elif [ "$lay" = pe ]; then "$UP" "${base[@]}" <(dec 1) <(dec 2) 2> "$e"; rc=$?
  else "$UP" "${base[@]}" <(dec 1) 2> "$e"; rc=$?; fi
  t1=$(ip_now)
  if [ "${#fin[@]}" = 0 ]; then
    # The decoders behind <(...) may still be writing their status: wait up to 60 s for it.
    local i=0; while [ "$i" -lt 600 ]; do [ -s "$W/$tag.dec1" ] && { [ "$lay" = se ] || [ -s "$W/$tag.dec2" ]; } && break; sleep 0.1; i=$((i + 1)); done
    for m in 1 2; do [ "$lay" = se ] && [ "$m" = 2 ] && continue; decs="$decs${decs:+,}$(cat "$W/$tag.dec$m" 2> /dev/null || echo none)"; done
  fi
  seqs=$(sed -n 's/^\([0-9]*\) sequences .*processed in.*/\1/p' "$e" | head -1)
  RUN_OUT=$([ -s "$o" ] && ip_sha "$o" || echo absent); RUN_REP=$([ -s "$r" ] && ip_sha "$r" || echo absent)
  RUN_RC=$rc RUN_DECS=${decs:--}
  local cmd="kraken2 ${base[*]//$W\//} $( [ "${#fin[@]}" -gt 0 ] && printf '%s ' "${fin[@]##*/}" || { [ "$lay" = pe ] && echo "<($DK -P $p mate1) <($DK -P $p mate2)" || echo "<($DK -P $p mate1)"; })"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.3f\t%s\t%s\t%s\t%s\n' "$tag" "$lay" "$arm" "$p" "$DBSEL" "$rc" "$RUN_DECS" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b - a}')" "${seqs:-?}" "$RUN_OUT" "$RUN_REP" "$cmd" >> "$RUNS"
  cp "$e" "$RES/$tag.stderr" 2> /dev/null
  rm -f "$o" "$r"
}
# arms PREFIX LAYOUT: I0 first (the reference), then every other arm compared with it.
arms() {
  local pre=$1 lay=$2 a p tag okdec
  k2 "$pre-$lay-I0" "$lay" I0 - || return
  ck exit "$pre-$lay-I0" 0 "$RUN_RC"
  ck nonempty "$pre-$lay-I0 output" yes "$([ "$RUN_OUT" != absent ] && echo yes || echo no)"
  I0OUT[$pre-$lay]=$RUN_OUT I0REP[$pre-$lay]=$RUN_REP
  for a in I1 I1f devfd I2 I3 I4 neg; do
    local ps=(-); case "$a" in I2|I3|I4) ps=("${KPS[@]}") ;; esac
    for p in "${ps[@]}"; do
      tag="$pre-$lay-$a"; [ "$p" != - ] && tag="$tag-P$p"
      k2 "$tag" "$lay" "$a" "$p" || continue
      if [ "$a" = neg ]; then
        ck neg-control "$tag output differs from I0 (--gzip-compressed on /dev/fd paths)" "${I0OUT[$pre-$lay]}" "$RUN_OUT" ne
        info neg-control "$tag" "exit $RUN_RC, output $RUN_OUT, stderr: $(grep -m1 -i 'gzip\|not in' "$RES/$tag.stderr" 2> /dev/null | tr '\t' ' ')"
        continue
      fi
      okdec=yes; [ "$RUN_DECS" = - ] || [[ $RUN_DECS =~ ^0(,0)?$ ]] || okdec="no ($RUN_DECS)"
      ck exit "$tag" 0 "$RUN_RC"
      ck decoders "$tag decoder exit statuses all 0" yes "$okdec"
      ck "$([ "$a" = devfd ] && echo devfd || echo arms)" "$tag --output = I0" "${I0OUT[$pre-$lay]}" "$RUN_OUT"
      ck "$([ "$a" = devfd ] && echo devfd || echo arms)" "$tag --report = I0" "${I0REP[$pre-$lay]}" "$RUN_REP"
    done
  done
}

# ---- the identity check -------------------------------------------------------------------------
# identity LABEL WANT_SHA GZ|BGZF [INDEX]: gzip -dc, then rapidgzip at every -P (with the index when
# given), all equal to WANT_SHA with exit 0. A crash or a mismatch fails the check (never "used").
identity() {
  local lab=$1 want=$2 f=$3 idx=${4:-} got rc p
  local -a ix=()
  [ -n "$idx" ] && ix=(--import-index "$idx")
  if [ -z "$idx" ]; then
    got=$(gzip -dc "$f" | ip_sha_in); rc=${PIPESTATUS[0]}
    ck identity "$lab gzip -dc (exit $rc)" "$want" "$got"
    [ "$rc" = 0 ] || ck identity "$lab gzip -dc exit" 0 "$rc"
  fi
  for p in "${IP_RG_PS[@]}"; do
    got=$("$IP_RG" -d -c -P "$p" "${ix[@]}" "$f" | ip_sha_in); rc=${PIPESTATUS[0]}
    ck identity "$lab rapidgzip -P $p${idx:+ --import-index} (exit $rc)" "$want" "$got"
    [ "$rc" = 0 ] || ck identity "$lab rapidgzip -P $p exit" 0 "$rc"
  done
}

# ---- the gzflag scan ----------------------------------------------------------------------------
# Every sweep file other than this pre-flight and its library: a line that passes --gzip-compressed
# and mentions an I2-I4 input path (rapidgzip, /dev/fd, a process substitution, I2/I3/I4) fails.
gzflag_scan() {
  local f n=0 bad=0 hits
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in scripts/inputpath/preflight.sh|scripts/inputpath/lib.sh|scripts/inputpath/prep.sh) continue ;; esac
    n=$((n + 1))
    # A spec holds its body as one JSON string (one physical line): scan the decoded body's own lines,
    # or I1's legitimate --gzip-compressed and I2's /dev/fd paths would share a "line".
    case "$f" in
      *.json) hits=$(jq -r '.command[2] // empty' "$f" 2>/dev/null | grep -nE -- '--gzip-compressed' | grep -E 'rapidgzip|/dev/fd|<\(|\bI[234]\b' || true) ;;
      *) hits=$(grep -nE -- '--gzip-compressed' "$f" | grep -E 'rapidgzip|/dev/fd|<\(|\bI[234]\b' || true) ;;
    esac
    if [ -n "$hits" ]; then bad=$((bad + 1)); echo "$f: $hits"; fi
  done < <(git ls-files -co --exclude-standard -- 'scripts/inputpath/*' 'scripts/g2/*inputpath*' 'runs/*inputpath*' 'scripts/lib/*inputpath*' | sort -u)
  ck gzflag "sweep files scanned: $n (none yet means: the rule is documented in docs/inputpath.md and asserted on every command built here)" 0 "$bad"
}

# ---- the G1 reference ---------------------------------------------------------------------------
# g1_ref DB CASE PLAIN_SHA1: "<output sha> <report sha> <record>" from the latest G1 oracle record of
# DB at this pin that passed, ran CASE unfiltered, and read an input whose mate-1 FASTQ has PLAIN_SHA1.
g1_ref() {
  local db=$1 cs=$2 s1=$3 d
  for d in $(ls -d results/g1/oracle-"$db"-*/ 2> /dev/null | sort -r); do
    d=${d%/}
    [ -s "$d/manifest.json" ] && [ -s "$d/cases.tsv" ] || continue
    jq -e --arg pin "$UPSTREAM_PIN" --arg s "sha256 $s1 " '.upstream_pin == $pin and .failed == false and ((.case_filter // "") == "")
        and ([.reads[]?.source | contains($s)] | any)' "$d/manifest.json" > /dev/null 2>&1 || continue
    awk -F'\t' -v c="$cs" -v d="$d" 'NR==1{for(i=1;i<=NF;i++) h[$i]=i; next} $1==c{print $h["output_upstream_sha256"], $h["report_upstream_sha256"], d; exit}' "$d/cases.tsv"
    return 0
  done
  return 1
}

ISAL_LOCAL="" ISAL_RT="" ISAL_WHEELS='[]' G1REC='[]' OBJS='[]'
isal_checks() {  # $1: a .gz to decode with -v
  ISAL_LOCAL=$(jq -r .isal_static <<< "$IP_RG_INFO")
  ISAL_RT=$(ip_isal_runtime "$IP_RG" "$1")
  info isal "this host's rapidgzip ($(jq -r .wheel <<< "$IP_RG_INFO"))" "static: $ISAL_LOCAL; rapidgzip -v 'Time spent decoding with ISA-L': ${ISAL_RT:-?} s"
  ISAL_WHEELS=$(ip_isal_wheels "$W") || ISAL_WHEELS='[]'
  if [ "$(jq length <<< "$ISAL_WHEELS")" = 0 ]; then info isal "pinned manylinux aarch64 wheels" "could not download (offline?)"
  else
    jq -r '.[] | select(.wheel | test("aarch64")) | "\(.wheel)\t\(.isal)"' <<< "$ISAL_WHEELS" | while IFS=$'\t' read -r w h; do info isal "pinned wheel $w" "$h"; done
    ck isal "positive control: the pinned cp39 x86_64 wheel is detected as carrying ISA-L" isal \
      "$(jq -r '[.[] | select(.wheel | test("cp39.*x86_64")) | .isal][0] // "absent"' <<< "$ISAL_WHEELS")"
  fi
}

# ---- PART=local ---------------------------------------------------------------------------------
if [ "$PART" = local ]; then
  N=200000; ST=$K2_READS/SRR062634_$N
  [ -s "${ST}.SOURCE" ] || scripts/fetch-reads.sh SRR062634 "$N" > /dev/null || { echo "inputpath-preflight: cannot fetch SRR062634 reads" >&2; exit 1; }
  for m in 1 2; do
    SRC[fq$m]=${ST}_$m.fq SRC[gz$m]=${ST}_$m.fq.gz
    want=$(awk -v f="SRR062634_${N}_$m.fq" '$1=="sha256" && $3==f {print $2}' "${ST}.SOURCE")
    ck source "SRR062634_${N}_$m.fq sha256 = its SOURCE" "$want" "$(ip_sha "${SRC[fq$m]}")"
    SRC[bgzf$m]=$W/SRR062634_${N}_$m.fq.bgz SRC[idx$m]=$W/SRR062634_${N}_$m.fq.gz.rgidx
    gzip -dc "${SRC[gz$m]}" | "$IP_BGZIP" -l "$IP_BGZIP_LEVEL" -@ 4 -c > "${SRC[bgzf$m]}" || ck build "bgzip mate $m" 0 1
    got=$("$IP_RG" -d -c -P "$IP_RG_EXPORT_P" --chunk-size "$IP_RG_CHUNK_KIB" --index-format "$IP_RG_INDEX_FORMAT" \
            --export-index "${SRC[idx$m]}" "${SRC[gz$m]}" | ip_sha_in)
    ck identity "mate $m rapidgzip --export-index pass" "$want" "$got"
    ck bgzf "mate $m is BGZF (BC extra field)" yes "$(python3 -I -c 'import sys; b=open(sys.argv[1],"rb").read(18); print("yes" if b[:2]==b"\x1f\x8b" and b[3]&4 and b[12:14]==b"BC" else "no")' "${SRC[bgzf$m]}")"
    identity "S1 mate $m .gz" "$want" "${SRC[gz$m]}"
    identity "S1 mate $m BGZF" "$want" "${SRC[bgzf$m]}"
    identity "S1 mate $m .gz" "$want" "${SRC[gz$m]}" "${SRC[idx$m]}"
    OBJS=$(jq -c --arg m "$m" --arg fq "$want" --arg gz "$(ip_sha "${SRC[gz$m]}")" --arg b "$(ip_sha "${SRC[bgzf$m]}")" \
      --arg bs "$(ip_size "${SRC[bgzf$m]}")" --arg i "$(ip_sha "${SRC[idx$m]}")" --arg is "$(ip_size "${SRC[idx$m]}")" \
      '. + [{sample:"SRR062634_200000", mate:($m|tonumber), fastq_sha256:$fq, gz_sha256:$gz, bgzf_sha256:$b, bgzf_bytes:($bs|tonumber), index_sha256:$i, index_bytes:($is|tonumber)}]' <<< "$OBJS")
  done
  isal_checks "${SRC[gz1]}"
  gzflag_scan
  ip_say "kraken2 arms on $DBSEL (threads $TH; -P ${KPS[*]})"
  arms S1 pe
  arms S1 se
  sha1=$(ip_sha "${SRC[fq1]}")
  for lay in pe se; do
    cs=pe-default-gz-S1; [ "$lay" = se ] && cs=se-default-S1
    if ref=$(g1_ref "$DBSEL" "$cs" "$sha1"); then
      read -r ro rr rd <<< "$ref"
      ck g1 "S1-$lay I0 --output = $rd ($cs)" "$ro" "${I0OUT[S1-$lay]}"
      ck g1 "S1-$lay I0 --report = $rd ($cs)" "$rr" "${I0REP[S1-$lay]}"
      G1REC=$(jq -c --arg l "$lay" --arg c "$cs" --arg d "$rd" --arg o "$ro" --arg r "$rr" '. + [{layout:$l, case:$c, record:$d, output_sha256:$o, report_sha256:$r}]' <<< "$G1REC")
    else
      ck g1 "S1-$lay: a passing G1 oracle record for $DBSEL at the pin with $cs" found missing
    fi
  done
fi

# ---- PART=inputs --------------------------------------------------------------------------------
if [ "$PART" = inputs ]; then
  T=scripts/inputpath/inputs.tsv
  [ -s "$T" ] || { echo "inputpath-preflight: no $T (make inputpath-prep writes it)" >&2; exit 1; }
  ck header "$T" "role	accession	mate	s3_key	sha256	kind	source_sha256" "$(head -1 "$T")"
  declare -A LOC=() SHA=() KIND=() SRCSHA=()
  mkdir -p "$W/obj"; AWSOK=""
  locate() {  # locate KEY SHA -> a local path holding the object
    local k=$1 s=$2 b c
    b=$(basename "$k")
    for c in ${INPUTPATH_DIR:+"$INPUTPATH_DIR/$b"} ${INPUTPATH_SRC_DIR:+"$INPUTPATH_SRC_DIR/$b"} "$K2_READS/$b" "$W/obj/$b"; do
      [ -s "$c" ] && [ "$(ip_sha "$c")" = "$s" ] && { echo "$c"; return 0; }
    done
    if [ -z "$AWSOK" ]; then ip_bucket_check || return 1; AWSOK=1; fi
    aws s3 cp --only-show-errors --region "$IP_REGION" "s3://$IP_BUCKET/$k" "$W/obj/$b" >&2 || return 1
    echo "$W/obj/$b"
  }
  while IFS=$'\t' read -r role _acc mate key sha kind ssha; do
    [ "$role" = role ] && continue
    if [ -z "${LOC[$key]:-}" ]; then
      p=$(locate "$key" "$sha") || { ck object "$key" found missing; continue; }
      LOC[$key]=$p SHA[$key]=$sha KIND[$key]=$kind SRCSHA[$key]=$ssha
      ck object "$key sha256 (from $p)" "$sha" "$(ip_sha "$p")"
    fi
    case "$role/$kind" in
      */fastq) SRC[$role-fq$mate]=${LOC[$key]} ;;
      */gz) SRC[$role-gz$mate]=${LOC[$key]} ;;
      */bgzf) SRC[$role-bgzf$mate]=${LOC[$key]} ;;
      */index) SRC[$role-idx$mate]=${LOC[$key]} ;;
    esac
    SRC[$role-src$mate]=$ssha; [ "$kind" = fastq ] && SRC[$role-plain$mate]=$ssha
  done < "$T"
  for key in "${!LOC[@]}"; do
    p=${LOC[$key]}
    case "${KIND[$key]}" in
      fastq) ck identity "$key is its own source" "${SRCSHA[$key]}" "${SHA[$key]}" ;;
      gz|bgzf) identity "$key" "${SRCSHA[$key]}" "$p" ;;
    esac
  done
  for key in "${!LOC[@]}"; do
    [ "${KIND[$key]}" = index ] || continue
    gzk=$(awk -F'\t' -v s="${SRCSHA[$key]}" '$6=="gz" && $5==s {print $4; exit}' "$T")
    [ -n "$gzk" ] && [ -n "${LOC[$gzk]:-}" ] || { ck index "$key: its .gz (sha256 ${SRCSHA[$key]}) is in the table" found missing; continue; }
    identity "$gzk with $key" "${SRCSHA[$gzk]}" "${LOC[$gzk]}" "${LOC[$key]}"
  done
  anygz=$(for key in "${!LOC[@]}"; do [ "${KIND[$key]}" = gz ] && echo "${LOC[$key]}"; done | head -1)
  [ -n "$anygz" ] && isal_checks "$anygz"
  gzflag_scan
  if [ -n "$DBSEL" ]; then
    ip_say "kraken2 arms on $DBSEL (threads $TH; -P ${KPS[*]})"
    for role in pe se; do
      lay=$role
      [ -n "${SRC[$role-fq1]:-}" ] || { info arms "$role" "no $role rows in $T"; continue; }
      for m in 1 2; do for k in fq gz bgzf idx; do SRC[$k$m]=${SRC[$role-$k$m]:-}; done; done
      arms "$role" "$lay"
      cs=pe-default-gz-S1; [ "$lay" = se ] && cs=se-default-S1
      if ref=$(g1_ref "$DBSEL" "$cs" "${SRC[$role-plain1]}"); then
        read -r ro rr rd <<< "$ref"
        ck g1 "$role I0 --output = $rd" "$ro" "${I0OUT[$role-$lay]}"; ck g1 "$role I0 --report = $rd" "$rr" "${I0REP[$role-$lay]}"
      else
        info g1 "$role I0 on $DBSEL" "no G1/G2 oracle record for these inputs at this DB; I0 here is the reference: --output ${I0OUT[$role-$lay]}, --report ${I0REP[$role-$lay]} (the node's I0 must equal it)"
      fi
      G1REC=$(jq -c --arg l "$lay" --arg o "${I0OUT[$role-$lay]}" --arg r "${I0REP[$role-$lay]}" --arg db "$DBSEL" \
        '. + [{role:$l, db:$db, i0_output_sha256:$o, i0_report_sha256:$r}]' <<< "$G1REC")
    done
  fi
fi

# ---- record -------------------------------------------------------------------------------------
NCK=$(($(wc -l < "$CHECKS") - 1)); NFAIL=$(awk -F'\t' 'NR>1 && $5=="no"' "$CHECKS" | wc -l | tr -d ' ')
jq -n --arg commit "$COMMIT" --argjson dirty "$DIRTY" --arg part "$PART" --arg db "$DBSEL" --arg dbdir "$DBDIR" \
  --arg dbsrc "$( [ -n "$DBDIR" ] && cat "$DBDIR/SOURCE" 2> /dev/null)" \
  --arg pin "$UPSTREAM_SHA" --arg desc "$UPSTREAM_DESCRIBE" --arg up "$UP" --arg upbuild "$(cat "$K2DIR/BUILD" 2> /dev/null)" \
  --argjson rg "$IP_RG_INFO" --argjson bgzip "$IP_BGZIP_INFO" --arg gz "$(command -v gzip)" --arg gzv "$(gzip --version 2>&1 | head -1)" \
  --arg isal_rt "$ISAL_RT" --argjson isal_wheels "$ISAL_WHEELS" --argjson g1 "$G1REC" --argjson objs "$OBJS" \
  --arg th "$TH" --arg kps "${KPS[*]}" --arg ps "${IP_RG_PS[*]}" --arg devfd "$DEVFD_EXAMPLE" \
  --arg host "$(uname -srm)" --arg ncpu "$(getconf _NPROCESSORS_ONLN)" --arg start "$START" --arg stop "$(date -u +%FT%TZ)" \
  --arg checks_sha "$(ip_checks_sha256)" --argjson nck "$NCK" --argjson nfail "$NFAIL" \
  --arg inputs_sha "$( [ "$PART" = inputs ] && ip_sha scripts/inputpath/inputs.tsv)" \
  '{gate:"g2", what:"inputpath-preflight (#90)", part:$part, commit:$commit, dirty_scripts:$dirty,
    upstream:{pin:$pin, describe:$desc, kraken2:$up, build:$upbuild}, db:{name:$db, dir:$dbdir, source:$dbsrc},
    tools:{rapidgzip:($rg + {isal_runtime_s:$isal_rt}), bgzip:$bgzip, gzip:{path:$gz, version:$gzv}},
    isal_pinned_aarch64_wheels:$isal_wheels, g1_reference:$g1, built_test_objects:$objs,
    kraken2_threads:($th|tonumber), kraken2_arm_ps:$kps, identity_ps:$ps, devfd_example:$devfd,
    host:$host, ncpu:($ncpu|tonumber), start:$start, stop:$stop, checks_sha256:$checks_sha,
    inputs_tsv_sha256:$inputs_sha, checks:$nck, failed:$nfail, pass:($nfail == 0)}' > "$RES/manifest.json"
ip_say "inputpath-preflight: $NCK checks, $NFAIL failed ($RES)"
[ "$NFAIL" = 0 ]
