#!/usr/bin/env bash
# make oracle-cohort (docs/oracle.md, "Cohort mode"; #25): Law 1 for the engine's cohort mode.
# Upstream kraken2 at the pin runs each sample of a cohort alone (scripts/upstream-cohort.sh);
# the engine runs the same samples as one cohort (AK2_COHORT, cmd/aws-kraken2/cohort.go) in four
# ways, and every sample's every output file is byte-compared with upstream's:
#   n1        AK2_ENGINE_N=1, one process, sample-parallel, 3 samples in flight, local outputs
#   n3        3 processes over loopback (directory rendezvous), sample-parallel, 2 in flight
#   n3-striped  the same 3 processes, every sample block-striped across them (rank 0 emits)
#   n3-sdk    3 processes, sample-parallel, every output s3:// through the SDK path
#             (aws-sdk-go-v2) to a local fake S3 (k2probe fakes3)
#   n3-lpt    3 processes, sample-parallel with LPT placement (parallel:lpt, weight = the
#             sample's input bytes), 2 in flight; the observed home ranks must equal the LPT
#             placement recomputed from the manifest (scripts/lib/lpt_check.py), as n3's must
#             equal j mod N
# A sample passes when its exit status equals upstream's, its file set equals upstream's, and
# every file is identical. A control sample (engine side only: --confidence 0.05 added) must
# come out different, which shows the comparison can see a one-option change (Law 4).
#
# Usage: scripts/oracle-cohort.sh [viral|standard8|all]   (default viral)
# Writes results/g1/oracle-cohort-<db>-<UTC>/{manifest.json,samples.tsv,summary.md,run.log};
# outputs under .cache/oracle-cohort/<ts>/. Exits non-zero on any difference.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
. scripts/pin.env
. scripts/paths.sh
. scripts/pin-identity.sh
pin_identity || { echo "oracle-cohort: cannot establish the pin identity" >&2; exit 1; }
echo "oracle-cohort: shell flags $-"
SEL=${1:-viral}
case "$SEL" in viral) DBS=(viral) ;; standard8) DBS=(standard8) ;; all) DBS=(viral standard8) ;;
  *) echo "usage: $0 [viral|standard8|all]" >&2; exit 2 ;; esac
# DECOMP_BIN (as make oracle): the gzip both sides find on PATH; AK2_DECOMPRESS passes to the
# engine as is (pipe: it runs that gzip, as the wrapper does). The manifest records both.
if [ -n "${DECOMP_BIN:-}" ]; then PATH="$DECOMP_BIN:$PATH"
elif [ -x /tmp/gnugzip/inst/bin/gzip ]; then PATH="/tmp/gnugzip/inst/bin:$PATH"; fi
export PATH
echo "oracle-cohort: decompression ${AK2_DECOMPRESS:-inprocess}; gzip $(command -v gzip)"
for t in jq perl awk cmp gzip; do command -v "$t" >/dev/null || { echo "oracle-cohort: need $t" >&2; exit 1; }; done
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
unset KRAKEN2_DB_PATH KRAKEN2_DEFAULT_DB KRAKEN2_NUM_THREADS AK2_S3_EMULATE AK2_S3_CLIENT

K2DIR=$(scripts/oracle-build.sh) || { echo "oracle-cohort: upstream build failed" >&2; exit 1; }
make -s build || { echo "oracle-cohort: go build failed" >&2; exit 1; }
OURS="$ROOT/bin/aws-kraken2"; K2P="$ROOT/bin/k2probe"
N=200000
for acc in SRR062634 ERR478965 SRR28305653; do
  [ -s "$K2_READS/${acc}_$N.SOURCE" ] || scripts/fetch-reads.sh "$acc" "$N" >/dev/null || { echo "oracle-cohort: no reads $acc" >&2; exit 1; }
