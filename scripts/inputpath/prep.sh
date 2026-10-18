#!/usr/bin/env bash
# make inputpath-prep (#90; docs/inputpath.md, "Pre-flight and inputs"): the sweep's derived test
# inputs, built once. For every distinct .gz in scripts/inputpath/samples.tsv (already staged in the
# project bucket):
#   1. find it locally (.cache/reads, sha256 equal to the object's sha256 metadata) or download it
#      into a fresh /tmp directory; gzip -dc it and require the sha256 the staged FASTQ object
#      carries (its metadata);
#   2. I4: gzip -dc | bgzip (htslib, pinned in lib.sh) into BGZF; it must be BGZF and gzip -dc,
#      bgzip -dc and rapidgzip at every -P must give the FASTQ's sha256;
#   3. I3: rapidgzip --export-index (at IP_RG_EXPORT_P, IP_RG_CHUNK_KIB, IP_RG_INDEX_FORMAT); the
#      exporting pass and every -P with --import-index must give the FASTQ's sha256;
#   4. only then, upload both under s3://<bucket>/aws-kraken2/data/inputpath/ with sha256 metadata,
#      check them with head-object, and tag them (project=aws-kraken2, kind=data). An object that is
#      already there with the same sha256 is not uploaded again.
# Then writes scripts/inputpath/inputs.tsv (role, accession, mate, s3_key, sha256, kind, source_sha256;
# the harness reads it) and the record results/inputpath/prep-<UTC>-<commit>/{manifest.json,
# checks.tsv,run.log}. Refuses to upload without a passing make inputpath-preflight record
# (PART=local) whose checks_sha256 equals the current scripts'.
#
# Env: INPUTPATH_DRY=1 (build and check, upload nothing, do not touch inputs.tsv),
#      INPUTPATH_KEEP=1 (keep the /tmp work directory; its path is printed: hand it to
#      make inputpath-preflight PART=inputs as INPUTPATH_DIR), INPUTPATH_TOOLS (as preflight),
#      PREP_THREADS (bgzip -@, default 8). Runs on the laptop or as a node's first step.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. scripts/pin.env
. scripts/paths.sh
. scripts/ak2.env
. scripts/lib/tags.sh
. scripts/inputpath/lib.sh
export AWS_PROFILE
TS=$(date -u +%Y%m%dT%H%M%SZ)
COMMIT=$(git rev-parse HEAD); DIRTY=$([ -n "$(git status --porcelain -- scripts)" ] && echo true || echo false)
RES=results/inputpath/prep-$TS-${COMMIT:0:7}
mkdir -p "$RES" || exit 1
LOG=$RES/run.log
exec > >(tee -a "$LOG") 2>&1
echo "inputpath-prep: shell flags $- (results $RES)"
START=$(date -u +%FT%TZ)
DRY=${INPUTPATH_DRY:-0}
TH=${PREP_THREADS:-8}
TOOLS=${INPUTPATH_TOOLS:-/tmp/ak2-inputpath-tools}
ip_gzip_path
for t in jq aws gzip python3 git curl; do command -v "$t" > /dev/null || { echo "inputpath-prep: need $t" >&2; exit 1; }; done
CHECKS=$RES/checks.tsv
printf 'check\tsubject\texpected\tobserved\tpass\n' > "$CHECKS"
NFAIL=0
ck() {
  local p=yes; [ "$3" = "$4" ] || { p=no; NFAIL=$((NFAIL + 1)); }
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$p" >> "$CHECKS"
  [ "$p" = yes ] && echo "  ok   $1 $2" || echo "  FAIL $1 $2: expected '$3', observed '$4'"
}
CMDS=$RES/commands.txt; : > "$CMDS"
run() { echo "$*" >> "$CMDS"; }   # records a command as run (paths relative to the work directory)

# ---- the pre-flight gate ------------------------------------------------------------------------
WANT=$(ip_checks_sha256)
PF=""
for d in $(ls -d results/inputpath/preflight-local-*/ 2> /dev/null | sort -r); do
  if jq -e --arg s "$WANT" '.pass == true and .checks_sha256 == $s' "${d%/}/manifest.json" > /dev/null 2>&1; then PF=${d%/}; break; fi
done
if [ -z "$PF" ]; then
  echo "inputpath-prep: no passing make inputpath-preflight record (PART=local) for the current checks (checks_sha256 $WANT); run make inputpath-preflight first" >&2
  [ "$DRY" = 1 ] || exit 1
