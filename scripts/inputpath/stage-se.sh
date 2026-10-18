#!/usr/bin/env bash
# make inputpath-stage-se [RUN=SRR4074269] (#90; docs/inputpath.md, "Pre-flight and inputs"): stage
# the sweep's single-end sample (Scott, 2026-10-18: SRR4074269) from ENA into the project bucket.
#   1. Record ENA's filereport for RUN (one file, library_layout SINGLE) in
#      results/inputpath/se/<RUN>/run.tsv (run, study, layout, strategy, instrument, reads, bases,
#      URL, bytes, md5) with query.json (URL, time, sha256 of the raw response).
#   2. Download the .fastq.gz over HTTPS in STAGE_RANGES ranged streams (default 8) into a fresh
#      /tmp directory; bytes and md5 must equal ENA's.
#   3. gzip -dc it to the plain FASTQ (I0's input; the sha256 the sweep's identity check uses).
#   4. Upload both to s3://<bucket>/aws-kraken2/data/reads/<RUN>.fastq.gz and <RUN>.fastq with
#      sha256 (and md5 for the .gz) metadata, check with head-object, tag (project, kind=data).
#      An object already there with the same sha256 is not uploaded again.
#   5. Append to results/inputpath/se/<RUN>/staged.tsv (run, kind, bytes, md5, sha256, key, version,
#      etag, url, at).
# STAGE_KEEP=1 keeps the /tmp directory (its path is printed; make inputpath-prep reads the .gz from
# INPUTPATH_SRC_DIR=<it> instead of downloading it again).
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. scripts/pin.env
. scripts/paths.sh
. scripts/ak2.env
. scripts/lib/tags.sh
. scripts/inputpath/lib.sh
export AWS_PROFILE
echo "inputpath-stage-se: shell flags $-"
RUN=${1:-${RUN:-SRR4074269}}
[[ $RUN =~ ^[SED]RR[0-9]+$ ]] || { echo "inputpath-stage-se: bad run $RUN" >&2; exit 2; }
NR=${STAGE_RANGES:-8}
D=results/inputpath/se/$RUN; mkdir -p "$D" || exit 1
for t in curl jq python3 aws gzip; do command -v "$t" > /dev/null || { echo "inputpath-stage-se: need $t" >&2; exit 1; }; done
if command -v md5sum > /dev/null; then md5of() { md5sum "$1" | cut -d' ' -f1; }; else md5of() { md5 -q "$1"; }; fi
ip_gzip_path

# 1. ENA's record.
F=run_accession,study_accession,library_layout,library_strategy,instrument_model,read_count,base_count,fastq_ftp,fastq_bytes,fastq_md5
URL="https://www.ebi.ac.uk/ena/portal/api/filereport?accession=$RUN&result=read_run&fields=$F&format=tsv"
RAW=$(mktemp) || exit 1
curl -fsS --retry 5 --retry-delay 5 "$URL" -o "$RAW" || { echo "inputpath-stage-se: ENA query failed" >&2; exit 1; }
AT=$(date -u +%FT%TZ)
read -r run study layout strategy instr reads bases ftp bytes md5 < <(awk -F'\t' 'NR==2{for(i=1;i<=NF;i++) gsub(/ /,"_",$i); print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10}' "$RAW")
[ "$run" = "$RUN" ] && [ "$layout" = SINGLE ] && [[ $ftp != *";"* ]] && [[ $md5 =~ ^[0-9a-f]{32}$ ]] ||
  { cat "$RAW"; echo "inputpath-stage-se: $RUN is not one SINGLE file with an md5 at ENA" >&2; exit 1; }