done
R=$K2_READS
S1="$R/SRR062634_$N"; S2="$R/ERR478965_$N"; S3="$R/SRR28305653_$N"
TS=$(date -u +%Y%m%dT%H%M%SZ)
WORK="$K2_SHARED_ROOT/.cache/oracle-cohort/$TS"
# A sample that fails: ERR478965 with the last 10 records of mate 2 removed (unequal mates:
# upstream writes every pair it can, then exits 65 without the report; as make oracle's "mates").
VAR="$WORK/variants"; mkdir -p "$VAR" || exit 1
cp "${S2}_1.fq" "$VAR/mates_1.fq" && head -n $((4 * (N - 10))) "${S2}_2.fq" > "$VAR/mates_2.fq" || { echo "oracle-cohort: variant failed" >&2; exit 1; }
# name|options|inputs|outputs (o --output, r --report, c classified/unclassified)
SAMPLES=(
  "s1-pe|--paired|${S1}_1.fq ${S1}_2.fq|orc"
  "s1-pe-gz|--paired|${S1}_1.fq.gz ${S1}_2.fq.gz|or"
  "s2-se-conf|--confidence 0.1|${S2}_1.fq|or"
  "s2-pe-zero|--paired --report-zero-counts|${S2}_1.fq ${S2}_2.fq|or"
  "s3-pe-gz-names|--paired --use-names|${S3}_1.fq.gz ${S3}_2.fq.gz|orc"
  "s3-se-mhg3|--minimum-hit-groups 3|${S3}_1.fq|or"
  "s1-se-quick-mpa|--quick --use-mpa-style|${S1}_1.fq|or"
  "s2-pe-q20|--paired --minimum-base-quality 20|${S2}_1.fq ${S2}_2.fq|orc"
  "s3-pe-conf05|--paired --confidence 0.5|${S3}_1.fq ${S3}_2.fq|or"
  "mates-differ|--paired|$VAR/mates_1.fq $VAR/mates_2.fq|orc"
  "control|--paired|${S1}_1.fq ${S1}_2.fq|or"
)
MODES=(n1 n3 n3-striped n3-sdk n3-lpt)

# outfields BASE OUTS PAIRED: the output arguments, one per line.
outfields() {
  local base=$1 outs=$2 paired=$3
  [[ $outs == *o* ]] && printf '%s\n%s\n' --output "$base/output"
  [[ $outs == *r* ]] && printf '%s\n%s\n' --report "$base/report"
  if [[ $outs == *c* ]]; then
    if [ "$paired" = yes ]; then printf '%s\n' --classified-out "$base/cls#.fq" --unclassified-out "$base/uncls#.fq"
    else printf '%s\n' --classified-out "$base/cls.fq" --unclassified-out "$base/uncls.fq"; fi
  fi
}
# manifest SIDE BASEFN BATCHSPEC: write a cohort manifest; BASEFN NAME prints a sample's base.
manifest_line() {  # batch inflight mode client name base engine_side
  local batch=$1 inflight=$2 mode=$3 client=$4 name=$5 base=$6 engine=$7 s opts ins outs paired=no
  for s in "${SAMPLES[@]}"; do
    IFS='|' read -r n opts ins outs <<< "$s"
    [ "$n" = "$name" ] || continue
    [[ " $opts " == *" --paired "* ]] && paired=yes
    [ "$engine" = yes ] && [ "$name" = control ] && opts="$opts --confidence 0.05"
    local f=("$batch" "$inflight" "$mode" "$client" "$name")
    # shellcheck disable=SC2086
    [ "$mode" = parallel:lpt ] && f+=("weight=$(cat $ins | wc -c | tr -d ' ')")
    # shellcheck disable=SC2206
    f+=($opts)
    mapfile -t oa < <(outfields "$base" "$outs" "$paired")
    f+=("${oa[@]}")
    # shellcheck disable=SC2206
    f+=($ins)
    (IFS=$'\t'; echo "${f[*]}")
  done
}