fi
ck preflight "a passing preflight-local record with checks_sha256 $WANT" found "$([ -n "$PF" ] && echo found || echo missing)"
echo "inputpath-prep: pre-flight record ${PF:-none}"

# ---- tools, bucket, disk ------------------------------------------------------------------------
ip_rg_ensure "$TOOLS" || exit 1
ip_bgzip_ensure "$TOOLS" || exit 1
ip_bucket_check || exit 1
echo "inputpath-prep: $(jq -c . <<< "$IP_BUCKET_INFO")"
W=$(mktemp -d /tmp/ak2-inputpath-prep.XXXXXX) || exit 1
cleanup() { [ "${INPUTPATH_KEEP:-0}" = 1 ] && { echo "inputpath-prep: kept $W"; return; }; rm -rf "$W"; }
trap cleanup EXIT
FREE=$(ip_free_gb "$W"); echo "inputpath-prep: $FREE GB free at $W"
[ "$FREE" -ge 60 ] || { echo "inputpath-prep: need >= 60 GB free (50 GB headroom plus the work)" >&2; exit 1; }

# ---- per .gz ------------------------------------------------------------------------------------
S=scripts/inputpath/samples.tsv
declare -A SEEN=() GZSHA=() FQSHA=() BG=() BGSHA=() IX=() IXSHA=()
OBJS='[]'
head_meta() { aws s3api head-object --region "$IP_REGION" --bucket "$IP_BUCKET" --key "$1" --output json 2> /dev/null; }
while IFS=$'\t' read -r role acc mate gzk fqk note; do
  [ "$role" = role ] && continue
  [ -n "${SEEN[$gzk]:-}" ] && continue
  SEEN[$gzk]=1
  b=$(basename "$gzk"); stem=${b%.fq.gz}
  hgz=$(head_meta "$gzk") || { ck object "$gzk exists" yes no; continue; }
  hfq=$(head_meta "$fqk") || { ck object "$fqk exists" yes no; continue; }
  gzsha=$(jq -r '.Metadata.sha256 // empty' <<< "$hgz"); fqsha=$(jq -r '.Metadata.sha256 // empty' <<< "$hfq")
  [ -n "$gzsha" ] && [ -n "$fqsha" ] || { ck object "$gzk / $fqk carry sha256 metadata" yes no; continue; }
  gz=$K2_READS/$b
  if [ -s "$gz" ] && [ "$(ip_sha "$gz")" = "$gzsha" ]; then
    echo "inputpath-prep: $b from $gz (sha256 equal to the object's metadata; no download)"
  else
    gz=$W/$b
    ip_say "downloading s3://$IP_BUCKET/$gzk ($(jq -r .ContentLength <<< "$hgz") B)"
    aws s3 cp --only-show-errors --region "$IP_REGION" "s3://$IP_BUCKET/$gzk" "$gz" || { ck download "$gzk" ok failed; continue; }
    ck object "$b sha256 = its metadata" "$gzsha" "$(ip_sha "$gz")"
  fi
  got=$(gzip -dc "$gz" | ip_sha_in); ck identity "$b gzip -dc = $fqk's sha256" "$fqsha" "$got"
  # I4: BGZF.
  bg=$W/$stem.fq.bgz
  ip_say "bgzip $b"
  run "gzip -dc $b | bgzip -l $IP_BGZIP_LEVEL -@ $TH -c > $stem.fq.bgz"
  gzip -dc "$gz" | "$IP_BGZIP" -l "$IP_BGZIP_LEVEL" -@ "$TH" -c > "$bg"; rcs=("${PIPESTATUS[@]}")
  ck build "$stem.fq.bgz (gzip -dc | bgzip exit statuses)" "0 0" "${rcs[*]}"
  ck bgzf "$stem.fq.bgz is BGZF (BC extra field, BGZF EOF block)" yes "$(python3 -I - "$bg" <<'PY'
