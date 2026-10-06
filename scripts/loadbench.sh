#!/usr/bin/env bash
# make loadbench (issue #36; docs/loadbench.md): load-path and whole-process wall time of upstream
# kraken2 at the pin and of bin/aws-kraken2 (plus any ladder builds) on one database and thread
# count, cold and warm page cache, every run timed by the same instrument (scripts/lib/lbrun.py).
#
# Usage: scripts/loadbench.sh            (run directly, or `make loadbench`)
#        . scripts/loadbench.sh          (sourced by an AWS spec body: then cold rungs use the
#                                         preamble's ak2_drop_caches, every rung is an ak2_phase,
#                                         and runs.tsv is pushed after every rung)
# Env:   LB_DB       viral | standard8 | a database directory           (default standard8)
#        LB_THREADS  classifier threads                                 (default 8)
#        LB_REPS     repetitions of each rung                           (default 3)
#        LB_REPS_COLD, LB_REPS_WARM  per-state repetitions             (default LB_REPS)
#        LB_WARMUP   1 = before the matrix, unrecorded cold runs of the first implementation on
#                    the first input (their numbers go to the manifest as "warmups")  (default 1)
#        LB_WARMUPS  how many such warm-up runs                          (default 1)
#        LB_STATES   page-cache states, in order: "cold warm", "warm"   (default "cold warm")
#        LB_INPUTS   inputs, cheapest first: empty (no reads: startup + load + teardown),
#                    se (SRR062634 200k mate 1), pe (SRR062634 200k, --paired) (default "empty pe")
#        LB_IMPLS    implementations: upstream, ours, and LABEL=BINARY      (default "upstream ours")
#        LB_LADDER   a file of "LABEL COMMIT [NAME=VALUE...]" lines (COMMIT may be HEAD); each COMMIT's cmd/aws-kraken2
#                    is built and benchmarked as LABEL, with that environment (@NCPU is replaced
#                    by the online CPU count): the per-change attribution, Law 5   (default none)
#        LB_PROFILE  1 = afterwards, perf stat (Linux, if perf exists) of every implementation,
#                    cold and warm, and a pprof CPU profile plus gctrace of ours  (default 0)
#        LB_GATE     results/<gate>/                                    (default g2)
#        LB_ENV      extra NAME=VALUE words for every classifier run (e.g. K2_DB_READ_THREADS=8)
#        LB_READS    directory holding SRR062634_200000_{1,2}.fq        (default .cache/reads)
#        LB_PROFILE_IMPLS  with LB_PROFILE=1, profile only these labels   (default all)
# Writes results/<gate>/loadbench-<db>-<UTC timestamp>/: manifest.json, runs.tsv (one row per
# run), timings.tsv (ours' AK2_TIMINGS phases), summary.tsv, summary.md, stderr/, profile/.
# Cold: before every cold rung the page cache is dropped (Linux drop_caches, macOS purge). If
# that is impossible the cold rungs are skipped and the manifest says so; a warm run is never
# labelled cold.
set +e
LB_SOURCED=0
(return 0 2>/dev/null) && LB_SOURCED=1
[ "$LB_SOURCED" = 1 ] || set -uo pipefail
LB_START_DIR=$PWD
cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "loadbench: no repo" >&2; return 1 2>/dev/null || exit 1; }
ROOT=$PWD
. scripts/pin.env
. scripts/paths.sh
echo "loadbench: shell flags $-"

