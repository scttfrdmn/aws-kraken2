#!/usr/bin/env bash
# make g2 (docs/g2.md; issues #21 NVMe baseline, #22 big-RAM baseline, #23 H-knee sweep):
# upstream kraken2 at the pin, one instrumented run per rung (scripts/lib/g2run.py), driven by a
# checked-in plan file (scripts/g2/*.plan), then the summary (scripts/lib/g2summary.py).
#
# Usage: scripts/g2.sh                (run directly: a local smoke test, `make g2 PART=local`)
#        . scripts/g2.sh              (sourced by an AWS spec body: cold rungs use ak2_drop_caches,
#                                      every rung is an ak2_phase, runs.jsonl streams after each)
# Env:   G2_PLAN     plan file (required)
#        G2_DB       database directory (hash.k2d, opts.k2d, taxo.k2d) for the load/mmap/madv regimes
#        G2_RAMDB    database directory on a tmpfs, for the ram regime (table resident in RAM)
#        G2_READS    directory with the plan's inputs: <NAME>_1.fq, <NAME>_2.fq (+ .gz)
#        G2_WORK     scratch for --output/--report                   (default .cache/g2/<ts>)
#        G2_DEVS     block devices for /proc/diskstats deltas, comma-separated (default: none)
#        G2_PERF_EVENTS  perf stat events (default: none = no perf)
#        G2_PERF     perf command                                    (default perf)
#        G2_HZ       thread-state sampler rate                       (default 20)
#        G2_RUNG_TIMEOUT  seconds per rung, 0 = none; a timed-out rung is recorded as censored
#                    and the same plan line's smaller thread counts are skipped (they are slower)
#        G2_DEADLINE epoch seconds; rungs not started by then are skipped (recorded as such)
#        G2_LABEL    result dir label                                (default local)
#        G2_GATE     results/<gate>/                                 (default g2)
#        G2_UPSTREAM / G2_MADV  install dirs (default: scripts/oracle-build.sh / madvrandom-build.sh)
#        G2_ENV      extra NAME=VALUE words for every classifier run
# Plan lines (executed in file order; '#' comments):
#   run REGIME INPUT STATE REPS T1 T2 ...   for rep in 1..REPS, for T in T1 T2 ...: one rung
#   profile REGIME INPUT STATE T            one perf record -g run (not timed into any cell)
#   note TEXT                               copied into the manifest
#   REGIME: load (default load, table read into RAM) | ram (-M on G2_RAMDB) |
#           mmap (-M on G2_DB) | madv (kraken2-madvrandom -M on G2_DB; diagnostic only)
#   INPUT:  NAME-gz | NAME-fq (paired: G2_READS/NAME_{1,2}.fq[.gz]) | empty (load only)
#   STATE:  cold (drop_caches before the rung) | warm
set +e
G2_SOURCED=0
(return 0 2>/dev/null) && G2_SOURCED=1
[ "$G2_SOURCED" = 1 ] || set -uo pipefail
G2_START_DIR=$PWD
cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "g2: no repo" >&2; return 1 2>/dev/null || exit 1; }
. scripts/pin.env
. scripts/paths.sh
echo "g2: shell flags $-"

# Direct use: scripts/g2.sh local (smoke test on the viral DB) | scripts/g2.sh summary DIR.
if [ "$G2_SOURCED" = 0 ]; then
  case "${1:-}" in
    local) G2_PLAN=${G2_PLAN:-scripts/g2/local.plan}; G2_DB=${G2_DB:-$K2_DB_ROOT/k2_viral_20260626} ;;
    summary) [ -d "${2:-}" ] || { echo "usage: scripts/g2.sh summary RESULT_DIR" >&2; exit 2; }
             cd "$G2_START_DIR" && exec python3 "$OLDPWD/scripts/lib/g2summary.py" "$2" ;;
    '') ;;
    *) echo "usage: scripts/g2.sh [local | summary DIR]  (AWS: make run GATE=g2 SPEC=runs/g2-*.json)" >&2; exit 2 ;;
  esac
fi