import sys
f = open(sys.argv[1], "rb"); h = f.read(18); f.seek(-28, 2); t = f.read(28)
eof = bytes.fromhex("1f8b08040000000000ff0600424302001b0003000000000000000000")
print("yes" if h[:2] == b"\x1f\x8b" and h[3] & 4 and h[12:14] == b"BC" and t == eof else "no")
PY
)"
  ck identity "$stem.fq.bgz gzip -dc" "$fqsha" "$(gzip -dc "$bg" | ip_sha_in)"
  ck identity "$stem.fq.bgz bgzip -dc" "$fqsha" "$("$IP_BGZIP" -dc "$bg" | ip_sha_in)"
  for p in "${IP_RG_PS[@]}"; do
    got=$("$IP_RG" -d -c -P "$p" "$bg" | ip_sha_in); rc=${PIPESTATUS[0]}
    ck identity "$stem.fq.bgz rapidgzip -P $p (exit $rc)" "$fqsha" "$got"; [ "$rc" = 0 ] || ck identity "$stem.fq.bgz rapidgzip -P $p exit" 0 "$rc"
  done
  # I3: the rapidgzip index of the .gz.
  ix=$W/$stem.fq.gz.rgidx
  ip_say "rapidgzip --export-index $b"
  run "rapidgzip -d -c -P $IP_RG_EXPORT_P --chunk-size $IP_RG_CHUNK_KIB --index-format $IP_RG_INDEX_FORMAT --export-index $stem.fq.gz.rgidx $b | sha256"
  got=$("$IP_RG" -d -c -P "$IP_RG_EXPORT_P" --chunk-size "$IP_RG_CHUNK_KIB" --index-format "$IP_RG_INDEX_FORMAT" --export-index "$ix" "$gz" | ip_sha_in); rc=${PIPESTATUS[0]}
  ck identity "$b rapidgzip --export-index pass (exit $rc)" "$fqsha" "$got"
  for p in "${IP_RG_PS[@]}"; do
    got=$("$IP_RG" -d -c -P "$p" "$gz" | ip_sha_in); rc=${PIPESTATUS[0]}
    ck identity "$b rapidgzip -P $p (exit $rc)" "$fqsha" "$got"; [ "$rc" = 0 ] || ck identity "$b rapidgzip -P $p exit" 0 "$rc"
    got=$("$IP_RG" -d -c -P "$p" --import-index "$ix" "$gz" 2> /dev/null | ip_sha_in); rc=${PIPESTATUS[0]}
    ck identity "$b rapidgzip -P $p --import-index (exit $rc)" "$fqsha" "$got"; [ "$rc" = 0 ] || ck identity "$b rapidgzip -P $p --import-index exit" 0 "$rc"
  done
  GZSHA[$gzk]=$gzsha FQSHA[$gzk]=$fqsha BG[$gzk]=$bg BGSHA[$gzk]=$(ip_sha "$bg") IX[$gzk]=$ix IXSHA[$gzk]=$(ip_sha "$ix")
  ip_say "$stem: .gz $(ip_size "$gz") B, BGZF $(ip_size "$bg") B sha256 ${BGSHA[$gzk]}, index $(ip_size "$ix") B sha256 ${IXSHA[$gzk]}"
done < "$S"

# ---- upload, only when every check passed -------------------------------------------------------
if [ "$NFAIL" != 0 ] || [ -z "$PF" ]; then
  echo "inputpath-prep: $NFAIL checks failed or no pre-flight record: nothing uploaded"
  UPLOAD=refused
elif [ "$DRY" = 1 ]; then
  echo "inputpath-prep: INPUTPATH_DRY=1: nothing uploaded"; UPLOAD=dry
else
  UPLOAD="done"
  for gzk in "${!BG[@]}"; do
    for kind in bgzf index; do
      if [ "$kind" = bgzf ]; then f=${BG[$gzk]} s=${BGSHA[$gzk]} src=${FQSHA[$gzk]}; else f=${IX[$gzk]} s=${IXSHA[$gzk]} src=${GZSHA[$gzk]}; fi
      k=$IP_PREFIX/$(basename "$f")
      have=$(head_meta "$k" | jq -r '.Metadata.sha256 // empty')
      if [ "$have" = "$s" ]; then echo "inputpath-prep: $k present (sha256 $s)"
      else
        run "aws s3 cp --metadata sha256=$s,source-sha256=$src $(basename "$f") s3://$IP_BUCKET/$k"
        aws s3 cp --only-show-errors --region "$IP_REGION" --metadata "sha256=$s,source-sha256=$src" "$f" "s3://$IP_BUCKET/$k" ||
          { ck upload "$k" ok failed; UPLOAD=failed; continue; }
      fi
      h=$(head_meta "$k")
      ck upload "$k head-object sha256 and size" "$s $(ip_size "$f")" "$(jq -r '"\(.Metadata.sha256) \(.ContentLength)"' <<< "$h")"
      t=$(ak2_tag_object "$IP_BUCKET" "$k" data) || { ck tag "$k" ok failed; UPLOAD=failed; continue; }
      ck tag "$k project=aws-kraken2 kind=data ($t)" yes yes
      OBJS=$(jq -c --arg k "$k" --arg s "$s" --arg z "$(ip_size "$f")" --arg kind "$kind" --arg src "$src" --argjson h "$h" --arg t "$t" \
        '. + [{key:$k, kind:$kind, sha256:$s, bytes:($z|tonumber), source_sha256:$src, etag:$h.ETag, version_id:($h.VersionId // null), tags:"project=aws-kraken2 kind=data", tagging:$t}]' <<< "$OBJS")
    done
  done
