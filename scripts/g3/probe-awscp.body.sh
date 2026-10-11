# G3 pre-launch probe (#53 review, before the #25 ladder): the rate of RODA v205's hash.k2d
# (1.19 TB) staged by the AMI's aws CLI as shipped (awscp-default: the classic transfer client on
# r8gd.48xlarge, lever.sh's auto rule), onto the type's single NVMe device, exactly as S0-T1 and
# S0-Tv's fetch-db stage it: lv_nvme single, then lever.sh's lv_stage_db awscp-default command line
# (its client, its signed-then-anonymous head-object, `aws s3 cp --only-show-errors`). That rate has
# never been measured, so their 360 min TTL is a guess.
# It stages a prefix of the object: the copy runs until 20 min or 300 GiB received, whichever
# comes first (or the object is complete), and is then stopped; the partial file is removed.
# Every 10 s a progress line streams as "probe-awscp {json}" and into out/awscp.jsonl:
#   bytes (received on the NIC since the copy started; the allocated bytes on the NVMe beside it),
#   s, gbps (gigabits/s, cumulative) and interval_gbps (since the last line), gb_per_s (GB/s).
# The resolved client is recorded (kind client, from lever.sh's aws-client record), and the done
# line estimates the whole object's staging time at the measured rate.
# make rehearse seams (AK2_REHEARSE_*, which run.sh refuses in a spec's env): lever.sh's NVME, and
# AWSCP_S, AWSCP_BYTES and AWSCP_EVERY (the limits and the sampling period).
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
LIMIT_S=${AK2_REHEARSE_AWSCP_S:-1200}; LIMIT_B=${AK2_REHEARSE_AWSCP_BYTES:-322122547200}; EVERY=${AK2_REHEARSE_AWSCP_EVERY:-10}
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
J="$W/awscp.jsonl"; : > "$J"
emit() { printf '%s\n' "$1" >> "$J"; printf 'probe-awscp %s\n' "$1"; }
# rx: bytes received on the default-route interface (/proc/net/dev); "" where there is none.
rx() {
  local i; i=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2> /dev/null)
  [ -n "$i" ] && awk -v i="$i:" '$1 == i {print $2}' /proc/net/dev 2> /dev/null
}
# alloc DIR: the bytes allocated to the files under DIR (what the copy has written so far).
alloc() { python3 -c 'import os, sys; print(sum(os.lstat(os.path.join(d, f)).st_blocks * 512 for d, _, fs in os.walk(sys.argv[1]) for f in fs))' "$1"; }

ak2_phase setup
sudo -n dnf install -y -q git jq perl python3 tar util-linux > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf install failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
. scripts/g3/lever.sh || fail "lever.sh did not load"
# S0's storage: the first instance-store device, one xfs (lv_nvme single, as ladder.body.sh).
lv_nvme single /mnt/nvme || fail "lv_nvme failed"
DEST="$LV_NVME/db"; mkdir -p "$DEST" || fail "mkdir $DEST"
# S0's client: the AMI's aws CLI with no config override, recorded once (lever.sh's aws-client line).
lv__client default || fail "aws client default"
CL=$(grep '"kind":"aws-client"' "$LV_REC" | grep '"client":"default"' | tail -1)
emit "$(jq -c '{kind:"client", client, cli_version, resolved, how, estimate, configure_get, instance_type, optimized_platforms, ladder_types,
  home_aws_config, etc_aws}' <<< "$CL")"
# lv_stage_db's head-object: signed first, then anonymous; the copy is signed the same way.
lv__head "$RB" "$RP/hash.k2d" || fail "head-object of hash.k2d failed (signed and anonymous)"
OBJ=$LV_H_SIZE
CMD=("${LV_AWS[@]}" s3 cp --only-show-errors $LV_H_SIGN "s3://$RB/$RP/hash.k2d" "$DEST/hash.k2d")
emit "$(jq -nc --arg type "${AK2_INSTANCE_TYPE:-}" --argjson obj "$OBJ" --arg etag "$LV_H_ETAG" --arg sign "${LV_H_SIGN:-signed}" \
  --argjson ls "$LIMIT_S" --argjson lb "$LIMIT_B" --argjson every "$EVERY" --arg dest "$DEST" --arg fs "$(stat -f -c %T "$DEST" 2> /dev/null)" \
  --argjson nproc "$(nproc)" --arg cmd "${CMD[*]}" --arg aws "$(aws --version 2>&1 | head -1)" \
  '{kind:"config", instance_type:$type, object_bytes:$obj, etag:$etag, signing:$sign, limit_s:$ls, limit_bytes:$lb, every_s:$every,
    dest:$dest, fstype:$fs, nproc:$nproc, aws_version:$aws, command:$cmd}')"
ak2_push "$J" awscp.jsonl > /dev/null

