# shellcheck disable=SC2016,SC2024,SC2034  # literal jq/bash text; sudo dnf's log is ours; PARAMS are read below
# G2 input-path sweep I0-I4 (#90; docs/inputpath.md). One instance of one family runs the whole
# matrix for one engine: Standard-8 resident on tmpfs, loaded once per classifier run from RAM
# (upstream at the pin rebuilds nothing between runs: every point after the warm-up is warm),
# and every arm against it:
#   I0  pre-decompressed FASTQ on tmpfs (the families have no instance store; tmpfs is the page
#       cache, warm by construction)
#   I1  the .fastq.gz with --gzip-compressed (upstream's wrapper pipes gzip -dc per mate; ours
#       twice: AK2_DECOMPRESS=pipe, the same pipe, and in process)
#   I2  rapidgzip -d -c -P p --chunk-size 4096 per mate in a process substitution, no
#       --gzip-compressed; p in PS; at the best p (below) also chunk sizes CHUNKS (KiB) and the
#       default pipe size (the pipe-size contrast)
#   I3  I2 with --import-index (the prebuilt index of inputs.tsv), at the best p
#   I4  the BGZF re-encode decoded by rapidgzip, at the best p
# at kraken2 --threads in THREADS, for one paired-end and one single-end sample (inputs.tsv).
# THP: every point runs at MAIN_THP (enabled=always: upstream's table from a tmpfs mounted
# huge=always); with THP_CONTRAST=1 I0 runs again at enabled=never from a huge=never copy.
# Pipe: every rapidgzip decode writes into a pipe raised to PIPE_BYTES by
# scripts/inputpath/pipesz.py (F_SETPIPE_SZ; the size it got is recorded per mate).
# Best p (the rule, recorded in each select line): per sample and threads, among rep 1's I2 points
# at chunk 4096 and PIPE_BYTES with status ok, the smallest p whose wall_s is within 1% of the
# minimum wall_s. Rep 2 reuses rep 1's choice and runs rep 1's points in reverse order.
# Identity (Scott, 2026-10-18): before a rapidgzip configuration decodes a file in a point, that
# exact configuration decodes it to sha256sum, which must equal gzip -dc's; a crash, timeout or
# mismatch is an identity line with ok=false and every point needing it is skipped
# (skipped-identity), never run. A decoder that exits non-zero inside a point makes it a
# decode-crash point (excluded). Law 1: every point's --output and --report sha256 must equal the
# sample's warm-up I0 point's; otherwise a defect line.
# Streams one `inputpath {json}` line per event (also in out/points.jsonl, pushed after every
# point with the point's pidstat CSV, stderr and time records as out/points/<id>.tgz), so a TTL
# kill loses no finished point. A point not started by DEADLINE (launch + TTL - MARGIN_S) is
# skipped (skipped-deadline). drop_caches runs once before the first point; its failure ends the
# run (exit 95, the preamble's rule).
# make rehearse seams (AK2_REHEARSE_*, refused by run.sh in a spec's env): INPUTS_TSV (another
# inputs.tsv), DEADLINE_S (seconds from the measure phase's start; also lifts the 64-vCPU check), THP_ROOT (a fake sysfs root), GO (Go is on
# PATH), RAPIDGZIP / WHEELS (lever.sh's), TMPFS (plain directories instead of tmpfs mounts).
@PARAMS@
W=$HOME/ak2; mkdir -p "$W"
T_START=$(date +%s)
SHA=${AK2_RUN_ID##*-}
B=aws-kraken2-942542972736-us-west-2; DATA=aws-kraken2/data; DBNAME=k2_standard_08_GB_20260626
# Two records: out/events.jsonl, every line streamed (host, tool, db, input, identity, select,
# drop-caches, every point, defect, summary, fatal; field kind); out/points.jsonl, the point
# records only (schema inputpath-point/1, what make inputpath-report reads).
J=$W/events.jsonl; PJ=$W/points.jsonl; : > "$J"; : > "$PJ"
emit() { printf '%s\n' "$1" >> "$J"; printf 'inputpath %s\n' "$1"; }
emit_point() { printf '%s\n' "$1" >> "$PJ"; emit "$(jq -c '{kind:"point"} + .' <<< "$1")"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
THP_F=${AK2_REHEARSE_THP_ROOT:-}/sys/kernel/mm/transparent_hugepage/enabled
THP0=""
cur_thp() { local v; v=$(cat "$THP_F" 2> /dev/null); if [[ $v == *"["* ]]; then v=${v#*[}; v=${v%%]*}; fi; echo "$v"; }
restore_thp() { [ -n "$THP0" ] && [ "$(cur_thp)" != "$THP0" ] && echo "$THP0" | sudo -n tee "$THP_F" > /dev/null 2>&1; }
fail() {
  ak2_say "ERROR: $*"
  emit "$(jq -nc --arg m "$*" '{kind:"fatal", message:$m}' 2> /dev/null || printf '{"kind":"fatal"}')"
  restore_thp; ak2_push "$J" events.jsonl > /dev/null; ak2_push "$PJ" points.jsonl > /dev/null; exit 1
}
ak2_say "shell flags $- (body start)"
# The TTL counts from the launch request, taken as boot - LAUNCH_LEAD_S.
BOOT=$(awk -v n="$T_START" '{printf "%d", n - $1}' /proc/uptime)
DEADLINE=$((BOOT - LAUNCH_LEAD_S + TTL_S - MARGIN_S))
# (make rehearse: AK2_REHEARSE_DEADLINE_S replaces it, counted from the start of the measure phase.)
ak2_say "inputpath: family $FAMILY engine $ENGINE; points start until $(date -u -d "@$DEADLINE" +%FT%TZ 2> /dev/null || echo "$DEADLINE") (TTL ${TTL_S}s, margin ${MARGIN_S}s)"

ak2_phase setup
sudo -n dnf install -y -q git gcc-c++ make zlib-devel perl jq gzip tar findutils python3 python3-pip sysstat time procps-ng util-linux \
  > "$W/dnf.log" 2>&1 || { tail -5 "$W/dnf.log"; fail "dnf install failed"; }
for t in pidstat /usr/bin/time jq perl sha256sum; do command -v "$t" > /dev/null || fail "$t is missing after dnf"; done
git clone -q https://github.com/scttfrdmn/aws-kraken2.git "$W/repo" || fail "clone failed"
git -C "$W/repo" checkout -q "$SHA" || fail "checkout $SHA failed"
cd "$W/repo" || fail "cd repo"
IP=$W/repo/scripts/inputpath
# The inputs first: a missing or incomplete inputs.tsv fails here, before any build or stage.
ITSV=${AK2_REHEARSE_INPUTS_TSV:-scripts/inputpath/inputs.tsv}
ROWS=$(python3 "$IP/inputs.py" check "$ITSV" --accessions "$AK2_ACCESSIONS" 2>&1) || fail "inputs: $ROWS"
emit "$(jq -nc --arg f "$ITSV" --arg sha "$(sha256sum "$ITSV" | cut -d' ' -f1)" --argjson n "$(grep -c . <<< "$ROWS")" \
  '{kind:"inputs-tsv", file:$f, sha256:$sha, rows:$n}')"

NPROC=$(nproc)
THP0=$(cur_thp)
[ -n "$THP0" ] || fail "cannot read $THP_F"
emit "$(jq -nc --arg fam "$FAMILY" --arg eng "$ENGINE" --arg type "${AK2_INSTANCE_TYPE:-}" --arg ami "${AK2_AMI:-}" \
  --argjson nproc "$NPROC" --arg mem "$(awk '/^MemTotal/{print $2}' /proc/meminfo)" --arg kern "$(uname -r)" \
  --arg cpu "$(lscpu 2> /dev/null | awk -F: '/Model name/{gsub(/^ +/, "", $2); print $2; exit}')" \
  --arg thp "$(cat "$THP_F" 2> /dev/null)" \
  --arg defrag "$(cat "${AK2_REHEARSE_THP_ROOT:-}/sys/kernel/mm/transparent_hugepage/defrag" 2> /dev/null)" \
  --arg shmem "$(cat "${AK2_REHEARSE_THP_ROOT:-}/sys/kernel/mm/transparent_hugepage/shmem_enabled" 2> /dev/null)" \
  --arg pmax "$(cat /proc/sys/fs/pipe-max-size 2> /dev/null)" --arg params "$PARAMS_LINE" \
  '{kind:"host", family:$fam, engine:$eng, instance_type:$type, ami:$ami, nproc:$nproc, mem_total_kb:($mem|tonumber? // null),
    kernel:$kern, cpu:$cpu, thp_enabled_boot:$thp, thp_defrag:$defrag, thp_shmem_enabled:$shmem,
    pipe_max_size:($pmax|tonumber? // null), params:$params}')"
[ "$NPROC" -ge 64 ] || [ -n "${AK2_REHEARSE_DEADLINE_S:-}" ] || fail "nproc $NPROC: the sweep is sized for a 64-vCPU host"

# The engine, built while the inputs stage.
BUILD_PID=""
if [ "$ENGINE" = upstream ]; then
  ( scripts/oracle-build.sh > "$W/build.out" 2> "$W/build.err" ) &
  BUILD_PID=$!
else
  if [ -z "${AK2_REHEARSE_GO:-}" ]; then
    GOV=$(awk '$1=="go"{print $2}' go.mod)
    curl -fsSL --retry 5 --retry-delay 5 "https://go.dev/dl/go$GOV.linux-arm64.tar.gz" -o "$W/go.tgz" || fail "Go $GOV download failed"
    tar -xzf "$W/go.tgz" -C "$W" || fail "Go unpack failed"
    export PATH="$W/go/bin:$PATH"
  fi
  ( make build > "$W/build.out" 2> "$W/build.err" ) &
  BUILD_PID=$!
fi
LV_DIR=$W/lever
# shellcheck source=/dev/null
. scripts/g3/lever.sh || fail "lever.sh did not load"
lv__rg_ensure || fail "rapidgzip $LV_RG_VERSION (lever.sh) install failed"
RG=$LV_RG
RGI=$W/rapidgzip-info.txt
{ echo "== $RG --version"; "$RG" --version 2>&1; echo "== $RG --help"; "$RG" --help 2>&1
  echo "== $RG --oss-attributions"; "$RG" --oss-attributions 2>&1
  echo "== extension"; find "$LV_DIR/rg-venv" -name 'rapidgzip*.so' -exec sh -c 'echo "$1"; sha256sum "$1"; (ldd "$1" 2>&1 || true)
    echo "== isal symbols in $1: $(grep -a -o -E "isal_[a-z0-9_]+" "$1" | sort -u | head -8 | tr "\n" " ")"' _ {} \; 2> /dev/null
} > "$RGI"
# ISA-L (the plan: confirm the Graviton wheel has it). The wheel's extension is stripped, so the
# evidence is its --oss-attributions (the libraries compiled in) and isal_ strings in the
# extension: yes if the attributions name ISA-L; no if they list libraries, none ISA-L, and the
# extension has no isal_ string; unknown otherwise (they disagree, or there is no extension).
ATTR=$(awk '/^== .*--oss-attributions$/ {f = 1; next} /^== / {f = 0} f && /^# / {print substr($0, 3)}' "$RGI" | tr '\n' ',' | sed 's/,$//')
SYMS=$(sed -n 's/^== isal symbols in [^:]*: //p' "$RGI" | tr -d ' ')
ISAL=unknown
if grep -q -i -E 'isa-?l' <<< "$ATTR"; then ISAL=yes
elif [ -n "$ATTR" ] && [ -z "$SYMS" ] && grep -q '^== isal symbols in ' "$RGI"; then ISAL=no; fi
ISAL_EV="oss-attributions: ${ATTR:-none}; isal_ strings in the extension: ${SYMS:-none}"
emit "$(jq -nc --arg v "$LV_RG_VERSION" --arg rv "$("$RG" --version 2>&1 | head -1)" --arg path "$RG" \
  --arg whl "$(find "$LV_DIR/rg-wheels" -name 'rapidgzip-*.whl' 2> /dev/null | head -1 | xargs -r basename)" \
  --arg wsha "$(find "$LV_DIR/rg-wheels" -name 'rapidgzip-*.whl' 2> /dev/null | head -1 | xargs -r sha256sum | cut -d' ' -f1)" \
  --arg isal "$ISAL" --arg ev "$ISAL_EV" --arg info "$(sha256sum "$RGI" | cut -d' ' -f1)" \
  '{kind:"tool", name:"rapidgzip", version:$v, reports:$rv, path:$path, build:("PyPI wheel " + $whl), wheel_sha256:$wsha,
    isal:$isal, isal_evidence:$ev, info_file:"rapidgzip-info.txt", info_sha256:$info}')"
ak2_push "$RGI" rapidgzip-info.txt > /dev/null

# ---- RAM: the database, the inputs, the outputs (tmpfs) ----
ak2_phase stage
mnt() {  # DIR SIZE HUGE
  if [ -n "${AK2_REHEARSE_TMPFS:-}" ]; then mkdir -p "$1" && chmod 1777 "$1"; return; fi
  sudo -n mkdir -p "$1" && sudo -n mount -t tmpfs -o "size=$2,huge=$3,mode=1777" tmpfs "$1"
}
R=${AK2_REHEARSE_TMPFS:-/mnt}
DBN=$R/ip-db; DBH=$R/ip-db-huge; IN=$R/ip-in; OUT=$R/ip-out
mnt "$DBN" 12g never || fail "tmpfs $DBN"
mnt "$IN" 90g never || fail "tmpfs $IN"
mnt "$OUT" 24g never || fail "tmpfs $OUT"
for f in opts.k2d taxo.k2d hash.k2d; do
  ak2_stage "s3://$B/$DATA/$DBNAME/$f" "$DBN/$f" || fail "stage of $DBNAME/$f failed"
  s=$(stat -c%s "$DBN/$f")
  ak2_req GetObject $(( s < 8388608 ? 1 : (s + 8388607) / 8388608 )) "$B"
  want=$(aws s3api head-object --bucket "$B" --key "$DATA/$DBNAME/$f" --query Metadata.sha256 --output text)
  ak2_req HeadObject 1 "$B"
  got=$(sha256sum "$DBN/$f" | cut -d' ' -f1)
  [ "$got" = "$want" ] || fail "$DBNAME/$f sha256 $got != metadata $want"
  emit "$(jq -nc --arg f "$f" --arg sha "$got" --argjson b "$s" --arg d "$DBN" '{kind:"db", file:$f, sha256:$sha, bytes:$b, dir:$d}')"
done
if [ "$ENGINE" = upstream ] && { [ "$MAIN_THP" = always ] || [ "$THP_CONTRAST" = 1 ]; }; then
  mnt "$DBH" 12g always || fail "tmpfs $DBH (huge=always)"
  cp "$DBN/opts.k2d" "$DBN/taxo.k2d" "$DBN/hash.k2d" "$DBH/" || fail "copy to $DBH failed"
  for f in opts.k2d taxo.k2d hash.k2d; do cmp -s "$DBN/$f" "$DBH/$f" || fail "$DBH/$f differs from $DBN/$f"; done
  emit "$(jq -nc --arg d "$DBH" --arg shp "$(awk '/^ShmemHugePages/{print $2}' /proc/meminfo)" '{kind:"db-huge", dir:$d, huge:"always", shmem_huge_pages_kb:($shp|tonumber? // null)}')"
fi
# Inputs: every object staged and checked against its row; FASTQ derived with gzip -dc (its sha256
# is the reference every decode must equal); the BGZF's gzip -dc must equal it too.
declare -A REF=() OSHA=() FQB=() KEYS=()
while IFS=$'\t' read -r role acc mate bkt key osha kind src; do
  [ "$kind" = fastq ] && continue
  n="${role}_$mate.$kind"
  ak2_stage "s3://$bkt/$key" "$IN/$n" || fail "stage of s3://$bkt/$key failed"
  s=$(stat -c%s "$IN/$n"); ak2_req GetObject $(( s < 8388608 ? 1 : (s + 8388607) / 8388608 )) "$bkt"
  got=$(sha256sum "$IN/$n" | cut -d' ' -f1)
  [ "$got" = "$osha" ] || fail "$key: sha256 $got != inputs.tsv $osha"
  OSHA[$n]=$got; KEYS[$n]=$key
done <<< "$ROWS"
DERIVE=()
for f in "$IN"/*.gz; do
  ( gzip -dc "$f" | tee "${f%.gz}.fq" | sha256sum | cut -d' ' -f1 > "$f.ref"; [ "${PIPESTATUS[0]}" = 0 ] ) &
  DERIVE+=($!)
done
for f in "$IN"/*.bgzf; do
  ( gzip -dc "$f" | sha256sum | cut -d' ' -f1 > "$f.ref"; [ "${PIPESTATUS[0]}" = 0 ] ) &
  DERIVE+=($!)
done
for p in "${DERIVE[@]}"; do wait "$p" || fail "gzip -dc of an input failed"; done
while IFS=$'\t' read -r role acc mate bkt key osha kind src; do
  m="${role}_$mate"; ref=$(cat "$IN/$m.gz.ref")
  REF[$m]=$ref
  case $kind in
    gz) ok=$([ "$src" = - ] || [ "$src" = "$ref" ] && echo true || echo false) ;;
    fastq) ok=$([ "$osha" = "$ref" ] && echo true || echo false) ;;
    bgzf) [ "$(cat "$IN/$m.bgzf.ref")" = "$ref" ] || fail "$key: gzip -dc gives $(cat "$IN/$m.bgzf.ref"), not $m.gz's $ref"
          ok=$([ "$src" = - ] || [ "$src" = "$ref" ] || [ "$src" = "${OSHA[$m.gz]}" ] && echo true || echo false) ;;
    index) ok=$([ "$src" = - ] || [ "$src" = "$ref" ] || [ "$src" = "${OSHA[$m.gz]}" ] && echo true || echo false) ;;
  esac
  [ "$ok" = true ] || fail "$key ($kind): source_sha256 $src is neither $m's FASTQ ($ref) nor its gz (${OSHA[$m.gz]})"
  [ "$kind" = gz ] && FQB[$m]=$(stat -c%s "$IN/$m.fq")
  emit "$(jq -nc --arg role "$role" --arg acc "$acc" --arg mate "$mate" --arg uri "s3://$bkt/$key" --arg sha "$osha" --arg kind "$kind" \
    --arg src "$src" --arg ref "$ref" --arg file "$IN/$m.$kind" --arg b "$(stat -c%s "$IN/$m.$kind" 2> /dev/null)" --arg fqb "${FQB[$m]:-}" \
    '{kind:"input", role:$role, accession:$acc, mate:($mate|tonumber), uri:$uri, sha256:$sha, input_kind:$kind, source_sha256:$src,
      fastq_sha256:$ref, file:(if $kind == "fastq" then null else $file end), bytes:($b|tonumber? // null), fastq_bytes:($fqb|tonumber? // null)}')"
done <<< "$ROWS"
FQ_PE=$(( FQB[pe_1] + FQB[pe_2] )); FQ_SE=${FQB[se_1]}
ACC_PE=$(awk -F'\t' '$1 == "pe" {print $2; exit}' <<< "$ROWS"); ACC_SE=$(awk -F'\t' '$1 == "se" {print $2; exit}' <<< "$ROWS")

wait "$BUILD_PID" || { tail -30 "$W/build.err"; fail "the $ENGINE build failed"; }
if [ "$ENGINE" = upstream ]; then
  K2DIR=$(scripts/oracle-build.sh 2> /dev/null) || fail "upstream build not found"
  BIN=$K2DIR/kraken2; BUILD=$(tr '\n' ';' < "$K2DIR/BUILD")
else
  BIN=$W/repo/bin/aws-kraken2; BUILD="ours $(git rev-parse HEAD); $(go version 2> /dev/null)"
fi
[ -x "$BIN" ] || fail "no classifier at $BIN"
emit "$(jq -nc --arg e "$ENGINE" --arg bin "$BIN" --arg b "$BUILD" '{kind:"engine", engine:$e, bin:$bin, build:$b}')"
ak2_push "$J" events.jsonl > /dev/null
ak2_push "$LV_REC" lever.jsonl > /dev/null

# ---- the points ----
TFMT='ak2time wall_s=%e maxrss_kb=%M exit=%x user_s=%U sys_s=%S'
TIMEQ=$(printf '/usr/bin/time -f %q' "$TFMT")
declare -A IDS=() IDJ=() BESTP=()
POINTS_DONE=0; DEFECTS=0
RGJ=$(jq -nc --arg v "$LV_RG_VERSION" --arg isal "$ISAL" '{version:$v, build:"pypi", isal:(if $isal == "yes" then true elif $isal == "no" then false else null end)}')
set_thp() {
  [ "$(cur_thp)" = "$1" ] && return 0
  echo "$1" | sudo -n tee "$THP_F" > /dev/null 2>&1
  [ "$(cur_thp)" = "$1" ] || fail "THP enabled=$1 was not applied (reads $(cur_thp))"
}
time_exit() { awk '/terminated by signal/ {s = 128 + $NF} /ak2time/ {for (i = 1; i <= NF; i++) if ($i ~ /^exit=/) e = substr($i, 6)} END {print (s != "" ? s : (e != "" ? e : "missing"))}' "$1" 2> /dev/null || echo missing; }
# identity FILE MATEKEY ARGS...: that rapidgzip configuration on FILE, to sha256sum, against gzip -dc's.
identity() {
  local f=$1 m=$2; shift 2
  local key="$f|$*" tf=$W/identity.time t0 t1 got rc ex st=ok line
  case ${IDS[$key]:-} in ok) return 0 ;; ?*) return 1 ;; esac
  rm -f "$tf"; t0=$(now)
  got=$(timeout -k 30 "$ID_TIMEOUT" /usr/bin/time -f "$TFMT" -o "$tf" "$RG" -d -c "$@" "$f" 2> "$W/identity.err" | sha256sum | cut -d' ' -f1)
  rc=${PIPESTATUS[0]}; t1=$(now)
  ex=$(time_exit "$tf")
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then st=timeout; elif [ "$rc" != 0 ] || [ "$ex" != 0 ]; then st=crash; elif [ "$got" != "${REF[$m]}" ]; then st=mismatch; fi
  IDS[$key]=$st
  line=$(jq -nc --arg f "$f" --arg m "$m" --arg args "$*" --arg st "$st" --arg rc "$rc" --arg ex "$ex" --arg got "$got" --arg want "${REF[$m]}" \
    --arg t0 "$t0" --arg t1 "$t1" --arg fqb "${FQB[$m]}" --arg err "$(tail -c 400 "$W/identity.err")" \
    '{kind:"identity", file:$f, mate:$m, args:$args, status:$st, ok:($st == "ok"), exit:($rc|tonumber? // $rc), decoder_exit:($ex|tonumber? // $ex),
      sha256:$got, want_sha256:$want, seconds:(($t1|tonumber) - ($t0|tonumber)),
      mb_per_s:(($fqb|tonumber) / (($t1|tonumber) - ($t0|tonumber)) / 1e6), stderr_tail:(if $st == "ok" then null else $err end)}')
  emit "$line"
  IDJ[$key]=$(jq -c '{mate:(.mate | split("_")[1] | tonumber), gz_sha256:.want_sha256, rg_sha256:.sha256,
    rg_exit:(if (.decoder_exit|type) == "number" then .decoder_exit else 255 end), ok, status, args}' <<< "$line")
  [ "$st" = ok ]
}
# point REP SAMPLE ARM T P CHUNK PIPE THP DECOMP [WARMUP]: one classifier run (- for n/a), recorded
# by scripts/inputpath/record.py (schema inputpath-point/1).
point() {
  local rep=$1 s=$2 arm=$3 t=$4 p=$5 ck=$6 pipe=$7 thp=$8 dec=$9 warm=${10:-0}
  local id="r$rep-$s-$arm-t$t-p$p-c$ck-pipe$pipe-thp$thp-$dec"; [ "$warm" = 1 ] && id="warmup-$s"
  id=${id//[^A-Za-z0-9._-]/_}
  local D=$W/pts/$id paired=0 fqb=$FQ_SE mates="1" db=$DBN files="" m rgargs="" envp="" sho="" shr="" rec st idl="[]" mj="[]" kind=gz
  [ "$s" = pe ] && { paired=1; fqb=$FQ_PE; mates="1 2"; }
  [ "$ENGINE" = upstream ] && [ "$thp" = always ] && [ -s "$DBH/hash.k2d" ] && db=$DBH
  [ "$arm" = I4 ] && kind=bgzf
  rm -rf "$D"; mkdir -p "$D"
  for m in $mates; do
    mj=$(jq -c --argjson m "$m" --arg k "${KEYS[${s}_$m.$kind]}" --arg h "${OSHA[${s}_$m.$kind]}" --arg f "${REF[${s}_$m]}" \
      --arg ik "${KEYS[${s}_$m.index]}" --arg ih "${OSHA[${s}_$m.index]}" \
      '. + [{mate:$m, s3_key:$k, sha256:$h, fastq_sha256:$f, index_s3_key:$ik, index_sha256:$ih}]' <<< "$mj")
  done
  local skip=""
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then skip="deadline: not started before the run's deadline (launch + TTL - margin)"
  elif [ "$warm" != 1 ] && [ ! -s "$W/ref-$s.json" ]; then skip="no-reference: the sample's warm-up I0 did not give a reference"
  fi
  case $arm in
    I0) for m in $mates; do files="$files $IN/${s}_$m.fq"; done ;;
    I1) for m in $mates; do files="$files $IN/${s}_$m.gz"; done; files=" --gzip-compressed$files"
        [ "$dec" = pipe ] && envp="env AK2_DECOMPRESS=pipe "; [ "$dec" = inproc ] && envp="env -u AK2_DECOMPRESS " ;;
    I2|I3|I4)
      if [ -z "$skip" ] && [ "$p" = - ]; then skip="no-best-p: rep 1 gave no usable I2 point at these threads"; fi
      for m in $mates; do
        [ -n "$skip" ] && break
        local src=$IN/${s}_$m.gz
        case $arm in
          I2) rgargs="-P $p --chunk-size $ck" ;;
          I3) rgargs="-P $p --import-index $IN/${s}_$m.index" ;;
          I4) rgargs="-P $p --chunk-size $ck"; src=$IN/${s}_$m.bgzf ;;
        esac
        # shellcheck disable=SC2086  # rgargs is a word list
        identity "$src" "${s}_$m" $rgargs || skip="identity: rapidgzip $rgargs on $(basename "$src") was ${IDS[$src|$rgargs]} in its identity check"
        idl=$(jq -c --argjson i "${IDJ[$src|$rgargs]:-null}" '. + [$i]' <<< "$idl")
        files="$files <(python3 $IP/pipesz.py $pipe $D/pipe$m.txt $TIMEQ -o $D/rg$m.time $RG -d -c $rgargs $src)"
      done ;;
  esac
  local cmd="$envp$TIMEQ -o $D/k2.time $BIN --db $db --threads $t$([ "$paired" = 1 ] && echo " --paired") --output $OUT/output --report $OUT/report$files"
  jq -n --arg id "$id" --argjson rep "$rep" --argjson warm "$warm" --arg fam "$FAMILY" --arg eng "$ENGINE" --arg it "${AK2_INSTANCE_TYPE:-}" \
    --arg dbn "$DBNAME" --arg db "$db" --arg s "$s" --arg acc "$([ "$s" = pe ] && echo "$ACC_PE" || echo "$ACC_SE")" --arg arm "$arm" \
    --argjson t "$t" --arg p "$p" --arg ck "$ck" --arg pipe "$pipe" --arg thp "$thp" --arg dec "$dec" --argjson fqb "$fqb" \
    --argjson nproc "$NPROC" --argjson mates "$mj" --argjson ids "$idl" --argjson rg "$RGJ" --arg cmd "$cmd" '
    {id:$id, rep:$rep, warmup:($warm == 1), family:$fam, engine:$eng, instance_type:$it, db:$dbn, db_dir:$db, role:$s, accession:$acc,
     arm:$arm, threads:$t, p:($p|tonumber? // null), chunk_kib:($ck|tonumber? // null), pipe_requested:$pipe, thp_requested:$thp,
     decomp:$dec, fq_bytes:$fqb, nproc:$nproc, mates:$mates, identity:$ids, rapidgzip:$rg, cmd:$cmd}' > "$D/params.json"
  if [ -n "$skip" ]; then
    rec=$(python3 "$IP/record.py" --params "$D/params.json" --skip "$skip")
    emit_point "$rec"; return 0
  fi
  set_thp "$thp"
  rm -rf "${OUT:?}"/*
  printf '%s\n' "$cmd" > "$D/cmd.txt"
  python3 "$IP/run_point.py" --dir "$D" --fq-bytes "$fqb" --paired "$paired" --timeout "$POINT_TIMEOUT" -- "$cmd" > "$D/result.json" 2> "$D/run_point.err"
  [ -s "$OUT/output" ] && sho=$(sha256sum "$OUT/output" | cut -d' ' -f1)
  [ -s "$OUT/report" ] && shr=$(sha256sum "$OUT/report" | cut -d' ' -f1)
  rec=$(python3 "$IP/record.py" --params "$D/params.json" --result "$D/result.json" --dir "$D" --thp "$(cur_thp)" \
    --pidstat-csv "out/pidstat/$id.csv" --output-sha256 "$sho" --report-sha256 "$shr" --reference "$W/ref-$s.json" 2> "$D/record.err")
  jq -e . <<< "$rec" > /dev/null 2>&1 || fail "record.py failed on $id: $(tail -c 300 "$D/record.err")"
  st=$(jq -r '.harness.status_detail' <<< "$rec")
  [ "$st" = reference ] && jq -c '{output_sha256, report_sha256, sequences:.harness.sequences, point_id}' <<< "$rec" > "$W/ref-$s.json"
  emit_point "$rec"
  if [ "$(jq -r .status <<< "$rec")" = defect ]; then
    DEFECTS=$((DEFECTS + 1))
    emit "$(jq -c '{kind:"defect", point_id, arm, threads, p, status_detail:.harness.status_detail, note}' <<< "$rec")"
  fi
  [ -s "$D/pidstat.csv" ] && ak2_push "$D/pidstat.csv" "pidstat/$id.csv" > /dev/null
  rm -f "$D/pidstat.txt"
  tar -czf "$W/pt.tgz" -C "$D" . 2> /dev/null && ak2_push "$W/pt.tgz" "points/$id.tgz" > /dev/null
  ak2_push "$PJ" points.jsonl > /dev/null
  rm -rf "${OUT:?}"/*
  POINTS_DONE=$((POINTS_DONE + 1))
}
# select_p SAMPLE T: rep 1's best p for that sample and thread count (the rule in the header).
select_p() {
  local s=$1 t=$2 bp role=single
  [ "$s" = pe ] && role=paired
  bp=$(jq -s -r --arg r "$role" --argjson t "$t" --arg pipe "$PIPE_BYTES" --arg thp "$MAIN_THP" '
    [.[] | select(.rep == 1 and .input.role == $r and .arm == "I2" and .threads == $t and .chunk_mib == 4
      and .harness.pipe_requested == $pipe and .harness.thp_requested == $thp and .status == "ok" and .wall_s != null)] as $c
    | if ($c | length) == 0 then "-" else ($c | map(.wall_s) | min) as $m | [$c[] | select(.wall_s <= $m * 1.01) | .p] | min | tostring end' "$PJ")
  BESTP[$s:$t]=$bp
  emit "$(jq -nc --arg s "$s" --arg r "$role" --argjson t "$t" --arg bp "$bp" --slurpfile all "$PJ" '{kind:"select", sample:$s, threads:$t, best_p:($bp|tonumber? // null),
    rule:"rep 1 I2 points at chunk 4 MiB, the main pipe size and THP, status ok: the smallest p with wall_s <= 1.01 x the minimum wall_s",
    candidates:[$all[] | select(.rep == 1 and .input.role == $r and .arm == "I2" and .threads == $t and .chunk_mib == 4) | {p, wall_s, status, point_id}]}')"
}
OTHER_THP=never; [ "$MAIN_THP" = never ] && OTHER_THP=always
# Rep 1's list, sample by sample (the smaller FASTQ first: cheapest first), built as it runs
# (the best p comes from its own I2 points); rep 2 runs the same list reversed.
SAMPLES="se pe"; [ "$FQ_PE" -lt "$FQ_SE" ] && SAMPLES="pe se"
LIST=()
run1() { LIST+=("$*"); point 1 "$@"; }
ak2_drop_caches
emit "$(jq -nc --arg m "$(awk '/^(MemAvailable|Shmem):/{printf "%s=%s ", $1, $2}' /proc/meminfo)" '{kind:"drop-caches", ok:true, meminfo:$m}')"
ak2_phase measure
[ -n "${AK2_REHEARSE_DEADLINE_S:-}" ] && DEADLINE=$(( $(date +%s) + AK2_REHEARSE_DEADLINE_S ))
TMAX=$(tr ' ' '\n' <<< "$THREADS" | sort -n | tail -1)
for s in $SAMPLES; do
  point 1 "$s" I0 "$TMAX" - - - "$MAIN_THP" - 1
  for t in $THREADS; do run1 "$s" I0 "$t" - - - "$MAIN_THP" -; done
  [ "$THP_CONTRAST" = 1 ] && for t in $THREADS; do run1 "$s" I0 "$t" - - - "$OTHER_THP" -; done
  for p in $PS; do for t in $THREADS; do run1 "$s" I2 "$t" "$p" 4096 "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done; done
  for t in $THREADS; do select_p "$s" "$t"; done
  for t in $THREADS; do run1 "$s" I3 "$t" "${BESTP[$s:$t]}" - "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done
  for t in $THREADS; do run1 "$s" I4 "$t" "${BESTP[$s:$t]}" 4096 "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done
  for c in $CHUNKS; do for t in $THREADS; do run1 "$s" I2 "$t" "${BESTP[$s:$t]}" "$c" "$PIPE_BYTES" "$MAIN_THP" rapidgzip; done; done
  [ "$PIPE_CONTRAST" = 1 ] && for t in $THREADS; do run1 "$s" I2 "$t" "${BESTP[$s:$t]}" 4096 default "$MAIN_THP" rapidgzip; done
  if [ "$ENGINE" = ours ]; then
    for t in $THREADS; do run1 "$s" I1 "$t" - - - "$MAIN_THP" inproc; done
    for t in $THREADS; do run1 "$s" I1 "$t" - - - "$MAIN_THP" pipe; done
  else
    for t in $THREADS; do run1 "$s" I1 "$t" - - - "$MAIN_THP" wrapper-gzip; done
  fi
done
for ((rep = 2; rep <= REPS; rep++)); do
  for ((i = ${#LIST[@]} - 1; i >= 0; i--)); do
    # shellcheck disable=SC2086  # a list entry is a word list
    point "$rep" ${LIST[$i]}
  done
done
ak2_phase wrapup
restore_thp
python3 "$IP/tables.py" "$PJ" "$W/inputpath.tsv" > "$W/tables.log" 2>&1 || ak2_say "WARN: tables.py failed: $(tail -3 "$W/tables.log")"
[ -s "$W/inputpath.tsv" ] && ak2_push "$W/inputpath.tsv" inputpath.tsv > /dev/null
emit "$(jq -s -c --argjson d "$DEFECTS" --arg thp0 "$THP0" --arg thp "$(cur_thp)" --slurpfile ev "$J" '{kind:"summary", points:length,
  by_status:(group_by(.status) | map({key:.[0].status, value:length}) | from_entries),
  by_detail:(group_by(.harness.status_detail) | map({key:.[0].harness.status_detail, value:length}) | from_entries),
  identity:([$ev[] | select(.kind == "identity")] | group_by(.status) | map({key:.[0].status, value:length}) | from_entries),
  defects:$d, thp_boot:$thp0, thp_restored:($thp == $thp0)}' "$PJ")"
ak2_push "$PJ" points.jsonl > /dev/null
ak2_push "$J" events.jsonl > /dev/null
ak2_push "$LV_REC" lever.jsonl > /dev/null
ak2_say "inputpath: $POINTS_DONE points run, $DEFECTS defects"
exit 0
