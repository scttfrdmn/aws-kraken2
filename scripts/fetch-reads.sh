#!/usr/bin/env bash
# Fetch the first N records (per mate) of a public run from ENA into .cache/reads/, as plain and
# gzip FASTQ, and record provenance. Usage: scripts/fetch-reads.sh <run-accession> <N>
set -uo pipefail
cd "$(dirname "$0")/.."
ACC=${1:?run accession}; N=${2:?records per mate}
. scripts/pin.env
. scripts/paths.sh
DST="$K2_READS"; mkdir -p "$DST"
STEM="$DST/${ACC}_$N"
[ -s "$STEM.SOURCE" ] && { echo "$STEM"; exit 0; }
URLS=$(curl -fsS "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=$ACC&result=read_run&fields=fastq_ftp&format=tsv" | awk -F'\t' 'NR==2{print $2}' | tr ';' ' ')
[ -n "$URLS" ] || { echo "fetch-reads: no fastq_ftp for $ACC" >&2; exit 1; }
LINES=$((4 * N))
i=0; files=()
for u in $URLS; do
  case "$u" in *_1.fastq.gz) m=1 ;; *_2.fastq.gz) m=2 ;; *) m=0 ;; esac
  [ "$m" = 0 ] && [ "$(echo $URLS | wc -w)" -gt 1 ] && continue   # skip unpaired leftovers
  out="$STEM${m:+_$m}.fq"; [ "$m" = 0 ] && out="$STEM.fq"
  # head closes the pipe early by design; check the record count rather than pipe status.
  curl -fs "https://$u" | gzip -dc 2>/dev/null | head -n "$LINES" > "$out"
  got=$(wc -l < "$out" | tr -d ' ')
  [ "$got" = "$LINES" ] || { echo "fetch-reads: $u gave $got lines, want $LINES" >&2; exit 1; }
  gzip -kn9 -f "$out"
  files+=("$out"); i=$((i+1))
done
{ echo "accession $ACC"; echo "records_per_mate $N"; echo "urls $URLS"
  for f in "${files[@]}"; do echo "sha256 $(shasum -a 256 "$f" | cut -d' ' -f1) $(basename "$f")"; done
  echo "fetched $(date -u +%FT%TZ)"; } > "$STEM.SOURCE"
echo "$STEM"