# Cold, as S0's fetch-db (nothing of the object is cached; the copy goes network -> NVMe).
ak2_drop_caches
ak2_phase stage
R0=$(rx); T0=$(now)
"${CMD[@]}" > "$W/cp.out" 2>&1 &
CP=$!
STOP=""; LB=0; LS=0; LASTPUSH=$SECONDS; S60=""
while :; do
  for _ in $(seq "$EVERY"); do kill -0 "$CP" 2> /dev/null || break; sleep 1; done
  t=$(now); s=$(awk -v a="$T0" -v b="$t" 'BEGIN{printf "%.3f", b - a}')
  r=$(rx); al=$(alloc "$DEST")
  # Dirty and Writeback (kB): page cache waiting for, or being written to, the NVMe. Growing, they
  # say the disk, not the network, limits the rate. "" where there is no /proc/meminfo.
  read -r dk wk < <(awk '/^Dirty:/ {d = $2} /^Writeback:/ {w = $2} END {print d, w}' /proc/meminfo 2> /dev/null)
  if [ -n "$R0" ] && [ -n "$r" ]; then b=$((r - R0)); basis=nic_rx; else b=$al; basis=allocated; fi
  emit "$(jq -nc --argjson b "$b" --argjson al "${al:-0}" --arg basis "$basis" --argjson s "$s" --argjson lb "$LB" --argjson ls "$LS" \
    --arg dk "${dk:-}" --arg wk "${wk:-}" '
    def r3: . * 1000 | round / 1000;
    {kind:"progress", bytes:$b, bytes_basis:$basis, allocated_bytes:$al, s:$s,
     dirty_kb:(if $dk == "" then null else ($dk | tonumber) end), writeback_kb:(if $wk == "" then null else ($wk | tonumber) end),
     gbps:(if $s > 0 then ($b * 8 / $s / 1e9 | r3) else null end),
     gb_per_s:(if $s > 0 then ($b / $s / 1e9 | r3) else null end),
     interval_gbps:(if $s > $ls then (($b - $lb) * 8 / ($s - $ls) / 1e9 | r3) else null end)}')"
  LB=$b; LS=$s
  [ -z "$S60" ] && awk -v s="$s" 'BEGIN{exit !(s >= 60)}' && S60="$s $b"   # the steady rate is taken from the first line past 60 s
  if ! kill -0 "$CP" 2> /dev/null; then STOP=ended; break; fi
  if awk -v s="$s" -v l="$LIMIT_S" 'BEGIN{exit !(s >= l)}'; then STOP=time; break; fi
  if [ "$b" -ge "$LIMIT_B" ]; then STOP=bytes; break; fi
  if [ $((SECONDS - LASTPUSH)) -ge 30 ]; then ak2_push "$J" awscp.jsonl > /dev/null; LASTPUSH=$SECONDS; fi
done
# Stop the copy: TERM, then KILL if it has not exited within 30 s, so the wait below cannot hang
# until the TTL.
HARD=false
if [ "$STOP" != ended ]; then
  kill "$CP" 2> /dev/null
  for _ in $(seq 30); do kill -0 "$CP" 2> /dev/null || break; sleep 1; done
  if kill -0 "$CP" 2> /dev/null; then kill -KILL "$CP" 2> /dev/null; HARD=true; ak2_say "probe-awscp: the copy ignored TERM for 30 s; KILL"; fi
fi
wait "$CP"; CPRC=$?
[ "$STOP" = ended ] && { [ "$CPRC" = 0 ] && STOP=complete || STOP=failed; }
T1=$(now); sync
FB=$(alloc "$DEST"); FR=$(rx)
B=$LB; [ -n "$R0" ] && [ -n "$FR" ] && B=$((FR - R0))
[ "$STOP" = complete ] && B=$OBJ
# Requests (derived, as lever.sh counts them): head-object made by lv__head; the copy's GETs at
# the classic client's 8 MiB parts, as -estimate unless the client resolved to classic.
SFX=""; [ "${LV_CLIENT_EST[default]:-1}" = 1 ] && SFX=-estimate
ak2_req "GetObject$SFX" $(( (B + 8388607) / 8388608 )) "$RB"
emit "$(jq -nc --arg stop "$STOP" --argjson rc "$CPRC" --argjson b "$B" --argjson fb "${FB:-0}" --argjson obj "$OBJ" \
  --arg t0 "$T0" --arg t1 "$T1" --arg s60 "${S60:-}" --argjson hard "$HARD" --arg out "$(tail -c 600 "$W/cp.out")" '
  def r3: . * 1000 | round / 1000;
  (($t1|tonumber) - ($t0|tonumber)) as $s
  | (if $s60 == "" then null else ($s60 | split(" ") | map(tonumber)) end) as $p
  | (if $p == null or $s <= $p[0] then null else (($b - $p[1]) / ($s - $p[0])) end) as $steady
  | {kind:"done", stopped_by:$stop, cp_rc:$rc, killed_hard:$hard, bytes:$b, allocated_bytes_after_stop:$fb, object_bytes:$obj, s:($s | r3),
     gbps:(if $s > 0 then ($b * 8 / $s / 1e9 | r3) else null end), gb_per_s:(if $s > 0 then ($b / $s / 1e9 | r3) else null end),
     steady_gbps:(if $steady == null then null else ($steady * 8 / 1e9 | r3) end),
     est_object_s:(if $s > 0 and $b > 0 then ($obj / ($b / $s) | round) else null end),
     est_object_s_steady:(if $steady == null or $steady <= 0 then null else ($obj / $steady | round) end),
     cp_output_tail:$out}')"
rm -rf "$DEST"
ak2_push "$J" awscp.jsonl > /dev/null || fail "push of awscp.jsonl failed"
ak2_say "probe-awscp: stopped by $STOP after $(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.0f", b - a}') s, $B bytes"
case $STOP in time|bytes|complete) exit 0 ;; *) fail "the copy failed (rc $CPRC): $(tail -3 "$W/cp.out" | tr '\n' ' ')" ;; esac