STATUS=0
run_db() {
  local db=$1 dbdir
  case "$db" in viral) dbdir="$K2_DB_ROOT/k2_viral_20260626" ;; standard8) dbdir="$K2_DB_ROOT/k2_standard_08_GB_20260626" ;; esac
  local RES="results/g1/oracle-cohort-$db-$TS" W="$WORK/$db"
  mkdir -p "$RES" "$W" || return
  local LOG="$RES/run.log"; : > "$LOG"
  log() { echo "$*" | tee -a "$LOG"; }
  log "shell flags: $-"
  local start; start=$(date -u +%FT%TZ)
  local COMMON=(--db "$dbdir" --threads 2)
  # Upstream: every sample alone, local outputs.
  local s name opts ins outs
  : > "$W/up.tsv"
  for s in "${SAMPLES[@]}"; do
    IFS='|' read -r name opts ins outs <<< "$s"
    mkdir -p "$W/up/$name"
    manifest_line 0 1 parallel - "$name" "$W/up/$name" no >> "$W/up.tsv"
  done
  scripts/upstream-cohort.sh run "$K2DIR/kraken2" "$W/up.tsv" "$W/up.jsonl" "${COMMON[@]}" 2>> "$LOG"
  log "upstream: $(wc -l < "$W/up.jsonl") samples, exits $(jq -r .exit "$W/up.jsonl" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
  # A cohort with a failing sample (upstream exit != 0) ends with exit 1 (cohort.go).
  local want_rc=0
  [ "$(jq -s 'map(select(.exit != 0)) | length' "$W/up.jsonl")" -gt 0 ] && want_rc=1
  [ "$(jq -s 'map(select(.exit != 0)) | length' "$W/up.jsonl")" -gt 0 ] || { log "FAIL: no sample exits non-zero upstream; the failure path is not covered"; STATUS=1; }
  local mode
  for mode in "${MODES[@]}"; do
    local MW="$W/$mode" man="$W/$mode.tsv" base
    mkdir -p "$MW"; : > "$man"
    for s in "${SAMPLES[@]}"; do
      IFS='|' read -r name opts ins outs <<< "$s"
      case "$mode" in
        n1) base="$MW/$name"; mkdir -p "$base"; manifest_line 0 3 parallel - "$name" "$base" yes >> "$man" ;;
        n3) base="$MW/$name"; mkdir -p "$base"; manifest_line 0 2 parallel - "$name" "$base" yes >> "$man" ;;
        n3-striped) base="$MW/$name"; mkdir -p "$base"; manifest_line 0 1 striped - "$name" "$base" yes >> "$man" ;;
        n3-sdk) manifest_line 0 2 parallel sdk "$name" "s3://bkt/$mode/$name" yes >> "$man" ;;
        n3-lpt) base="$MW/$name"; mkdir -p "$base"; manifest_line 0 2 parallel:lpt - "$name" "$base" yes >> "$man" ;;
      esac
    done
    local fpid="" envs=()
    if [ "$mode" = n3-sdk ]; then
      rm -f "$MW/fakes3.url"
      "$K2P" fakes3 -dir "$MW/s3" -url-file "$MW/fakes3.url" 2>> "$LOG" &
      fpid=$!
      for _ in $(seq 50); do [ -s "$MW/fakes3.url" ] && break; sleep 0.1; done
      envs=(AK2_S3_ENDPOINT="$(cat "$MW/fakes3.url")" AK2_ALLOWED_BUCKETS=bkt AK2_S3_CLIENT=sdk)
    fi
    local t0 t1 rc
    t0=$(date +%s)
    if [ "$mode" = n1 ]; then
      env "${envs[@]}" AK2_ENGINE_N=1 AK2_COHORT="$man" AK2_TIMINGS=1 "$OURS" "${COMMON[@]}" 2> "$MW/rank0.stderr"; rc=$?
    else
      local rv="$MW/rv" pids=() k
      mkdir -p "$rv"
      for k in 1 2; do
        env "${envs[@]}" AK2_ENGINE_N=3 AK2_ENGINE_RANK=$k AK2_ENGINE_RENDEZVOUS="$rv" AK2_ENGINE_TIMEOUT=3m \
          AK2_COHORT="$man" AK2_TIMINGS=1 "$OURS" "${COMMON[@]}" 2> "$MW/rank$k.stderr" & pids+=($!)
      done
      env "${envs[@]}" AK2_ENGINE_N=3 AK2_ENGINE_RANK=0 AK2_ENGINE_RENDEZVOUS="$rv" AK2_ENGINE_TIMEOUT=3m \
        AK2_COHORT="$man" AK2_TIMINGS=1 "$OURS" "${COMMON[@]}" 2> "$MW/rank0.stderr"; rc=$?
      for k in "${pids[@]}"; do wait "$k"; local prc=$?; [ "$prc" = "$want_rc" ] || { log "$mode: a peer exited $prc (want $want_rc)"; STATUS=1; }; done
    fi
    t1=$(date +%s)
    [ -n "$fpid" ] && { kill "$fpid"; wait "$fpid" 2>/dev/null; }
    log "$mode: cohort exit $rc in $((t1 - t0)) s (want $want_rc)"
    [ "$rc" = "$want_rc" ] || STATUS=1
    # Placement: every home rank as the manifest's placement says (j mod N, or LPT).
    case "$mode" in
      n3|n3-sdk|n3-lpt)
        python3 scripts/lib/lpt_check.py 3 "$man" "$MW"/rank*.stderr > "$MW/placement.txt" 2>&1
        local prc=$?
        sed "s/^/$mode: /" "$MW/placement.txt" | tee -a "$LOG"
        [ "$prc" = 0 ] || { log "$mode: FAIL: placement differs from the manifest's"; STATUS=1; }
        # The LPT check can only see LPT if LPT's placement differs from j mod N here.
        if [ "$mode" = n3-lpt ] && ! grep -q 'differs from j mod N: yes' "$MW/placement.txt"; then
          log "$mode: FAIL: the LPT placement equals j mod N for these samples (the check cannot resolve it)"; STATUS=1
        fi ;;
    esac
  done
  # Compare.
  local T="$RES/samples.tsv"
  printf 'mode\tsample\tupstream_exit\tengine_exit\tfiles_upstream\tfiles_engine\tfiles_identical\tsets_equal\tcontrol\tpass\n' > "$T"
  for mode in "${MODES[@]}"; do
    for s in "${SAMPLES[@]}"; do
      IFS='|' read -r name opts ins outs <<< "$s"
      local ue ee udir edir
      ue=$(jq -r --arg n "$name" 'select(.name == $n) | .exit' "$W/up.jsonl")
      ee=$(cat "$W/$mode"/rank*.stderr | awk -F'\t' -v n="$name" '$1=="ak2-sample" && $5==n && ($13=="home" || $13=="emitter") {print $31}' | tail -1)
      udir="$W/up/$name"
      if [ "$mode" = n3-sdk ]; then edir="$W/$mode/s3/bkt/$mode/$name"; else edir="$W/$mode/$name"; fi
      local uf ef same=0 diffs=0 f
      uf=$(cd "$udir" 2>/dev/null && ls | sort | tr '\n' ' ')
      ef=$(cd "$edir" 2>/dev/null && ls | sort | tr '\n' ' ')
      for f in $uf; do
        if [ -f "$edir/$f" ] && [ "$(sha "$udir/$f")" = "$(sha "$edir/$f")" ]; then same=$((same + 1))
        else diffs=$((diffs + 1)); log "DIFF $db $mode $name $f"; fi
      done
      local sets=no; [ "$uf" = "$ef" ] && sets=yes
      local ctl=no pass=no
      [ "$name" = control ] && ctl=yes
      if [ "$ctl" = no ] && [ "$ue" = "$ee" ] && [ "$sets" = yes ] && [ "$diffs" = 0 ] && [ "$same" -gt 0 ]; then pass=yes; fi
      if [ "$ctl" = yes ] && [ "$ue" = "$ee" ] && [ "$diffs" -gt 0 ]; then pass=yes; fi
      [ "$pass" = yes ] || STATUS=1
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$name" "${ue:--}" "${ee:--}" "$(echo $uf | wc -w | tr -d ' ')" \
        "$(echo $ef | wc -w | tr -d ' ')" "$same" "$sets" "$ctl" "$pass" >> "$T"
    done
  done
  local stop; stop=$(date -u +%FT%TZ)
  local dirty=false
  if ! git diff --quiet HEAD -- . ':!results' || [ -n "$(git ls-files --others --exclude-standard -- . ':!results')" ]; then dirty=true; fi
  local total pass
  total=$(awk 'NR>1' "$T" | wc -l | tr -d ' '); pass=$(awk -F'\t' 'NR>1 && $10=="yes"' "$T" | wc -l | tr -d ' ')
  jq -n --arg db "$db" --arg dbdir "$(basename "$dbdir")" --arg commit "$(git rev-parse HEAD)" --argjson dirty "$dirty" \
    --arg pin "$UPSTREAM_SHA" --arg describe "$UPSTREAM_DESCRIBE" --arg start "$start" --arg stop "$stop" \
    --arg os "$(uname -s)" --arg arch "$(uname -m)" --argjson total "$total" --argjson pass "$pass" \
    --arg modes "${MODES[*]}" --argjson nsamples "${#SAMPLES[@]}" \
    --arg gzip "$(gzip --version 2>&1 | head -1)" --arg gzip_path "$(command -v gzip)" --arg ak2_decompress "${AK2_DECOMPRESS:-}" \
    '{gate:"g1", what:"make oracle-cohort: upstream kraken2 per sample vs the engine cohort mode, byte-identity per sample (Law 1, #25)",
      db:$db, db_dir:$dbdir, commit:$commit, dirty:$dirty, upstream_pin:$pin, upstream_describe:$describe,
      host:{os:$os, arch:$arch, canonical_platform:($os == "Linux" and $arch == "aarch64")},
      gzip:{version:$gzip, path:$gzip_path},
      decompress:{ak2_decompress:$ak2_decompress,
                  ours:(if $ak2_decompress == "pipe" then "gzip -dc / bzip2 -dc from PATH (as the wrapper)" else "in process" end)},
      modes:($modes|split(" ")), samples:$nsamples, rows:$total, rows_passed:$pass,
      start:$start, stop:$stop, failed:($pass != $total)}' > "$RES/manifest.json"
  {
    echo "# make oracle-cohort: $db, $TS"
    echo
    echo "Upstream at \`$UPSTREAM_SHA\` per sample vs the engine's cohort mode at \`$(git rev-parse HEAD)\` (dirty: $dirty), on $(uname -s) $(uname -m)."
    echo "Decompression: ours $(jq -r .decompress.ours "$RES/manifest.json") (AK2_DECOMPRESS='${AK2_DECOMPRESS:-}'); gzip on PATH: $(gzip --version 2>&1 | head -1) ($(command -v gzip))."
    echo
    echo "| mode | samples | passed | control flagged |"
    echo "|---|---|---|---|"
    awk -F'\t' 'NR>1 { n[$1]++; if ($10=="yes" && $9=="no") p[$1]++; if ($9=="yes" && $10=="yes") c[$1]++ }
      END { for (m in n) printf "| %s | %d | %d | %s |\n", m, n[m]-1, p[m]+0, (c[m] ? "yes" : "NO") }' "$T" | sort
    echo
    echo "Per sample: \`samples.tsv\` (exit statuses, file counts, identical files, file sets). Log: \`run.log\`."
  } > "$RES/summary.md"
  jq -e '.failed == false' "$RES/manifest.json" >/dev/null || STATUS=1
  log "results: $RES ($pass of $total rows pass)"
}
for db in "${DBS[@]}"; do run_db "$db"; done
[ "$STATUS" = 0 ] && echo "oracle-cohort: ok" || echo "oracle-cohort: FAILED" >&2
exit "$STATUS"
