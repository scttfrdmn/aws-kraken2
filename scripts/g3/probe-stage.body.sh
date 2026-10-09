# G3 probe (a) (#25, Scott approved the three cheap probes 2026-10-08): best-practice staging of
# RODA v205's hash.k2d (1.19 TB) onto a tmpfs on one x8g.24xlarge (40 Gb/s, 1536 GiB), as an
# upstream user at their best would stage it, with nothing else running (U1 staged with aws s3 cp
# while the upstream build ran, and its 647 s fetch-db included a 31.4 s ETag check).
# Cheapest first: (1) a 30 s discard sweep of our ranged-GET reader (k2probe rget, the loader's
# approach: parallel ranged GETs pinned to the ETag) at 32, 64 and 128 workers; (2) the whole
# object onto the tmpfs with rget at the sweep's best, then the ETag check timed on its own;
# (3) the whole object with s5cmd (a released, checksummed binary), its ETag check timed; (4) aws
# s3 cp (CRT, 40 Gb/s target, as U1) for 150 s, rate only. The file is removed between tools.
# Network transfers, not storage reads, so drop_caches does not apply (the tmpfs is RAM).
# Every progress line streams as "probe-stage {json}" and into out/stage.jsonl, pushed per step.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
URL=${AK2_REHEARSE_HASH_URL:-https://$RB.s3.us-west-2.amazonaws.com/$RP/hash.k2d}
SWEEP_S=${AK2_REHEARSE_SWEEP_S:-30}; CRT_S=${AK2_REHEARSE_CRT_S:-150}
S5V=2.3.0
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
J="$W/stage.jsonl"; : > "$J"
emit() { echo "$1" >> "$J"; echo "probe-stage $1"; }

ak2_phase setup
sudo -n dnf install -y -q git jq perl tar > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "no repo"
GOV=$(awk '$1=="go"{print $2}' go.mod)
case "$(uname -s)-$(uname -m)" in Linux-aarch64) GOOS=linux; GOA=arm64 ;; Darwin-arm64) GOOS=darwin; GOA=arm64 ;; *) fail "unsupported host" ;; esac
if [ -z "${AK2_REHEARSE_GO:-}" ]; then
  curl -fsSL --retry 5 "https://go.dev/dl/go$GOV.$GOOS-$GOA.tar.gz" -o "$W/go.tgz" || fail "Go download failed"
  tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
  export PATH="$W/go/bin:$PATH"
fi
CGO_ENABLED=0 go build -o "$W/k2probe" ./cmd/k2probe || fail "k2probe build failed"
if [ -n "${AK2_REHEARSE_S5CMD:-}" ]; then S5=$AK2_REHEARSE_S5CMD; else
  T=s5cmd_${S5V}_Linux-arm64.tar.gz
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/$T" -o "$W/$T" || fail "s5cmd download failed"
  curl -fsSL --retry 5 "https://github.com/peak/s5cmd/releases/download/v$S5V/s5cmd_checksums.txt" -o "$W/s5sums" || fail "s5cmd checksums failed"
  ( cd "$W" && grep " $T\$" s5sums | sha256sum -c - ) || fail "s5cmd checksum mismatch"
  tar -xzf "$W/$T" -C "$W" s5cmd || fail "s5cmd unpack failed"
  S5=$W/s5cmd
fi
ak2_say "tools: $("$W/k2probe" 2>&1 | grep -c rget) rget; s5cmd $("$S5" version 2>&1 | head -1); $(aws --version 2>&1)"
ET=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ETag --output text | tr -d '"')
SZ=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ContentLength --output text)
ak2_req HeadObject 2 "$RB"
[[ "$SZ" =~ ^[0-9]+$ ]] && [ -n "$ET" ] || fail "head-object of hash.k2d failed"
ak2_say "hash.k2d etag=$ET size=$SZ"
RAMDB=$(scripts/upstream-cohort.sh mount roda 1150g) || fail "tmpfs failed"
ak2_say "tmpfs $RAMDB; nproc $(nproc); $(grep MemTotal /proc/meminfo 2>/dev/null)"

