#!/usr/bin/env bash
# #44 Law-1 diagnosis, one sample:
#
#   scripts/g3/diag44.sh SAMPLE DB READS_DIR WORK OUT THREADS
#
# Upstream kraken2 at the pin and our plain path (bin/aws-kraken2), both --memory-mapping on the
# same database, --paired, plain defaults, on READS_DIR/SAMPLE_{1,2}.fastq.gz. Writes to OUT only
# what differs and its reads: summary.json (both outputs' and reports' sha256 and engine-writer
# S3 ETags, exits, record counts, differing records), report.diff, and from
# scripts/lib/diag_extract.py diff.tsv, up_sel.txt, ours_sel.txt, sel_{1,2}.fq; then
# diag.jsonl from k2probe diag-reads over those reads (scanner, lookups with probe counts from
# upstream's CompactHashTable via upstream/chash_dump -m, the hit list and ResolveTree, both
# ways). The full outputs stay in WORK.
set +e
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
. scripts/pin.env
. scripts/paths.sh
S=$1 DB=$2 RD=$3 W=$4 O=$5 T=${6:-16}
mkdir -p "$W" "$O"
K2=$(scripts/oracle-build.sh 2>/dev/null)/kraken2
H=".oracle/harness/$UPSTREAM_PIN"
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
t0=$(now)
"$K2" --db "$DB" --memory-mapping --paired --threads "$T" --output "$W/$S.up.out" --report "$W/$S.up.rep" \
  "$RD/${S}_1.fastq.gz" "$RD/${S}_2.fastq.gz" 2> "$W/$S.up.err" > /dev/null
ue=$?; t1=$(now)
bin/aws-kraken2 --db "$DB" --memory-mapping --paired --threads "$T" --output "$W/$S.ours.out" --report "$W/$S.ours.rep" \
  "$RD/${S}_1.fastq.gz" "$RD/${S}_2.fastq.gz" 2> "$W/$S.ours.err" > /dev/null
oe=$?; t2=$(now)
# make rehearse's seam (scripts/lib/diag44_rehearse.sh; unset on AWS): one of our lines altered,
# so the rehearsal has a difference to diagnose.
if [ "${AK2_REHEARSE_TAMPER:-}" = "$S" ]; then
  awk 'NR == 5 { $1 = ($1 == "C" ? "U" : "C") } { print }' OFS='\t' "$W/$S.ours.out" > "$W/$S.ours.t" && mv "$W/$S.ours.t" "$W/$S.ours.out"
fi
python3 scripts/lib/diag_extract.py "$W/$S.up.out" "$W/$S.ours.out" "$RD/${S}_1.fastq.gz" "$RD/${S}_2.fastq.gz" "$O" > "$W/$S.extract.log" 2>&1
xe=$?
diff "$W/$S.up.rep" "$W/$S.ours.rep" > "$O/report.diff"
nd=$(awk 'END{print NR - 1}' "$O/diff.tsv" 2>/dev/null)
de=0
if [ "${nd:-0}" -gt 0 ]; then
  bin/k2probe diag-reads -db "$DB" -mmdump "$H/mm_dump" -chashdump "$H/chash_dump" -up "$O/up_sel.txt" -ours "$O/ours_sel.txt" \
    "$O/sel_1.fq" "$O/sel_2.fq" > "$O/diag.jsonl" 2> "$O/diag.err"
  de=$?
fi
jq -n --arg s "$S" --argjson ue "$ue" --argjson oe "$oe" --argjson xe "$xe" --argjson de "$de" --argjson nd "${nd:-null}" \
  --arg upo "$(sha "$W/$S.up.out")" --arg upr "$(sha "$W/$S.up.rep")" --arg ouo "$(sha "$W/$S.ours.out")" --arg our "$(sha "$W/$S.ours.rep")" \
  --arg upe "$(python3 scripts/lib/ak2etag.py output "$W/$S.up.out" | cut -f1)" --arg upre "$(python3 scripts/lib/ak2etag.py report "$W/$S.up.rep" | cut -f1)" \
  --arg oue "$(python3 scripts/lib/ak2etag.py output "$W/$S.ours.out" | cut -f1)" --arg oure "$(python3 scripts/lib/ak2etag.py report "$W/$S.ours.rep" | cut -f1)" \
  --arg tu "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')" --arg to "$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.1f", b-a}')" \
  --arg x "$(cat "$W/$S.extract.log")" \
  '{sample:$s, upstream:{exit:$ue, seconds:($tu|tonumber), output_sha256:$upo, report_sha256:$upr, output_etag:$upe, report_etag:$upre},
    ours_plain_mmap:{exit:$oe, seconds:($to|tonumber), output_sha256:$ouo, report_sha256:$our, output_etag:$oue, report_etag:$oure},
    extract:{exit:$xe, log:$x}, differing_records:$nd, diag_reads_exit:$de}' > "$O/summary.json"
cat "$O/summary.json"
[ "$ue" = 0 ] && [ "$oe" = 0 ] && [ "$xe" = 0 ] && [ "$de" = 0 ]
