# #44 Law-1 diagnosis (CLEAR-TO-LAUNCH 2026-10-08): on r8gd.16xlarge with RODA v205 staged onto
# instance-store NVMe, upstream kraken2 at the pin and our plain path, both --memory-mapping, on
# the three cohort samples U1 found differing (SRR5935755, SRR5935786, SRR5935807). Per sample
# scripts/g3/diag44.sh pushes only what differs and its reads: summary.json (digests, ETags),
# report.diff, diff.tsv, the differing read pairs, and k2probe diag-reads' per-read diagnosis
# (scanner events with ambiguity flags; every lookup's value and probe count from upstream's
# CompactHashTable via upstream/chash_dump -m against internal/chash; the hit list; ResolveTree's
# arithmetic, replayed from upstream's events and from ours). Each summary streams as a
# "d44-summary {json}" line. The full outputs are never pushed.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; DATA=aws-kraken2/data
fail() { ak2_say "ERROR: $*"; exit 1; }
SAMPLES=(SRR5935755 SRR5935786 SRR5935807)
# make rehearse's seams (scripts/lib/diag44_rehearse.sh; unset on AWS).
[ -n "${AK2_REHEARSE_SAMPLES:-}" ] && read -r -a SAMPLES <<< "$AK2_REHEARSE_SAMPLES"
# T = 256: upstream's NVMe -M optimum (#40, U2: flat from 256 to 768).
T=${AK2_REHEARSE_THREADS:-256}

ak2_phase setup
sudo -n dnf install -y -q git > "$W/dnf0.log" 2>&1 || fail "dnf git failed"
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
. scripts/g2-instance.sh
g2i_setup
g2i_nvme
if [ -z "${AK2_REHEARSE_SAMPLES:-}" ]; then
  GOV=$(awk '$1=="go"{print $2}' go.mod)
  curl -fsSL --retry 5 --retry-delay 5 "https://go.dev/dl/go$GOV.linux-arm64.tar.gz" -o "$W/go.tgz" || fail "Go download failed"
  tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
  export PATH="$W/go/bin:$PATH"
fi
( { scripts/oracle-build.sh && scripts/harness-build.sh mm_dump chash_dump && make build; } > "$W/build.out" 2>&1 ) &
BUILD_PID=$!

ak2_phase fetch
RD=$G2_NVME/reads; mkdir -p "$RD"
FILES=(); for s in "${SAMPLES[@]}"; do FILES+=("${s}_1.fastq.gz" "${s}_2.fastq.gz"); done
scripts/g3/fetch.sh "$B" "$DATA/cohort" "$RD" 6 "${FILES[@]}" > "$W/fetched.txt" 2>&1 || { cat "$W/fetched.txt"; fail "input fetch failed"; }
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject "${#FILES[@]}" "$B"
ak2_say "inputs staged and verified: ${#FILES[@]} files"
g2i_awscfg 25Gb/s
DB=$G2_NVME/db/RefSeqCompleteV205
g2i_stage_roda "$DB"
unset AWS_CONFIG_FILE
# read_ahead_kb = 4 on every NVMe device (G2's tune, #21): with the boot default, each random
# fault of a cold --memory-mapping run reads 128 KiB, and the first attempt at ce5d8ee spent over
# 50 min on its first sample without finishing.
for dv in ${G2_DEVS//,/ }; do
  echo 4 | sudo -n tee "/sys/block/$dv/queue/read_ahead_kb" > /dev/null || fail "cannot set read_ahead_kb on $dv"
done
ak2_say "read_ahead_kb: $(for dv in ${G2_DEVS//,/ }; do printf '%s=%s ' "$dv" "$(cat /sys/block/$dv/queue/read_ahead_kb 2>/dev/null)"; done)"
wait "$BUILD_PID" || { tail -30 "$W/build.out"; fail "build failed"; }
ak2_say "upstream $(tr '\n' ';' < "$(scripts/oracle-build.sh 2>/dev/null)/BUILD"); harnesses and Go built"

FAILED=0
for s in "${SAMPLES[@]}"; do
  ak2_phase "diag-$s"
  O="$W/d44/$s"
  # Streamed: diag44.sh prints each step as it starts and ends.
  scripts/g3/diag44.sh "$s" "$DB" "$RD" "$G2_NVME/work" "$O" "$T" 2>&1 | tee "$W/$s.log" | grep --line-buffered '^d44: '
  [ "${PIPESTATUS[0]}" = 0 ] || FAILED=1
  echo "d44-summary $(jq -c . "$O/summary.json" 2>/dev/null || echo '{"sample":"'"$s"'","error":"no summary"}')"
  for f in summary.json report.diff diff.tsv up_sel.txt ours_sel.txt sel_1.fq sel_2.fq diag.jsonl diag.err; do
    [ -f "$O/$f" ] && ak2_push "$O/$f" "d44/$s/$f"
  done
  ak2_push "$W/$s.log" "d44/$s/run.log"
done
ak2_say "diag44 done (failed=$FAILED)"
exit "$FAILED"