lb_main() {
  local DBSEL=${LB_DB:-standard8} TH=${LB_THREADS:-8} REPS=${LB_REPS:-3}
  local REPS_COLD=${LB_REPS_COLD:-${LB_REPS:-3}} REPS_WARM=${LB_REPS_WARM:-${LB_REPS:-3}}
  local WARMUP=${LB_WARMUP:-1} WARMUPS=${LB_WARMUPS:-1} WARMUP_JSON=null
  local STATES=${LB_STATES:-cold warm} INPUTS=${LB_INPUTS:-empty pe}
  local IMPLS=${LB_IMPLS:-upstream ours} LADDER=${LB_LADDER:-} PROFILE=${LB_PROFILE:-0}
  local GATE=${LB_GATE:-g2} EXTRA_ENV=${LB_ENV:-} PROFILE_IMPLS=${LB_PROFILE_IMPLS:-}
  local t
  for t in jq python3 awk; do
    command -v "$t" >/dev/null || { echo "loadbench: need $t" >&2; return 1; }
  done
  if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
  else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

  local DBDIR
  case "$DBSEL" in
    viral) DBDIR="$K2_DB_ROOT/k2_viral_20260626" ;;
    standard8) DBDIR="$K2_DB_ROOT/k2_standard_08_GB_20260626" ;;
    /*) DBDIR=$DBSEL ;;
    *) DBDIR="$LB_START_DIR/$DBSEL" ;;
  esac
  for t in hash.k2d opts.k2d taxo.k2d; do
    [ -s "$DBDIR/$t" ] || { echo "loadbench: $DBDIR/$t missing (make stage-db or fetch-db)" >&2; return 1; }
  done
  local DBNAME; DBNAME=$(basename "$DBDIR")
  local READS=${LB_READS:-$K2_READS}
  local S1="$READS/SRR062634_200000"
  case " $INPUTS " in *" se "*|*" pe "*)
    for t in "${S1}_1.fq" "${S1}_2.fq"; do
      [ -s "$t" ] || { echo "loadbench: $t missing (make stage-reads / fetch-reads)" >&2; return 1; }
    done ;;
  esac

  # ---- implementations ----------------------------------------------------------------------
  local K2DIR
  K2DIR=$(scripts/oracle-build.sh) || { echo "loadbench: upstream build failed" >&2; return 1; }
  . scripts/pin-identity.sh
  pin_identity || { echo "loadbench: cannot establish the upstream pin identity" >&2; return 1; }
  make -s build || { echo "loadbench: go build failed" >&2; return 1; }
  local NCPU; NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)
  local -a LABELS=() BINS=() SRCS=() ENVS=()
  local spec
  for spec in $IMPLS; do
    case "$spec" in
      upstream) LABELS+=(upstream); BINS+=("$K2DIR/kraken2"); SRCS+=("upstream@$UPSTREAM_PIN"); ENVS+=("") ;;
      ours) LABELS+=(ours); BINS+=("$ROOT/bin/aws-kraken2"); SRCS+=("$(git rev-parse HEAD)"); ENVS+=("") ;;
      *=*) LABELS+=("${spec%%=*}"); BINS+=("${spec#*=}"); SRCS+=("given"); ENVS+=("") ;;
      *) echo "loadbench: unknown implementation '$spec'" >&2; return 1 ;;
    esac
  done
  if [ -n "$LADDER" ]; then
    local label commit dst lenv
    while read -r label commit lenv; do
      case "$label" in ''|'#'*) continue ;; esac
      commit=$(git rev-parse --verify -q "$commit^{commit}") ||
        { echo "loadbench: ladder $label: no such commit" >&2; return 1; }
      dst="$ROOT/.cache/loadbench/bin/$(go env GOOS)-$(go env GOARCH)/$commit"
      if [ ! -x "$dst/aws-kraken2" ]; then
        rm -rf "$dst.src" && mkdir -p "$dst.src" "$dst" &&
          git archive "$commit" | tar -x -C "$dst.src" &&
          go build -C "$dst.src" -trimpath -ldflags "-X main.upstreamPin=$UPSTREAM_PIN" \
            -o "$dst/aws-kraken2" ./cmd/aws-kraken2 ||
          { echo "loadbench: cannot build ladder $label at $commit" >&2; return 1; }
        rm -rf "$dst.src"
      fi
      LABELS+=("$label"); BINS+=("$dst/aws-kraken2"); SRCS+=("$commit")
      ENVS+=("${lenv//@NCPU/$NCPU}")
    done < "$LADDER"
  fi

  # ---- cold: can the page cache be dropped? ---------------------------------------------------
  local COLD_OK=false DROP_METHOD=none
  if declare -F ak2_drop_caches >/dev/null; then
    COLD_OK=true; DROP_METHOD=ak2_drop_caches
  elif [ "$(uname -s)" = Linux ]; then
    if [ "$(id -u)" = 0 ] && [ -w /proc/sys/vm/drop_caches ]; then COLD_OK=true; DROP_METHOD=drop_caches-root
    elif sudo -n true 2>/dev/null && sudo -n test -w /proc/sys/vm/drop_caches; then COLD_OK=true; DROP_METHOD=drop_caches-sudo; fi
  elif [ "$(uname -s)" = Darwin ]; then
    if sudo -n true 2>/dev/null; then COLD_OK=true; DROP_METHOD=purge-sudo; fi
  fi
  lb_drop() {
    sync
    case "$DROP_METHOD" in
      ak2_drop_caches) ak2_drop_caches ;;
      drop_caches-root) echo 3 > /proc/sys/vm/drop_caches ;;
      drop_caches-sudo) sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' ;;
      purge-sudo) sudo -n purge ;;
      *) return 1 ;;
    esac
  }
  local -a RSTATES=()
  for t in $STATES; do
    case "$t" in
      cold) if $COLD_OK; then RSTATES+=(cold); else echo "loadbench: cannot drop the page cache here (no passwordless sudo): cold rungs skipped" >&2; fi ;;
      warm) RSTATES+=(warm) ;;
      *) echo "loadbench: unknown state '$t'" >&2; return 1 ;;
    esac
  done

  # ---- output -----------------------------------------------------------------------------------
  local TS; TS=$(date -u +%Y%m%dT%H%M%SZ)
  local DBTAG=$DBSEL; case "$DBSEL" in */*) DBTAG=$DBNAME ;; esac
  local RES="$ROOT/results/$GATE/loadbench-$DBTAG-t$TH-$TS"
  local WORK="$ROOT/.cache/loadbench/$TS"
  mkdir -p "$RES/stderr" "$WORK" || return 1
  [ "$PROFILE" = 1 ] && mkdir -p "$RES/profile"
  : > "$WORK/empty.fq"
  local start; start=$(date -u +%FT%TZ)
  local RUNS="$RES/runs.tsv" TIM="$RES/timings.tsv"
  printf 'rep\timpl\tinput\tstate\tthreads\texit\twall_s\tload_s\tclassify_s\ttail_s\tminflt\tmajflt\tuser_s\tsys_s\tmaxrss\tthp_fault_alloc\tthp_fault_fallback\toutput_sha256\n' > "$RUNS"
  printf 'rep\timpl\tinput\tstate\tphase\tstart_s\tseconds\tminflt\tmajflt\tuser_s\tsys_s\n' > "$TIM"
  local thp_en thp_df
  thp_en=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)
  thp_df=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo n/a)
  echo "loadbench: db=$DBDIR threads=$TH reps=$REPS states=${RSTATES[*]} inputs=$INPUTS impls=${LABELS[*]} cold=$COLD_OK ($DROP_METHOD) thp=[$thp_en] defrag=[$thp_df]"
  echo "loadbench: results $RES"

  vmstat_thp() { awk '$1=="thp_fault_alloc"{a=$2} $1=="thp_fault_fallback"{f=$2} END{printf "%s %s", (a==""?"-":a), (f==""?"-":f)}' /proc/vmstat 2>/dev/null || echo "- -"; }

  # args INPUT: the classifier arguments for one input.
  lb_args() {
    local out=$1
    case "$2" in
      empty) echo "--db $DBDIR --threads $TH --output $out $WORK/empty.fq" ;;
      se) echo "--db $DBDIR --threads $TH --output $out ${S1}_1.fq" ;;
      pe) echo "--db $DBDIR --threads $TH --output $out --paired ${S1}_1.fq ${S1}_2.fq" ;;
      *) return 1 ;;
    esac
  }

  # rung REP I INPUT STATE: one timed run of implementation I.
  local FAILS=0
  lb_rung() {
    local rep=$1 i=$2 input=$3 state=$4
    local label=${LABELS[$i]} bin=${BINS[$i]}
    local tag="$rep-$label-$input-$state" out="$WORK/out-$label-$input.txt" args j a0 a1 b0 b1
    args=$(lb_args "$out" "$input") || { echo "loadbench: unknown input $input" >&2; return 1; }
    if [ "$state" = cold ]; then lb_drop || { echo "loadbench: drop failed before $tag" >&2; FAILS=$((FAILS + 1)); return 1; }; fi
    declare -F ak2_phase >/dev/null && ak2_phase "lb-$tag"
    read -r a0 a1 <<< "$(vmstat_thp)"
    # shellcheck disable=SC2086
    j=$(env AK2_TIMINGS=1 $EXTRA_ENV ${ENVS[$i]} python3 scripts/lib/lbrun.py "$RES/stderr/$tag.txt" -- "$bin" $args)
    read -r b0 b1 <<< "$(vmstat_thp)"
    [ -n "$j" ] || { echo "loadbench: $tag: no measurement" >&2; FAILS=$((FAILS + 1)); return 1; }
    local osha=-; [ -f "$out" ] && osha=$(sha "$out")
    local d0=- d1=-; [ "$a0" != - ] && [ "$b0" != - ] && { d0=$((b0 - a0)); d1=$((b1 - a1)); }
    jq -r --arg rep "$rep" --arg impl "$label" --arg input "$input" --arg state "$state" \
      --arg th "$TH" --arg d0 "$d0" --arg d1 "$d1" --arg osha "$osha" \
      '[$rep,$impl,$input,$state,$th,.exit,.wall_s,(.load_s//"-"),(.classify_s//"-"),(.tail_s//"-"),
        .minflt,.majflt,.user_s,.sys_s,.maxrss,$d0,$d1,$osha] | map(tostring) | join("\t")' <<< "$j" >> "$RUNS"
    awk -F'\t' -v p="$rep\t$label\t$input\t$state" '$1=="ak2-timing"{print p"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8}' \
      "$RES/stderr/$tag.txt" >> "$TIM"
    [ "$(jq .exit <<< "$j")" = 0 ] || { echo "loadbench: $tag exited $(jq .exit <<< "$j")" >&2; FAILS=$((FAILS + 1)); }
    echo "loadbench: $tag $(jq -c '{wall_s,load_s,classify_s,tail_s,minflt}' <<< "$j")"
    rm -f "$out"
    declare -F ak2_push >/dev/null && ak2_push "$RUNS" "$(basename "$RES")/runs.tsv" >/dev/null
    return 0
  }

  # Every binary runs once first (unrecorded), so no rung pays a first exec (macOS verifies a new
  # binary's signature on its first run).
  for i in "${!BINS[@]}"; do "${BINS[$i]}" --version > /dev/null 2>&1; done

  # Warm-up: the first cold reads of a freshly staged database differ from the rest (on
  # instance-store NVMe the first read faster, on EBS slower: results/g2/20261006-115949-dab2575
  # and results/g2/20261006-121954-dab2575; with one warm-up the next cold read, the first
  # recorded rung, still deviated: results/g2/20261006-135946-9035dd6,
  # results/g2/20261006-154839-bf1cf20). LB_WARMUPS unrecorded cold runs absorb it; their numbers
  # are kept in the manifest (warmups), not dropped silently.
  local WARMUPS_JSON='[]'
  case " ${RSTATES[*]} " in *" cold "*)
    if [ "$WARMUP" = 1 ]; then
      local win=${INPUTS%% *} wn w
      for wn in $(seq 1 "$WARMUPS"); do
        lb_drop || break
        declare -F ak2_phase >/dev/null && ak2_phase "lb-warmup$wn-${LABELS[0]}-$win"
        # shellcheck disable=SC2046
        w=$(env AK2_TIMINGS=1 $EXTRA_ENV ${ENVS[0]} python3 scripts/lib/lbrun.py \
          "$RES/stderr/warmup$wn-${LABELS[0]}-$win-cold.txt" -- "${BINS[0]}" $(lb_args "$WORK/warmup.out" "$win"))
        w=$(jq -c --arg impl "${LABELS[0]}" --arg input "$win" --argjson n "$wn" \
          '. + {impl:$impl, input:$input, state:"cold", n:$n}' <<< "${w:-null}" 2>/dev/null || echo null)
        echo "loadbench: warmup $wn (unrecorded) $w"
        WARMUPS_JSON=$(jq -c --argjson w "$w" '. + [$w]' <<< "$WARMUPS_JSON")
        WARMUP_JSON=$w
        rm -f "$WORK/warmup.out"
      done
    fi ;;
  esac

  # Matrix: input (cheapest first) > rep > implementation > state. Warm follows the same
  # implementation's cold run, so the cache then holds the database and the reads. Without a cold
  # state, one unrecorded priming run per input warms the cache first. The implementation order
  # rotates by one each repetition (rep r starts with implementation r-1 mod n), so no
  # implementation always runs first or always follows the same neighbour. Cold rungs run in
  # repetitions 1..LB_REPS_COLD, warm ones in 1..LB_REPS_WARM.
  local input rep i st
  for input in $INPUTS; do
    case " ${RSTATES[*]} " in *" cold "*) ;; *)
      j=$(python3 scripts/lib/lbrun.py "$WORK/prime.txt" -- "${BINS[0]}" $(lb_args "$WORK/prime.out" "$input")) ;;
    esac
    local nimpl=${#LABELS[@]} o
    for rep in $(seq 1 $(( REPS_COLD > REPS_WARM ? REPS_COLD : REPS_WARM ))); do
      for o in $(seq 0 $((nimpl - 1))); do
        i=$(( (o + rep - 1) % nimpl ))
        for st in "${RSTATES[@]}"; do
          [ "$st" = cold ] && [ "$rep" -gt "$REPS_COLD" ] && continue
          [ "$st" = warm ] && [ "$rep" -gt "$REPS_WARM" ] && continue
          lb_rung "$rep" "$i" "$input" "$st"
        done
      done
    done
  done

  # ---- profiling extras --------------------------------------------------------------------------
  if [ "$PROFILE" = 1 ]; then
    local PERF="" pin=${INPUTS##* }
    if [ "$(uname -s)" = Linux ] && command -v perf >/dev/null; then
      PERF=perf; sudo -n true 2>/dev/null && PERF="sudo -n perf"
    fi
    for i in "${!LABELS[@]}"; do
      if [ -n "$PROFILE_IMPLS" ]; then
        case " $PROFILE_IMPLS " in *" ${LABELS[$i]} "*) ;; *) continue ;; esac
      fi
      for st in "${RSTATES[@]}"; do
        local label=${LABELS[$i]} bin=${BINS[$i]} ptag
        ptag="${LABELS[$i]}-$pin-$st"
        if [ -n "$PERF" ]; then
          if [ "$st" = cold ]; then lb_drop || continue; fi
          declare -F ak2_phase >/dev/null && ak2_phase "lb-perf-$ptag"
          # shellcheck disable=SC2046,SC2086
          $PERF stat -x, -o "$RES/profile/perf-$ptag.csv" \
            -e task-clock,page-faults,minor-faults,major-faults,context-switches,cpu-migrations,dTLB-load-misses \
            -- env $EXTRA_ENV ${ENVS[$i]} "$bin" $(lb_args "$WORK/perf.out" "$pin") 2> "$RES/profile/perf-$ptag.stderr"
          echo "loadbench: perf stat $ptag rc=$?"
        fi
        case "$label" in upstream) ;; *)
          if [ "$st" = cold ]; then lb_drop || continue; fi
          declare -F ak2_phase >/dev/null && ak2_phase "lb-pprof-$ptag"
          # shellcheck disable=SC2046,SC2086
          env AK2_TIMINGS=1 AK2_CPUPROFILE="$RES/profile/pprof-$ptag.cpu" GODEBUG=gctrace=1 $EXTRA_ENV ${ENVS[$i]} \
            "$bin" $(lb_args "$WORK/prof.out" "$pin") 2> "$RES/profile/gctrace-$ptag.txt"
          echo "loadbench: pprof $ptag rc=$?"
          command -v go >/dev/null && go tool pprof -top -nodecount=40 "$bin" "$RES/profile/pprof-$ptag.cpu" \
            > "$RES/profile/pprof-$ptag.top.txt" 2>/dev/null
          ;;
        esac
      done
    done
    rm -f "$WORK/prof.out" "$WORK/perf.out" 2>/dev/null
  fi
  local stop; stop=$(date -u +%FT%TZ)

  # ---- manifest and summary -------------------------------------------------------------------
  local dirty=false
  [ -n "$(git status --porcelain -- scripts cmd internal go.mod go.sum Makefile)" ] && dirty=true
  local impls_json="[]" k
  for k in "${!LABELS[@]}"; do
    impls_json=$(jq -c --arg l "${LABELS[$k]}" --arg b "${BINS[$k]#"$ROOT"/}" --arg s "${SRCS[$k]}" \
      --arg h "$(sha "${BINS[$k]}")" --arg e "${ENVS[$k]}" \
      '. + [{label:$l, binary:$b, source:$s, sha256:$h, env:$e}]' <<< "$impls_json")
  done
  local dbfiles="[]"
  for t in hash.k2d opts.k2d taxo.k2d; do
    dbfiles=$(jq -c --arg f "$t" --argjson s "$(wc -c < "$DBDIR/$t" | tr -d ' ')" '. + [{file:$f, bytes:$s}]' <<< "$dbfiles")
  done
  # Where the database lives: the device, its filesystem, the disk model and serial (an EBS
  # volume's serial is its volume ID; instance store reads "Amazon EC2 NVMe Instance Storage"),
  # and for EBS the volume type, IOPS and throughput when the instance may describe it.
  local storage='{}'
  if [ "$(uname -s)" = Linux ]; then
    local src fst disk dmodel dserial ebs='null'
    src=$(df --output=source "$DBDIR" 2>/dev/null | tail -1)
    fst=$(df --output=fstype "$DBDIR" 2>/dev/null | tail -1)
    disk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1); [ -n "$disk" ] || disk=$(basename "$src")
    dmodel=$(lsblk -dno MODEL "/dev/$disk" 2>/dev/null | sed 's/ *$//')
    dserial=$(lsblk -dno SERIAL "/dev/$disk" 2>/dev/null | sed 's/ *$//')
    case "$dserial" in vol*)
      local vid="vol-${dserial#vol}" vreg
      vreg=$(curl -sf -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null |
        { read -r tok; curl -sf -m 2 -H "X-aws-ec2-metadata-token: $tok" http://169.254.169.254/latest/meta-data/placement/region; } 2>/dev/null)
      [ -n "$vreg" ] && ebs=$(aws ec2 describe-volumes --region "$vreg" --volume-ids "$vid" \
        --query 'Volumes[0].{id:VolumeId,type:VolumeType,iops:Iops,throughput_mibps:Throughput,size_gib:Size}' \
        --output json 2>/dev/null || echo null)
      [ -n "$ebs" ] || ebs=null
      [ "$ebs" = null ] && ebs=$(jq -nc --arg id "$vid" '{id:$id, note:"describe-volumes not permitted; type and throughput unknown"}')
      ;;
    esac
    storage=$(jq -nc --arg src "$src" --arg fs "$fst" --arg disk "$disk" --arg model "$dmodel" \
      --arg serial "$dserial" --argjson ebs "$ebs" \
      '{device:$src, fstype:$fs, disk:$disk, model:$model, serial:$serial, ebs:$ebs}')
  elif [ "$(uname -s)" = Darwin ]; then
    storage=$(jq -nc --arg src "$(df "$DBDIR" | tail -1 | awk '{print $1}')" '{device:$src}')
  fi
  local model; model=$(sysctl -n hw.model 2>/dev/null || cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)
  local mem; mem=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo 2>/dev/null); [ -n "$mem" ] || mem=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  # Canonical: Linux aarch64 on EC2 through make run (AK2_RUN_ID is set by the harness only).
  local canon=false; [ "$(uname -s)-$(uname -m)" = Linux-aarch64 ] && [ -n "${AK2_RUN_ID:-}" ] && canon=true
  jq -n --arg gate "$GATE" --arg what "make loadbench: load-path and whole-process wall, upstream vs ours (#36)" \
    --arg commit "$(git rev-parse HEAD)" --argjson dirty "$dirty" \
    --arg pin "$UPSTREAM_SHA" --rawfile upbuild "$K2DIR/BUILD" \
    --arg describe "$UPSTREAM_DESCRIBE" \
    --argjson impls "$impls_json" --arg go "$(go version 2>/dev/null)" \
    --arg db "$DBSEL" --arg dbname "$DBNAME" --argjson dbfiles "$dbfiles" \
    --arg dbsource "$(cat "$DBDIR/SOURCE" 2>/dev/null)" \
    --arg reads "$(cat "${S1}.SOURCE" 2>/dev/null)" \
    --argjson threads "$TH" --argjson reps "$REPS" --argjson reps_cold "$REPS_COLD" --argjson reps_warm "$REPS_WARM" --argjson warmup "$WARMUP_JSON" --argjson warmups "$WARMUPS_JSON" --arg states "${RSTATES[*]}" --arg inputs "$INPUTS" \
    --arg extra_env "$EXTRA_ENV" --argjson profile "$([ "$PROFILE" = 1 ] && echo true || echo false)" \
    --argjson cold_ok "$COLD_OK" --arg drop "$DROP_METHOD" --arg requested_states "$STATES" \
    --arg os "$(uname -s)" --arg arch "$(uname -m)" --arg kernel "$(uname -r)" --arg model "$model" \
    --argjson ncpu "$NCPU" --argjson mem "$mem" --arg pagesize "$(getconf PAGESIZE)" \
    --arg thp_en "$thp_en" --arg thp_df "$thp_df" --argjson canonical "$canon" \
    --argjson storage "$storage" --arg reads_dir "$READS" \
    --arg run_id "${AK2_RUN_ID:-}" --arg start "$start" --arg stop "$stop" --argjson fails "$FAILS" \
    '{gate:$gate, what:$what, commit:$commit, dirty:$dirty, ak2_run_id:$run_id,
      upstream:{pin:$pin, describe:$describe, build:$upbuild}, implementations:$impls, go:$go,
      db:{name:$db, dir:$dbname, files:$dbfiles, source:$dbsource, storage:$storage},
      reads_source:$reads, reads_dir:$reads_dir,
      order:"implementations rotate by one per repetition",
      threads:$threads, reps:$reps, reps_cold:$reps_cold, reps_warm:$reps_warm, warmup:$warmup, warmups:$warmups, inputs:$inputs, states_requested:$requested_states,
      states_run:$states, extra_env:$extra_env, profile:$profile,
      cold:{available:$cold_ok, method:$drop},
      host:{os:$os, arch:$arch, kernel:$kernel, model:$model, ncpu:$ncpu, mem_bytes:$mem,
            page_size:$pagesize, thp_enabled:$thp_en, thp_defrag:$thp_df,
            canonical_platform:$canonical,
            note:(if $canonical then "Linux aarch64 on EC2 (make run)" else "NOT a make run on Linux aarch64 EC2: development evidence only" end)},
      start:$start, stop:$stop, failures:$fails}' > "$RES/manifest.json"
  python3 scripts/lib/lbsummary.py "$RES" || FAILS=$((FAILS + 1))
  rm -rf "$WORK"
  if declare -F ak2_push >/dev/null; then
    local f
    for f in "$RES"/*.tsv "$RES"/*.json "$RES"/*.md; do ak2_push "$f" "$(basename "$RES")/$(basename "$f")"; done
    for f in "$RES"/stderr/* "$RES"/profile/*; do
      [ -f "$f" ] && ak2_push "$f" "$(basename "$RES")/$(basename "$(dirname "$f")")/$(basename "$f")"
    done
  fi
  echo "results: ${RES#"$ROOT"/}"
  [ "$FAILS" = 0 ]
}

lb_main
LB_STATUS=$?
cd "$LB_START_DIR" || true
if [ "$LB_SOURCED" = 1 ]; then return "$LB_STATUS"; fi
exit "$LB_STATUS"