# rget_run LABEL OUT SECONDS WORKERS: our ranged-GET reader; its JSON lines streamed.
rget_run() {
  local line rc
  "$W/k2probe" rget -url "$URL" -etag "$ET" -size "$SZ" -out "$2" -seconds "$3" -workers "$4" -chunk-mib 64 -every 5 -label "$1" \
    > "$W/rget.out" 2> "$W/rget.err" &
  local p=$!
  # Stream as it goes (a TTL kill must not lose the lines).
  local seen=0
  while kill -0 "$p" 2>/dev/null; do
    sleep 5
    n=$(wc -l < "$W/rget.out"); [ "$n" -gt "$seen" ] && { sed -n "$((seen + 1)),${n}p" "$W/rget.out" | while read -r line; do emit "$line"; done; seen=$n; }
  done
  wait "$p"; rc=$?
  n=$(wc -l < "$W/rget.out"); [ "$n" -gt "$seen" ] && sed -n "$((seen + 1)),${n}p" "$W/rget.out" | while read -r line; do emit "$line"; done
  [ "$rc" = 0 ] || { tail -3 "$W/rget.err"; ak2_say "rget $1 rc=$rc"; }
  return "$rc"
}
# etag_run LABEL: the ETag check of the staged file, on its own.
etag_run() {
  local t0 t1 j rc
  t0=$(now); j=$(python3 scripts/lib/etagcheck.py "$RAMDB/hash.k2d" "$ET"); rc=$?; t1=$(now)
  emit "$(jq -nc --arg l "$1" --arg t0 "$t0" --arg t1 "$t1" --argjson rc "$rc" --arg j "$j" \
    '{kind:"etag", label:$l, seconds:(($t1|tonumber)-($t0|tonumber)), ok:($rc == 0), check:$j}')"
  return "$rc"
}
# sampled_run LABEL SECONDS CMD...: a tool writing $RAMDB/hash.k2d, its file size sampled every 5 s.
sampled_run() {
  local l=$1 lim=$2 t0 t1 rc b; shift 2
  t0=$(now)
  if [ "$lim" -gt 0 ]; then timeout "$lim" "$@" > "$W/tool.out" 2>&1 & else "$@" > "$W/tool.out" 2>&1 & fi
  local p=$!
  while kill -0 "$p" 2>/dev/null; do
    sleep 5
    b=$(du -sk "$RAMDB" 2>/dev/null | cut -f1); b=$(( ${b:-0} * 1024 ))  # the whole tmpfs: a tool may write a temporary name first
    emit "$(jq -nc --arg l "$l" --arg t0 "$t0" --arg t1 "$(now)" --argjson b "$b" \
      '{kind:"progress", label:$l, elapsed_s:(($t1|tonumber)-($t0|tonumber)), file_bytes:$b}')"
  done
  wait "$p"; rc=$?; t1=$(now)
  # The bytes actually present on the tmpfs (allocated, so a sparse time-limited write counts what arrived), under
  # any name: aws s3 cp writes a temporary file and renames it at the end (probe (a) at c0b50ca recorded 0 bytes).
  b=$(du -sk "$RAMDB" 2>/dev/null | cut -f1); b=$(( ${b:-0} * 1024 ))
  emit "$(jq -nc --arg l "$l" --arg t0 "$t0" --arg t1 "$t1" --argjson b "$b" --argjson rc "$rc" --argjson sz "$SZ" --argjson lim "$lim" \
    '{kind:"done", label:$l, seconds:(($t1|tonumber)-($t0|tonumber)), bytes_allocated:$b, object_bytes:$sz, exit:$rc,
      complete:($rc == 0 and $lim == 0), gbps:($b / (($t1|tonumber)-($t0|tonumber)) / 1e9)}')"
  tail -2 "$W/tool.out"
  return "$rc"
}

FAIL=0
ak2_phase sweep
BEST=64; BR=0
for wk in 32 64 128; do
  rget_run "sweep-w$wk" "" "$SWEEP_S" "$wk" || FAIL=1
  r=$(grep '"kind":"done"' "$W/rget.out" | jq -r '.gbps_cum')
  awk -v a="$r" -v b="$BR" 'BEGIN{exit !(a > b)}' && { BEST=$wk; BR=$r; }
  ak2_req GetObject "$(grep '"kind":"done"' "$W/rget.out" | jq -r '.requests')" "$RB"
done
ak2_say "sweep best: $BEST workers at $BR GB/s"
ak2_push "$J" stage.jsonl > /dev/null

ak2_phase rget-full
rget_run "full-rget-w$BEST" "$RAMDB/hash.k2d" 0 "$BEST" || FAIL=1
ak2_req GetObject "$(grep '"kind":"done"' "$W/rget.out" | jq -r '.requests')" "$RB"
ak2_phase etag-rget
etag_run "etag-after-rget" || FAIL=1
find "${RAMDB:?}" -mindepth 1 -delete  # any temporary names too
ak2_push "$J" stage.jsonl > /dev/null

ak2_phase s5cmd-full
sampled_run "full-s5cmd" 0 "$S5" --no-sign-request --numworkers 256 cp --concurrency 128 --part-size 64 "s3://$RB/$RP/hash.k2d" "$RAMDB/hash.k2d" || FAIL=1
ak2_req GetObject $(( (SZ + 67108863) / 67108864 )) "$RB"
ak2_phase etag-s5cmd
etag_run "etag-after-s5cmd" || FAIL=1
find "${RAMDB:?}" -mindepth 1 -delete  # any temporary names too
ak2_push "$J" stage.jsonl > /dev/null

ak2_phase awscrt-sample
printf '[default]\ns3 =\n  preferred_transfer_client = crt\n  target_bandwidth = 40Gb/s\n  multipart_chunksize = 64MB\n' > "$W/aws-config"
AWS_CONFIG_FILE="$W/aws-config" sampled_run "awscrt-${CRT_S}s" "$CRT_S" aws s3 cp --only-show-errors --no-sign-request "s3://$RB/$RP/hash.k2d" "$RAMDB/hash.k2d"
rc=$?
[ "$rc" = 0 ] || [ "$rc" = 124 ] || FAIL=1   # 124: stopped by its time limit, as planned
ak2_req GetObject "$(awk -v b="$(grep '"label":"awscrt' "$J" | tail -1 | jq -r '.bytes_allocated')" 'BEGIN{print int((b + 67108863) / 67108864)}')" "$RB"
find "${RAMDB:?}" -mindepth 1 -delete  # any temporary names too
scripts/upstream-cohort.sh umount roda
ak2_phase push
ak2_push "$J" stage.jsonl || FAIL=1
ak2_say "stage probe done FAIL=$FAIL"
exit "$FAIL"
