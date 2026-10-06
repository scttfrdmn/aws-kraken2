#!/usr/bin/env bash
# Fetch the first N records (per mate) of a public run from ENA into .cache/reads/, as plain and
# gzip FASTQ, and record provenance. Usage: scripts/fetch-reads.sh <run-accession> <N>
# ENA intermittently answers HTTP 500: every request is retried, and the script fails loudly,
# naming the URL, once the retries are spent.
set -uo pipefail
cd "$(dirname "$0")/.."
ACC=${1:?run accession}; N=${2:?records per mate}
. scripts/pin.env
. scripts/paths.sh
DST="$K2_READS"; mkdir -p "$DST"
STEM="$DST/${ACC}_$N"
[ -s "$STEM.SOURCE" ] && { echo "$STEM"; exit 0; }
RETRY=(--retry 5 --retry-delay 5 --connect-timeout 30)
API="https://www.ebi.ac.uk/ena/portal/api/filereport?accession=$ACC&result=read_run&fields=fastq_ftp&format=tsv"
REPORT=$(curl -fsS "${RETRY[@]}" --retry-all-errors -m 60 "$API") \
  || { echo "fetch-reads: FAILED: ENA portal API for $ACC after retries ($API)" >&2; exit 1; }
URLS=$(printf '%s\n' "$REPORT" | awk -F'\t' 'NR==2{print $2}' | tr ';' ' ')
[ -n "$URLS" ] || { echo "fetch-reads: FAILED: no fastq_ftp for $ACC in: $REPORT" >&2; exit 1; }
LINES=$((4 * N))
i=0; files=()
for u in $URLS; do
  case "$u" in *_1.fastq.gz) m=1 ;; *_2.fastq.gz) m=2 ;; *) m=0 ;; esac
  [ "$m" = 0 ] && [ "$(echo $URLS | wc -w)" -gt 1 ] && continue   # skip unpaired leftovers
  out="$STEM${m:+_$m}.fq"; [ "$m" = 0 ] && out="$STEM.fq"
  # head closes the pipe early by design, so the record count, not the pipe status, says whether
  # a fetch worked. curl --retry covers HTTP 5xx and timeouts before the body; --retry-all-errors
  # is not used on this stream because it would also "retry" the write error head causes. A
  # failure mid-stream is retried by the loop around the whole pipeline.
  got=0
  for attempt in 1 2 3 4 5; do
    curl -fsS "${RETRY[@]}" -m 1800 "https://$u" 2>"$out.curl.err" | gzip -dc 2>/dev/null | head -n "$LINES" > "$out"
    got=$(wc -l < "$out" | tr -d ' ')
    [ "$got" = "$LINES" ] && break
    echo "fetch-reads: attempt $attempt: $u gave $got lines, want $LINES ($(grep -v 'Failure writing' "$out.curl.err" | head -1)); retrying" >&2
    sleep 5
  done
  rm -f "$out.curl.err"
  [ "$got" = "$LINES" ] || { echo "fetch-reads: FAILED: $u gave $got lines after 5 attempts, want $LINES" >&2; rm -f "$out"; exit 1; }
  gzip -kn9 -f "$out"
  files+=("$out"); i=$((i+1))
done
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
declare -A hashes
for f in "${files[@]}"; do
  hashes[$f]=$(sha "$f")
  [[ ${hashes[$f]} =~ ^[0-9a-f]{64}$ ]] || { echo "fetch-reads: no sha256 for $f" >&2; exit 1; }
done
{ echo "accession $ACC"; echo "records_per_mate $N"; echo "urls $URLS"
  for f in "${files[@]}"; do echo "sha256 ${hashes[$f]} $(basename "$f")"; done
  echo "fetched $(date -u +%FT%TZ)"; } > "$STEM.SOURCE"
echo "$STEM"