g2_main() {
  local PLAN=${G2_PLAN:-} DB=${G2_DB:-} RAMDB=${G2_RAMDB:-} READS=${G2_READS:-$K2_READS}
  local HZ=${G2_HZ:-20} TMO=${G2_RUNG_TIMEOUT:-0} DEADLINE=${G2_DEADLINE:-0}
  local EVENTS=${G2_PERF_EVENTS:-} PERF=${G2_PERF:-perf} DEVS=${G2_DEVS:-}
  local LABEL=${G2_LABEL:-local} GATE=${G2_GATE:-g2} EXTRA_ENV=${G2_ENV:-}
  local t
  for t in jq python3 awk; do command -v "$t" >/dev/null || { echo "g2: need $t" >&2; return 1; }; done
  case "$PLAN" in /*) ;; ?*) [ -f "$PLAN" ] || PLAN="$G2_START_DIR/$PLAN" ;; esac
  [ -f "$PLAN" ] || { echo "g2: G2_PLAN '$PLAN' not found" >&2; return 1; }
  if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
  else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

  local UP=${G2_UPSTREAM:-} MADV=${G2_MADV:-}
  [ -n "$UP" ] || UP=$(scripts/oracle-build.sh) || { echo "g2: upstream build failed" >&2; return 1; }
  if grep -Eq '^(run|profile) +madv ' "$PLAN" && [ -z "$MADV" ]; then
    MADV=$(scripts/madvrandom-build.sh) || { echo "g2: madvrandom build failed" >&2; return 1; }
  fi
  . scripts/pin-identity.sh
  pin_identity || { echo "g2: cannot establish the upstream pin identity" >&2; return 1; }

  local COLD_OK=false DROP=none
  if declare -F ak2_drop_caches >/dev/null; then COLD_OK=true; DROP=ak2_drop_caches
  elif [ "$(uname -s)" = Linux ] && sudo -n true 2>/dev/null; then COLD_OK=true; DROP=drop_caches-sudo; fi
  g2_drop() {
    sync
    case "$DROP" in
      ak2_drop_caches) ak2_drop_caches ;;
      drop_caches-sudo) sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' ;;
      *) return 1 ;;
    esac
  }

  local TS; TS=$(date -u +%Y%m%dT%H%M%SZ)
  local RES="$PWD/results/$GATE/g2-$LABEL-$TS"
  local WORK=${G2_WORK:-$PWD/.cache/g2/$TS}
  mkdir -p "$RES/stderr" "$RES/perf" "$RES/profile" "$WORK" || return 1
  cp "$PLAN" "$RES/plan.txt"
  : > "$WORK/empty.fq"
  local JL="$RES/runs.jsonl"; : > "$JL"
  local start; start=$(date -u +%FT%TZ)

  # ---- inputs: bytes, records and 8 MiB blocks (classify.cc INPUT_BLOCK_BYTES) per input ----
  local INJ="$RES/inputs.json"; echo '{}' > "$INJ"
  local inp name fmt f1 f2
  for inp in $(awk '$1=="run"||$1=="profile"{print $3}' "$PLAN" | sort -u); do
    [ "$inp" = empty ] && continue
    name=${inp%-*}; fmt=${inp##*-}
    f1="$READS/${name}_1.fq"; f2="$READS/${name}_2.fq"
    [ -s "$f1" ] && [ -s "$f2" ] || { echo "g2: input $inp: $f1 / $f2 missing" >&2; return 1; }
    if [ "$fmt" = gz ]; then
      [ -s "$f1.gz" ] && [ -s "$f2.gz" ] || { echo "g2: input $inp: $f1.gz / $f2.gz missing" >&2; return 1; }
    fi
    local b1 recs
    b1=$(wc -c < "$f1" | tr -d ' '); recs=$(( $(wc -l < "$f1" | tr -d ' ') / 4 ))
    jq --arg k "$inp" --arg f1 "$f1" --arg fmt "$fmt" --argjson b1 "$b1" --argjson r "$recs" \
       --arg s1 "$(sha "$f1")" --arg s2 "$(sha "$f2")" \
       --arg z1 "$([ "$fmt" = gz ] && sha "$f1.gz" || echo -)" --arg z2 "$([ "$fmt" = gz ] && sha "$f2.gz" || echo -)" \
       '.[$k] = {name:($k|sub("-(gz|fq)$";"")), format:$fmt, pairs:$r, mate1_bytes:$b1,
                 blocks_8mib:(($b1 + 8388607) / 8388608 | floor), plain_sha256:[$s1,$s2],
                 gz_sha256:(if $fmt=="gz" then [$z1,$z2] else null end)}' "$INJ" > "$INJ.t" && mv "$INJ.t" "$INJ"
  done

  local thp_en thp_df
  thp_en=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)
  thp_df=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo n/a)
  echo "g2: plan=$PLAN db=$DB ramdb=$RAMDB reads=$READS cold=$COLD_OK ($DROP) thp=[$thp_en] defrag=[$thp_df] devs=$DEVS"
  echo "g2: results $RES"

  g2_cmd() {  # REGIME INPUT T OUT REPORT -> the classifier argv on stdout (one word per line)
    local regime=$1 input=$2 th=$3 out=$4 rep=$5 bin=$UP/kraken2 db=$DB mm=--memory-mapping
    case "$regime" in
      load) mm="" ;;
      mmap) ;;
      madv) bin=$MADV/kraken2 ;;
      ram) db=$RAMDB ;;
      *) return 1 ;;
    esac
    [ -n "$db" ] && [ -s "$db/hash.k2d" ] || { echo "g2: no database for regime $regime ($db)" >&2; return 1; }
    printf '%s\n' "$bin" --db "$db" --threads "$th" $mm --output "$out" --report "$rep"
    if [ "$input" = empty ]; then printf '%s\n' "$WORK/empty.fq"; return 0; fi
    local n=${input%-*} z=""; [ "${input##*-}" = gz ] && z=.gz
    printf '%s\n' --paired "$READS/${n}_1.fq$z" "$READS/${n}_2.fq$z"
  }

  local FAILS=0 SKIPPED=0 RUNG=0 line kind regime input state reps ths rep th tag j
  local -a ARGV
  local -A SKIP=()
  local push_ok=false; declare -F ak2_push >/dev/null && push_ok=true
  local lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    read -r kind regime input state reps ths <<< "$line"
    case "$kind" in
      ''|note) continue ;;
      run|profile) ;;
      *) echo "g2: plan line $lineno: unknown directive '$kind'" >&2; FAILS=$((FAILS + 1)); continue ;;
    esac
    if [ "$kind" = profile ]; then ths=$reps; reps=1; fi
    for ((rep = 1; rep <= reps; rep++)); do
      for th in $ths; do
        tag="L$lineno-$kind-$regime-$input-$state-t$th-r$rep"
        if [ -n "${SKIP[$lineno:$th]:-}" ]; then
          echo "g2: $tag skipped (${SKIP[$lineno:$th]})"
          jq -cn --arg tag "$tag" --argjson l "$lineno" --arg k "$kind" --arg rg "$regime" --arg i "$input" \
            --arg s "$state" --argjson r "$rep" --argjson t "$th" --arg why "${SKIP[$lineno:$th]}" \
            '{tag:$tag,line:$l,kind:$k,regime:$rg,input:$i,state:$s,rep:$r,threads:$t,skipped:$why}' >> "$JL"
          SKIPPED=$((SKIPPED + 1)); continue
        fi
        if [ "$DEADLINE" != 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
          SKIP[$lineno:$th]="deadline"
          echo "g2: $tag skipped (deadline G2_DEADLINE=$DEADLINE passed)"
          jq -cn --arg tag "$tag" --argjson l "$lineno" --arg k "$kind" --arg rg "$regime" --arg i "$input" \
            --arg s "$state" --argjson r "$rep" --argjson t "$th" \
            '{tag:$tag,line:$l,kind:$k,regime:$rg,input:$i,state:$s,rep:$r,threads:$t,skipped:"deadline"}' >> "$JL"
          SKIPPED=$((SKIPPED + 1)); continue
        fi
        mapfile -t ARGV < <(g2_cmd "$regime" "$input" "$th" "$WORK/out.txt" "$WORK/report.txt") || true
        [ "${#ARGV[@]}" -gt 0 ] || { echo "g2: $tag: bad regime/input" >&2; FAILS=$((FAILS + 1)); continue; }
        rm -f "$WORK/out.txt" "$WORK/report.txt"
        case "$state" in
          cold) $COLD_OK || { echo "g2: $tag: cannot drop caches here; skipped" >&2; SKIPPED=$((SKIPPED + 1))
                  jq -cn --arg tag "$tag" --argjson l "$lineno" --arg k "$kind" --arg rg "$regime" --arg i "$input" \
                    --argjson r "$rep" --argjson t "$th" \
                    '{tag:$tag,line:$l,kind:$k,regime:$rg,input:$i,state:"cold",rep:$r,threads:$t,skipped:"no drop_caches here"}' >> "$JL"
                  continue; }
                g2_drop || { echo "g2: drop failed before $tag" >&2; FAILS=$((FAILS + 1)); continue; } ;;
          warm) ;;
          *) echo "g2: $tag: unknown state" >&2; FAILS=$((FAILS + 1)); continue ;;
        esac
        RUNG=$((RUNG + 1))
        declare -F ak2_phase >/dev/null && ak2_phase "g2-$RUNG-$regime-$input-$state-t$th-r$rep"
        if [ "$kind" = profile ]; then
          # shellcheck disable=SC2086
          env $EXTRA_ENV $PERF record -F 199 -g -o "$WORK/perf.data" -- "${ARGV[@]}" \
            > /dev/null 2> "$RES/profile/$tag.stderr"
          $PERF report -i "$WORK/perf.data" --stdio --no-children --sort dso,sym --percent-limit 0.5 \
            2>/dev/null | grep -v '^$' | head -150 > "$RES/profile/$tag.txt"
          $PERF report -i "$WORK/perf.data" --stdio --no-children --sort comm,dso --percent-limit 0.5 \
            2>/dev/null | grep -v '^#' | grep -v '^$' | head -40 > "$RES/profile/$tag.dso.txt"
          rm -f "$WORK/perf.data"
          echo "g2: $tag profile written ($(wc -l < "$RES/profile/$tag.txt") lines)"
          $push_ok && ak2_push "$RES/profile/$tag.txt" "g2-$LABEL/profile/$tag.txt" >/dev/null
          continue
        fi
        # shellcheck disable=SC2086
        j=$(env $EXTRA_ENV python3 scripts/lib/g2run.py --out "$RES/stderr/$tag" --threads "$th" \
              --devs "$DEVS" --perf-events "$EVENTS" --perf "$PERF" --hz "$HZ" --timeout "$TMO" -- "${ARGV[@]}")
        [ -n "$j" ] || { echo "g2: $tag: no measurement" >&2; FAILS=$((FAILS + 1)); continue; }
        [ -f "$RES/stderr/$tag.perf.csv" ] && mv "$RES/stderr/$tag.perf.csv" "$RES/perf/$tag.csv"
        local osha=null rsha=null seqs
        [ -s "$WORK/out.txt" ] && osha="\"$(sha "$WORK/out.txt")\""
        [ -s "$WORK/report.txt" ] && rsha="\"$(sha "$WORK/report.txt")\""
        seqs=$(grep -oE '^[0-9]+ sequences \(' "$RES/stderr/$tag.stderr" | grep -oE '^[0-9]+' | head -1)
        jq -c --arg tag "$tag" --argjson l "$lineno" --arg rg "$regime" --arg i "$input" --arg s "$state" \
          --argjson r "$rep" --argjson osha "$osha" --argjson rsha "$rsha" --arg seqs "${seqs:-}" \
          --arg at "$(date -u +%FT%TZ)" \
          '{tag:$tag,line:$l,kind:"run",regime:$rg,input:$i,state:$s,rep:$r,finished_at:$at,
            sequences:(if $seqs=="" then null else ($seqs|tonumber) end),
            output_sha256:$osha,report_sha256:$rsha} + .' <<< "$j" >> "$JL"
        echo "g2: $tag $(jq -c '{exit,timed_out,wall_s,load_s,classify_s,offcpu_frac,ipc,aqu:([.disks[]?.aqu_sz]|max),majflt}' <<< "$j")"
        if [ "$(jq -r .timed_out <<< "$j")" = true ]; then
          local t2
          for t2 in $ths; do [ "$t2" -le "$th" ] && SKIP[$lineno:$t2]="t$th timed out at ${TMO}s"; done
          echo "g2: $tag timed out after ${TMO}s: smaller thread counts on plan line $lineno are skipped"
        elif [ "$(jq .exit <<< "$j")" != 0 ]; then
          echo "g2: $tag exited $(jq .exit <<< "$j")" >&2; FAILS=$((FAILS + 1))
        fi
        $push_ok && ak2_push "$JL" "g2-$LABEL/runs.jsonl" >/dev/null
      done
    done
  done < "$PLAN"

  local stop; stop=$(date -u +%FT%TZ)
  jq -n --arg commit "$(git rev-parse HEAD 2>/dev/null)" --argjson dirty "$(git diff --quiet HEAD 2>/dev/null && echo false || echo true)" \
     --arg pin "$UPSTREAM_SHA" --arg desc "$UPSTREAM_DESCRIBE" --arg plan "$PLAN" --arg plansha "$(sha "$PLAN")" \
     --arg up "$UP" --arg upb "$(cat "$UP/BUILD" 2>/dev/null)" --arg madv "$MADV" --arg madvb "$(cat "$MADV/BUILD" 2>/dev/null)" \
     --arg db "$DB" --arg ramdb "$RAMDB" --arg reads "$READS" --arg devs "$DEVS" --arg events "$EVENTS" \
     --arg hz "$HZ" --arg tmo "$TMO" --arg dl "$DEADLINE" --arg extra "$EXTRA_ENV" \
     --argjson cold "$COLD_OK" --arg drop "$DROP" --arg thp "$thp_en" --arg df "$thp_df" \
     --arg kernel "$(uname -r)" --arg arch "$(uname -m)" --arg ncpu "$(getconf _NPROCESSORS_ONLN 2>/dev/null)" \
     --arg mem "$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)" --arg run "${AK2_RUN_ID:-}" \
     --arg itype "${AK2_INSTANCE_TYPE:-}" --arg storage "${G2_STORAGE:-}" \
     --arg start "$start" --arg stop "$stop" --argjson fails "$FAILS" --argjson skipped "$SKIPPED" \
     --slurpfile inputs "$INJ" --arg notes "$(awk '$1=="note"{$1=""; print substr($0,2)}' "$PLAN")" '{
       commit:$commit, tree_dirty:$dirty, upstream:{pin:$pin, describe:$desc, install:$up, build:$upb},
       madvrandom:(if $madv=="" then null else {install:$madv, build:$madvb, diagnostic_only:true} end),
       plan:$plan, plan_sha256:$plansha, notes:($notes|split("\n")|map(select(.!=""))),
       db:$db, ramdb:$ramdb, reads:$reads, inputs:$inputs[0], storage:$storage,
       instruments:{devs:$devs, perf_events:$events, sampler_hz:($hz|tonumber), rung_timeout_s:($tmo|tonumber),
                    deadline_epoch:($dl|tonumber), extra_env:$extra},
       cold:{available:$cold, method:$drop},
       host:{instance_type:$itype, kernel:$kernel, arch:$arch, ncpu:$ncpu, mem_kib:$mem, thp_enabled:$thp, thp_defrag:$df},
       make_run_id:$run, start:$start, stop:$stop, failures:$fails, skipped:$skipped}' > "$RES/manifest.json"
  python3 scripts/lib/g2summary.py "$RES" || { echo "g2: summary failed" >&2; FAILS=$((FAILS + 1)); }
  echo "g2: $RUNG rungs, $SKIPPED skipped, $FAILS failures; $RES"
  G2_RESULT_DIR=$RES
  if $push_ok; then
    local f
    for f in manifest.json runs.jsonl inputs.json summary.md summary.tsv signatures.tsv plan.txt; do
      [ -f "$RES/$f" ] && ak2_push "$RES/$f" "g2-$LABEL/$f" >/dev/null
    done
    tar -C "$RES" -czf "$WORK/g2-detail.tgz" stderr perf profile && ak2_push "$WORK/g2-detail.tgz" "g2-$LABEL/detail.tgz" >/dev/null
  fi
  [ "$FAILS" = 0 ]
}

g2_main
G2_RC=$?
[ "$G2_SOURCED" = 1 ] && return $G2_RC
exit $G2_RC