fi

# ---- inputs.tsv ---------------------------------------------------------------------------------
# source_sha256: for fastq, gz and bgzf the sha256 of the FASTQ the object decodes to (fastq: itself);
# for index, the sha256 of the .gz it indexes.
if [ "$UPLOAD" = "done" ] && [ "$NFAIL" = 0 ]; then
  T=scripts/inputpath/inputs.tsv
  {
    printf 'role\taccession\tmate\ts3_key\tsha256\tkind\tsource_sha256\n'
    while IFS=$'\t' read -r role acc mate gzk fqk note; do
      [ "$role" = role ] && continue
      printf '%s\t%s\t%s\t%s\t%s\tfastq\t%s\n' "$role" "$acc" "$mate" "$fqk" "${FQSHA[$gzk]}" "${FQSHA[$gzk]}"
      printf '%s\t%s\t%s\t%s\t%s\tgz\t%s\n' "$role" "$acc" "$mate" "$gzk" "${GZSHA[$gzk]}" "${FQSHA[$gzk]}"
      printf '%s\t%s\t%s\t%s\t%s\tbgzf\t%s\n' "$role" "$acc" "$mate" "$IP_PREFIX/$(basename "${BG[$gzk]}")" "${BGSHA[$gzk]}" "${FQSHA[$gzk]}"
      printf '%s\t%s\t%s\t%s\t%s\tindex\t%s\n' "$role" "$acc" "$mate" "$IP_PREFIX/$(basename "${IX[$gzk]}")" "${IXSHA[$gzk]}" "${GZSHA[$gzk]}"
    done < "$S"
  } > "$T.new" && mv "$T.new" "$T"
  cp "$T" "$RES/inputs.tsv"
  echo "inputpath-prep: wrote $T ($(($(wc -l < "$T") - 1)) rows)"
fi

NCK=$(($(wc -l < "$CHECKS") - 1))
jq -n --arg commit "$COMMIT" --argjson dirty "$DIRTY" --arg pin "$UPSTREAM_PIN" --arg pf "$PF" \
  --argjson rg "$IP_RG_INFO" --argjson bgzip "$IP_BGZIP_INFO" --arg gz "$(command -v gzip)" --arg gzv "$(gzip --version 2>&1 | head -1)" \
  --argjson bucket "$IP_BUCKET_INFO" --argjson objs "$OBJS" --arg upload "$UPLOAD" --arg samples_sha "$(ip_sha "$S")" \
  --arg inputs_sha "$( [ -s scripts/inputpath/inputs.tsv ] && ip_sha scripts/inputpath/inputs.tsv)" \
  --arg ep "$IP_RG_EXPORT_P" --arg ck "$IP_RG_CHUNK_KIB" --arg fmt "$IP_RG_INDEX_FORMAT" --arg ps "${IP_RG_PS[*]}" --arg th "$TH" \
  --arg host "$(uname -srm)" --arg start "$START" --arg stop "$(date -u +%FT%TZ)" --argjson nck "$NCK" --argjson nfail "$NFAIL" \
  --rawfile cmds "$CMDS" \
  '{gate:"g2", what:"inputpath-prep (#90)", commit:$commit, dirty_scripts:$dirty, upstream_pin:$pin, preflight_record:$pf,
    tools:{rapidgzip:$rg, bgzip:$bgzip, gzip:{path:$gz, version:$gzv}},
    index:{export_p:($ep|tonumber), chunk_size_kib:($ck|tonumber), format:$fmt}, identity_ps:$ps, bgzip_threads:($th|tonumber),
    bucket:$bucket, samples_tsv_sha256:$samples_sha, inputs_tsv_sha256:$inputs_sha, objects:$objs, upload:$upload,
    commands:($cmds | split("\n") | map(select(length > 0))), host:$host, start:$start, stop:$stop,
    checks:$nck, failed:$nfail, pass:($nfail == 0 and $upload != "failed")}' > "$RES/manifest.json"
ip_say "inputpath-prep: $NCK checks, $NFAIL failed, upload $UPLOAD ($RES)"
[ "$NFAIL" = 0 ] && [ "$UPLOAD" != failed ] && [ "$UPLOAD" != refused ]