SRCURL=https://$ftp
{ printf 'run\tstudy\tlayout\tstrategy\tinstrument\tread_count\tbase_count\turl\tbytes\tmd5\n'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run" "$study" "$layout" "$strategy" "${instr//_/ }" "$reads" "$bases" "$SRCURL" "$bytes" "$md5"; } > "$D/run.tsv"
jq -n --arg u "$URL" --arg at "$AT" --arg s "$(ip_sha "$RAW")" --arg who "Scott, 2026-10-18 (#90)" \
  '{query_url:$u, queried_at:$at, raw_response_sha256:$s, approved:$who}' > "$D/query.json"
rm -f "$RAW"
echo "inputpath-stage-se: $RUN ($study, $layout, ${instr//_/ }, $reads reads): $SRCURL, $bytes B, md5 $md5"

ip_bucket_check || exit 1
GZK=$IP_ROOT_DATA/reads/$RUN.fastq.gz FQK=$IP_ROOT_DATA/reads/$RUN.fastq
W=$(mktemp -d /tmp/ak2-inputpath-stage-se.XXXXXX) || exit 1
FREE=$(ip_free_gb "$W"); echo "inputpath-stage-se: $FREE GB free"
[ "$FREE" -ge 60 ] || { echo "inputpath-stage-se: need >= 60 GB free" >&2; exit 1; }
cleanup() { [ "${STAGE_KEEP:-0}" = 1 ] && { echo "inputpath-stage-se: kept $W"; return; }; rm -rf "$W"; }
trap cleanup EXIT

# 2. Download in ranges.
GZ=$W/$RUN.fastq.gz
t0=$(ip_now)
step=$(( (bytes + NR - 1) / NR )); pids=()
for ((i = 0; i < NR; i++)); do
  a=$((i * step)); b=$((a + step - 1)); [ "$b" -ge "$bytes" ] && b=$((bytes - 1))
  curl -fsS --retry 10 --retry-delay 5 -r "$a-$b" -o "$W/part.$i" "$SRCURL" & pids+=($!)
done
st=0; for p in "${pids[@]}"; do wait "$p" || st=1; done
[ "$st" = 0 ] || { echo "inputpath-stage-se: a ranged download failed" >&2; exit 1; }
for ((i = 0; i < NR; i++)); do cat "$W/part.$i"; done > "$GZ"; rm -f "$W"/part.*
t1=$(ip_now)
[ "$(ip_size "$GZ")" = "$bytes" ] || { echo "inputpath-stage-se: $(ip_size "$GZ") B, ENA says $bytes" >&2; exit 1; }
[ "$(md5of "$GZ")" = "$md5" ] || { echo "inputpath-stage-se: md5 differs from ENA's $md5" >&2; exit 1; }
echo "inputpath-stage-se: downloaded $bytes B in $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.0f", b - a}') s, md5 equal to ENA's"

# 3. The plain FASTQ.
FQ=$W/$RUN.fastq
gzip -dc "$GZ" > "$FQ" || { echo "inputpath-stage-se: gzip -dc failed" >&2; exit 1; }
GZSHA=$(ip_sha "$GZ") FQSHA=$(ip_sha "$FQ")
echo "inputpath-stage-se: .gz sha256 $GZSHA; FASTQ $(ip_size "$FQ") B, sha256 $FQSHA, $(($(wc -l < "$FQ") / 4)) records"

# 4-5. Upload, check, tag, record.
[ -s "$D/staged.tsv" ] || printf 'run\tkind\tbytes\tmd5\tsha256\tkey\tversion\tetag\turl\tat\n' > "$D/staged.tsv"
FAILED=0
up() {  # up FILE KEY SHA MD5 KIND
  local f=$1 k=$2 s=$3 m=$4 kind=$5 have h meta t
  have=$(aws s3api head-object --region "$IP_REGION" --bucket "$IP_BUCKET" --key "$k" --query Metadata.sha256 --output text 2> /dev/null)
  if [ "$have" = "$s" ]; then echo "inputpath-stage-se: $k present (sha256 $s)"
  else
    meta="sha256=$s,source-url=$SRCURL"; [ -n "$m" ] && meta="$meta,md5=$m"
    aws s3 cp --only-show-errors --region "$IP_REGION" --metadata "$meta" "$f" "s3://$IP_BUCKET/$k" || { echo "inputpath-stage-se: upload $k failed" >&2; FAILED=1; return; }
  fi
  h=$(aws s3api head-object --region "$IP_REGION" --bucket "$IP_BUCKET" --key "$k" --output json) || { FAILED=1; return; }
  [ "$(jq -r '"\(.Metadata.sha256) \(.ContentLength)"' <<< "$h")" = "$s $(ip_size "$f")" ] || { echo "inputpath-stage-se: $k head-object mismatch" >&2; FAILED=1; return; }
  t=$(ak2_tag_object "$IP_BUCKET" "$k" data) || { echo "inputpath-stage-se: tagging $k failed" >&2; FAILED=1; return; }
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$RUN" "$kind" "$(ip_size "$f")" "${m:--}" "$s" "$k" "$(jq -r '.VersionId // "-"' <<< "$h")" \
    "$(jq -r .ETag <<< "$h" | tr -d '"')" "$SRCURL" "$(date -u +%FT%TZ)" >> "$D/staged.tsv"
  echo "inputpath-stage-se: $k staged ($(ip_size "$f") B, sha256 $s, tags $t)"
}
up "$GZ" "$GZK" "$GZSHA" "$md5" gz
up "$FQ" "$FQK" "$FQSHA" "" fastq
[ "$FAILED" = 0 ]
