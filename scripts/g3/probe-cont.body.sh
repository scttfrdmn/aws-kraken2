# G3 probe (b) (#25, Scott approved the three cheap probes 2026-10-08): the S3 contention curve
# for N nodes each staging RODA v205's hash.k2d at once, as N sample-parallel upstream nodes
# would. No kraken. One cohort (make run NODES=64) of c8gn.4xlarge (50 Gb/s baseline, the cheapest
# Graviton type whose sustained NIC is at least the x8g.24xlarge's 40 Gb/s), in four stages, cheapest
# first: N = 1 (rank 0 alone), 16, 32, 64 (ranks below N read, the rest wait). In each stage every
# reading rank runs our ranged-GET reader (k2probe rget, 64 workers, 64 MiB ranges, from byte 0,
# the way each sample-parallel node would start) to /dev/null for STAGE_S seconds; per-node and
# aggregate GB/s and the spread over nodes come from the streamed lines (post script).
# Synchronisation: every member puts rendezvous/probe/ready-<rank> (its clock), polls for all N,
# and starts the stages at max(ready clocks) + 30 s; stage k at that + k x (STAGE_S + GAP_S).
# Every rget line streams as "probe-cont {json}" and into out/cont-<rank>.jsonl after every stage.
W=$HOME/ak2; mkdir -p "$W"
SHA=$(echo "$AK2_COHORT_ID" | cut -d- -f3)
RANK=$AK2_ENGINE_RANK; N=$AK2_ENGINE_N
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
URL=${AK2_REHEARSE_HASH_URL:-https://$RB.s3.us-west-2.amazonaws.com/$RP/hash.k2d}
STAGE_S=${AK2_REHEARSE_STAGE_S:-60}; GAP_S=${AK2_REHEARSE_GAP_S:-20}; WAIT_LIMIT=${AK2_REHEARSE_WAIT_S:-1500}
STAGES=${AK2_REHEARSE_STAGES:-"1 16 32 64"}
fail() { ak2_say "ERROR: $*"; exit 1; }
J="$W/cont-$RANK.jsonl"; : > "$J"
RZ=${AK2_ENGINE_RENDEZVOUS#s3://}; RZB=${RZ%%/*}; RZK=${RZ#*/}/probe

ak2_phase setup
sudo -n dnf install -y -q git jq > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf failed"; }
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
ET=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ETag --output text | tr -d '"')
SZ=$(aws s3api head-object --no-sign-request --bucket "$RB" --key "$RP/hash.k2d" --query ContentLength --output text)
ak2_req HeadObject 2 "$RB"
[[ "$SZ" =~ ^[0-9]+$ ]] && [ -n "$ET" ] || fail "head-object of hash.k2d failed"
for s in $STAGES; do [ "$s" -le "$N" ] || fail "stage N=$s exceeds the cohort's $N members"; done
ak2_say "rank $RANK of $N; hash.k2d etag=$ET size=$SZ; stages $STAGES x ${STAGE_S}s"

ak2_phase rendezvous
date +%s > "$W/ready"
aws s3api put-object --bucket "$RZB" --key "$RZK/ready-$RANK" --body "$W/ready" > /dev/null || fail "ready put failed"
ak2_req PutObject 1 "$RZB"
t0=$(date +%s); GO=0; gets=0
while :; do
  have=0; mx=0
  for ((k = 0; k < N; k++)); do
    if aws s3api get-object --bucket "$RZB" --key "$RZK/ready-$k" "$W/r-$k" > /dev/null 2>&1; then
      have=$((have + 1)); v=$(cat "$W/r-$k"); [ "$v" -gt "$mx" ] && mx=$v
    fi
    gets=$((gets + 1))
  done
  [ "$have" = "$N" ] && { GO=$((mx + 30)); break; }
  [ $(( $(date +%s) - t0 )) -gt "$WAIT_LIMIT" ] && { ak2_req GetObject "$gets" "$RZB"; fail "rendezvous: $have of $N ready after ${WAIT_LIMIT}s"; }
  sleep 10
done
ak2_req GetObject "$gets" "$RZB"
ak2_say "rendezvous: all $N ready; stages start at $GO ($(( GO - $(date +%s) )) s from now)"

FAIL=0; k=0
for s in $STAGES; do
  st=$(( GO + k * (STAGE_S + GAP_S) )); k=$((k + 1))
  ak2_phase "stage-n$s"
  while [ "$(date +%s)" -lt "$st" ]; do sleep 1; done
  if [ "$RANK" -lt "$s" ]; then
    "$W/k2probe" rget -url "$URL" -etag "$ET" -size "$SZ" -seconds "$STAGE_S" -workers 64 -chunk-mib 64 -every 5 \
      -label "n$s-r$RANK" > "$W/rget.out" 2> "$W/rget.err" &
    p=$!; seen=0
    while kill -0 "$p" 2>/dev/null; do
      sleep 5
      n=$(wc -l < "$W/rget.out")
      if [ "$n" -gt "$seen" ]; then
        sed -n "$((seen + 1)),${n}p" "$W/rget.out" | while read -r l; do echo "$l" >> "$J"; echo "probe-cont $l"; done; seen=$n
      fi
    done
    wait "$p"; rc=$?
    n=$(wc -l < "$W/rget.out")
    [ "$n" -gt "$seen" ] && sed -n "$((seen + 1)),${n}p" "$W/rget.out" | while read -r l; do echo "$l" >> "$J"; echo "probe-cont $l"; done
    [ "$rc" = 0 ] || { tail -3 "$W/rget.err"; ak2_say "stage n$s rget rc=$rc"; FAIL=1; }
    ak2_req GetObject "$(grep '"kind":"done"' "$W/rget.out" | jq -r '.requests')" "$RB"
    ak2_push "$J" "cont-$RANK.jsonl" > /dev/null
  else
    ak2_say "stage n$s: rank $RANK waits"
  fi
done
ak2_phase push
ak2_push "$J" "cont-$RANK.jsonl" || FAIL=1
ak2_say "contention probe done FAIL=$FAIL"
exit "$FAIL"
