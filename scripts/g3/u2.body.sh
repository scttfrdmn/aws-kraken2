# G3 U2 (#25, #40; Scott approved the campaign 2026-10-08): upstream kraken2 at the pin (pristine;
# built from source here) at its best on NVMe: RODA v205 staged onto instance-store NVMe (RAID0
# over both devices), --memory-mapping with the host tune read_ahead_kb=4, cold (ak2_drop_caches
# before every cold rung), on r8gd.16xlarge. Plan scripts/g2/u2.plan: the #40 ladder T = 256..768
# on SRR062634's 8M-pair prefix (gz), n = 3, and the cohort's sample 1 (SRR5935740, gz as staged
# in the cohort prefix, sha256 checked) cold at T = 768 and 512 and warm. Runs through make g2's
# runner (scripts/g2.sh, scripts/lib/g2run.py): every rung streams a "g2: <rung> {json}" line into
# the run log and runs.jsonl is pushed after each; the summary is scripts/lib/g2summary.py's.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; DATA=aws-kraken2/data
fail() { ak2_say "ERROR: $*"; exit 1; }
hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
G2_DEADLINE=$(( $(date +%s) + 105 * 60 )); export G2_DEADLINE
# make rehearse's seams (scripts/lib/u2_rehearse.sh; unset on AWS): the plan and the 8M stem.
PLAN=${AK2_REHEARSE_PLAN:-scripts/g2/u2.plan}
STEM8M=${AK2_REHEARSE_STEM8M:-SRR062634_8000000}
S1=SRR5935740

ak2_phase setup
sudo -n dnf install -y -q git > "$W/dnf0.log" 2>&1 || fail "dnf git failed"
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
. scripts/g2-instance.sh
g2i_setup
g2i_nvme

ak2_phase fetch-reads
RD=$G2_NVME/reads
g2i_stage_reads "$RD" "$B" "$DATA" "$STEM8M"
for m in 1 2; do
  f="${S1}_$m.fastq.gz"
  ak2_stage "s3://$B/$DATA/cohort/$f" "$RD/${S1}_$m.fq.gz" || fail "stage of cohort/$f failed"
  want=$(aws s3api head-object --bucket "$B" --key "$DATA/cohort/$f" --query Metadata.sha256 --output text)
  got=$(sha256sum "$RD/${S1}_$m.fq.gz" | cut -d' ' -f1)
  ak2_req GetObject "$(( ($(stat -c%s "$RD/${S1}_$m.fq.gz") + 8388607) / 8388608 ))" "$B"
  ak2_req HeadObject 1 "$B"
  hex64 "$want" && [ "$got" = "$want" ] || fail "$f sha256 $got != metadata $want"
done
ak2_say "cohort sample 1 ($S1) staged and verified"

ak2_phase fetch-db
( scripts/oracle-build.sh > "$W/build.out" 2>&1 ) &
BUILD_PID=$!
g2i_awscfg 25Gb/s
DB=$G2_NVME/db/RefSeqCompleteV205
g2i_stage_roda "$DB"
wait "$BUILD_PID" || { cat "$W/build.out"; fail "build failed"; }
unset AWS_CONFIG_FILE
G2_UPSTREAM=$(scripts/oracle-build.sh 2>/dev/null) || fail "upstream build not found"
export G2_UPSTREAM
ak2_say "upstream: $(tr '\n' ';' < "$G2_UPSTREAM/BUILD")"

G2_PLAN=$PLAN G2_DB=$DB G2_READS=$RD G2_WORK=$G2_NVME/work G2_LABEL=u2 G2_GATE=g3 G2_RUNG_TIMEOUT=1200
export G2_PLAN G2_DB G2_READS G2_WORK G2_LABEL G2_GATE G2_RUNG_TIMEOUT
. scripts/g2.sh
RC=$?
ak2_say "g3 u2 rc=$RC"
ak2_phase push
[ "$RC" = 0 ] || exit "$RC"
exit 0
