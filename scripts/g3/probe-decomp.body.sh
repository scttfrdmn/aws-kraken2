# G3 probe (c) (#25, Scott approved the three cheap probes 2026-10-08): gzip decompression tools
# on the largest cohort sample by bytes, SRR5935773 (both mates, 2.07 GB of gz), on one small
# Graviton4 node (c8g.4xlarge, 16 vCPU: the same core as U1's x8g, and pigz -p 16 as U1's fq
# preparation). Tools: gzip -dc (what upstream's kraken2 wrapper runs on gz input, one process per
# mate), pigz -dc -p 16 (U1's preparation), igzip (ISA-L, python-isal's CLI), rapidgzip -P 16 and
# -P 8. Modes: seq (mate 1 then mate 2, as U1's preparation) and conc (both mates at once, as the
# wrapper's two pipes). Output to /dev/null for timing; each tool's output is also hashed once per
# mate and compared with gzip -dc's (a tool whose output differs is reported, never used).
# Inputs on /dev/shm (tmpfs): the probe times decompression, not storage, so no rung is cold and
# no drop_caches applies. 3 repetitions, tool order rotated per repetition. Every result streams
# as "probe-decomp {json}" and into out/decomp.jsonl, pushed after every repetition.
W=$HOME/ak2; mkdir -p "$W"
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; CK=aws-kraken2/data/cohort; S=SRR5935773
REPS=${AK2_REHEARSE_REPS:-3}; P=16
fail() { ak2_say "ERROR: $*"; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

ak2_phase setup
sudo -n dnf install -y -q git pigz gzip python3-pip perl jq > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf failed"; }
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
PY=${AK2_REHEARSE_PYTHON:-python3}  # make rehearse seam: a local python with the same wheels
"$PY" -m venv "$W/venv" || fail "venv failed"
"$W/venv/bin/pip" install -q --only-binary=:all: "rapidgzip==0.14.5" "isal==1.8.0" > "$W/pip.log" 2>&1 || { tail -5 "$W/pip.log"; fail "pip install failed"; }
RG="$W/venv/bin/rapidgzip"; IG="$W/venv/bin/python -m isal.igzip"
ak2_say "tools: $(gzip --version | head -1); pigz $(pigz --version 2>&1); rapidgzip $("$RG" --version 2>&1 | head -1); isal $("$W/venv/bin/python" -c 'import isal; print(isal.__version__)'); nproc $(nproc)"

ak2_phase fetch-inputs
IN=/dev/shm/ak2-in; [ -n "${AK2_REHEARSE_SHM:-}" ] && IN=$AK2_REHEARSE_SHM
mkdir -p "$IN" || fail "mkdir $IN"
"$W/repo/scripts/g3/fetch.sh" "$B" "$CK" "$IN" 2 "${S}_1.fastq.gz" "${S}_2.fastq.gz" > "$W/fetched.txt" 2>&1
FERR=$?
cat "$W/fetched.txt"
[ "$FERR" = 0 ] && [ "$(grep -vc ERROR "$W/fetched.txt")" = 2 ] || fail "input fetch failed"
ak2_req GetObject "$(awk '!/ERROR/{n += int(($2 + 8388607) / 8388608)} END{print n+0}' "$W/fetched.txt")" "$B"
ak2_req HeadObject 2 "$B"
ak2_say "inputs staged and verified: 2 files, $(awk '{s+=$2} END{printf "%.3f GB", s/1e9}' "$W/fetched.txt")"

# dc TOOL FILE: decompress FILE to stdout with TOOL.
dc() {
  case "$1" in
    gzip) gzip -dc "$2" ;;
    pigz-p16) pigz -dc -p "$P" "$2" ;;
    igzip) $IG -d -c "$2" ;;
    rapidgzip-p16) "$RG" -d -c -P 16 "$2" ;;
    rapidgzip-p8) "$RG" -d -c -P 8 "$2" ;;
  esac
}
TOOLS=(gzip pigz-p16 igzip rapidgzip-p16 rapidgzip-p8)
J="$W/decomp.jsonl"; : > "$J"
emit() { echo "$1" >> "$J"; echo "probe-decomp $1"; }

ak2_phase identity
declare -A REF
for t in "${TOOLS[@]}"; do
  for m in 1 2; do
    h=$(dc "$t" "$IN/${S}_$m.fastq.gz" | sha256sum | cut -d' ' -f1); rc=${PIPESTATUS[0]}
    [ "$t" = gzip ] && REF[$m]=$h
    emit "$(jq -nc --arg t "$t" --argjson m "$m" --arg h "$h" --arg ref "${REF[$m]:-}" --argjson rc "$rc" \
      '{kind:"identity", tool:$t, mate:$m, sha256:$h, identical:($h == $ref and $rc == 0), exit:$rc}')"
  done
done
ak2_push "$J" decomp.jsonl > /dev/null

for ((r = 1; r <= REPS; r++)); do
  ak2_phase "rep-$r"
  n=${#TOOLS[@]}
  for ((i = 0; i < n; i++)); do
    t=${TOOLS[$(( (i + r - 1) % n ))]}
    for mode in seq conc; do
      t0=$(now)
      if [ "$mode" = seq ]; then
        dc "$t" "$IN/${S}_1.fastq.gz" > /dev/null; r1=$?
        dc "$t" "$IN/${S}_2.fastq.gz" > /dev/null; r2=$?
      else
        dc "$t" "$IN/${S}_1.fastq.gz" > /dev/null & p1=$!
        dc "$t" "$IN/${S}_2.fastq.gz" > /dev/null & p2=$!
        wait "$p1"; r1=$?; wait "$p2"; r2=$?
      fi
      t1=$(now)
      emit "$(jq -nc --arg t "$t" --arg mode "$mode" --argjson rep "$r" --arg t0 "$t0" --arg t1 "$t1" --argjson e $(( r1 + r2 )) \
        --arg s "$S" '{kind:"time", sample:$s, tool:$t, mode:$mode, rep:$rep, seconds:(($t1|tonumber)-($t0|tonumber)), exit:$e}')"
    done
  done
  ak2_push "$J" decomp.jsonl > /dev/null
done
bad=$(grep -c '"exit":[1-9]' "$J")
ak2_say "decomp probe done: $(grep -c '"kind":"time"' "$J") timings, $bad non-zero exits"
ak2_phase push
ak2_push "$J" decomp.jsonl || exit 1
[ "$bad" = 0 ] || exit 1
exit 0
