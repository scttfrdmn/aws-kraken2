#!/usr/bin/env bash
# make bracken-check (issue #19): Bracken spot-check. Run upstream's kraken2 wrapper at the pin and
# our bin/aws-kraken2 with identical arguments on real paired reads against Standard-8, then run
# Bracken's est_abundance.py (pinned release) on each side's --report at each level, and
# byte-compare everything: the kraken --report and --output, Bracken's -o table, Bracken's
# --out-report, and Bracken's stdout (minus its two wall-clock lines). See docs/bracken-check.md.
#
# Usage: scripts/bracken-check.sh
# Env:   BRACKEN_THREADS  kraken2 --threads for both sides (default 8)
#        BRACKEN_PYTHON   the Python that runs est_abundance.py (default python3)
#        DECOMP_BIN       as make oracle (only matters for gz input; the reads here are plain)
# Writes results/g1/bracken-<UTC ts>-<short sha>/{manifest.json,cases.tsv,bracken.tsv,summary.md,
# commands.txt,run.log,outputs/} (every number computed here) and the kraken outputs under
# .cache/bracken/<ts>/.
# Exits non-zero on any difference, any non-zero exit, or a Bracken run that estimated nothing.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
. scripts/pin.env
. scripts/paths.sh
echo "bracken-check: shell flags $-"
INVOCATION="scripts/bracken-check.sh $*"

# Bracken pin: the v3.1 release (tag v3.1 is a lightweight tag on this commit).
BRACKEN_REPO=https://github.com/jenniferlu717/Bracken.git
BRACKEN_TAG=v3.1
BRACKEN_PIN=cfeac04b6445c44c3825866683a6fdd18746cb58
READ_LEN=100          # -r: SRR062634 is 100 bp; ERR478965 is trimmed, up to 100 bp
THRESH=10             # -t: Bracken's own default (bracken wrapper, THRESHOLD=10)
LEVELS=(S G)
SAMPLES=(ERR478965 SRR062634)
N=200000
TH=${BRACKEN_THREADS:-8}
PY=${BRACKEN_PYTHON:-python3}
DB="$K2_DB_ROOT/k2_standard_08_GB_20260626"

if [ -n "${DECOMP_BIN:-}" ]; then PATH="$DECOMP_BIN:$PATH"
elif [ -x /tmp/gnugzip/inst/bin/gzip ]; then PATH="/tmp/gnugzip/inst/bin:$PATH"; fi
export PATH
unset KRAKEN2_DB_PATH KRAKEN2_DEFAULT_DB KRAKEN2_NUM_THREADS
for t in jq perl awk cmp git "$PY"; do
  command -v "$t" >/dev/null || { echo "bracken-check: need $t" >&2; exit 1; }
done
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi

# ---- inputs -----------------------------------------------------------------------------------
K2DIR=$(scripts/oracle-build.sh) || { echo "bracken-check: upstream build failed" >&2; exit 1; }
UP="$K2DIR/kraken2"
make -s build || { echo "bracken-check: go build failed" >&2; exit 1; }
OURS="$ROOT/bin/aws-kraken2"
for f in "$DB/hash.k2d" "$DB/SOURCE" "$DB/database${READ_LEN}mers.kmer_distrib"; do
  [ -s "$f" ] || { echo "bracken-check: missing $f (scripts/fetch-db.sh standard8)" >&2; exit 1; }
done
for acc in "${SAMPLES[@]}"; do
  [ -s "$K2_READS/${acc}_$N.SOURCE" ] || scripts/fetch-reads.sh "$acc" "$N" >/dev/null \
    || { echo "bracken-check: cannot fetch reads $acc" >&2; exit 1; }
done

# Bracken at the pin, in this checkout's .cache (a script's own build artifacts stay local).
BSRC="$ROOT/.cache/bracken-src"
if [ ! -d "$BSRC/.git" ]; then
  git clone -q "$BRACKEN_REPO" "$BSRC" || { echo "bracken-check: clone failed" >&2; exit 1; }
fi
git -C "$BSRC" fetch -q --tags origin 2>/dev/null
git -C "$BSRC" checkout -q --detach "$BRACKEN_PIN" || { echo "bracken-check: checkout failed" >&2; exit 1; }
[ "$(git -C "$BSRC" rev-parse HEAD)" = "$BRACKEN_PIN" ] || { echo "bracken-check: Bracken HEAD is not the pin" >&2; exit 1; }
[ "$(git -C "$BSRC" rev-parse "$BRACKEN_TAG^{commit}")" = "$BRACKEN_PIN" ] \
  || { echo "bracken-check: tag $BRACKEN_TAG does not resolve to $BRACKEN_PIN" >&2; exit 1; }
git -C "$BSRC" diff --quiet HEAD -- || { echo "bracken-check: $BSRC has tracked modifications" >&2; exit 1; }
EST="$BSRC/src/est_abundance.py"
UPDESC=$(awk '$1=="describe"{print $2}' "$K2DIR/BUILD")
[ "$(awk '$1=="pin"{print $2}' "$K2DIR/BUILD")" = "$UPSTREAM_PIN" ] \
  || { echo "bracken-check: $K2DIR/BUILD is not the pin" >&2; exit 1; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
SHORT=$(git rev-parse --short HEAD)
WORK="$K2_SHARED_ROOT/.cache/bracken/$TS"
RES="$ROOT/results/g1/bracken-$TS-$SHORT"
mkdir -p "$WORK" "$RES" || exit 1
LOG="$RES/run.log"
: > "$LOG"
log() { echo "$*" | tee -a "$LOG"; }
log "shell flags: $-"
log "pin $UPSTREAM_PIN ($UPDESC)  bracken $BRACKEN_TAG $BRACKEN_PIN  python $("$PY" --version 2>&1)"
log "db $DB  threads $TH  work $WORK"
START=$(date -u +%FT%TZ)
FAILED=0
printf 'sample\tlevel\tfile\tupstream_bytes\tours_bytes\tupstream_sha256\tours_sha256\tidentical\n' > "$RES/cases.tsv"
printf 'sample\tlevel\tbracken_rows\tspecies_or_genera_total\tabove_threshold\treads_distributed\tupstream_exit\tours_exit\n' > "$RES/bracken.tsv"
: > "$RES/commands.txt"

# compare <sample> <level> <name> <upstream file> <ours file>
compare() {
  local a=$4 b=$5 same=no
  [ -e "$a" ] && [ -e "$b" ] && cmp -s "$a" "$b" && same=yes
  [ "$same" = yes ] || FAILED=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" \
    "$(wc -c < "$a" 2>/dev/null | tr -d ' ')" "$(wc -c < "$b" 2>/dev/null | tr -d ' ')" \
    "$(sha "$a" 2>/dev/null)" "$(sha "$b" 2>/dev/null)" "$same" >> "$RES/cases.tsv"
  log "$1 $2 $3: identical=$same"
}

for acc in "${SAMPLES[@]}"; do
  stem="$K2_READS/${acc}_$N"
  for side in upstream ours; do
    d="$WORK/$acc/$side"; mkdir -p "$d"
    bin=$UP; [ "$side" = ours ] && bin=$OURS
    # Identical arguments on both sides; only the executable differs. Relative output names, run
    # from the side's own directory, so Bracken's stdout (which echoes paths) is comparable too.
    args=(--db "$DB" --threads "$TH" --paired --report kraken.report --output kraken.out
          "${stem}_1.fq" "${stem}_2.fq")
    echo "(cd $d && $bin ${args[*]})" >> "$RES/commands.txt"
    (cd "$d" && "$bin" "${args[@]}") 2> "$d/kraken.stderr"
    st=$?
    echo "$st" > "$d/kraken.exit"
    log "$acc $side kraken2: exit $st; $(tr '\r' '\n' < "$d/kraken.stderr" | grep -E 'processed|classified' | tr -s ' ' | paste -sd' ' - | head -c 300)"
    [ "$st" = 0 ] || FAILED=1
    for L in "${LEVELS[@]}"; do
      bargs=(-i kraken.report -k "$DB/database${READ_LEN}mers.kmer_distrib" -l "$L" -t "$THRESH"
             -o "bracken.$L.tsv" --out-report "bracken.$L.report")
      echo "(cd $d && $PY $EST ${bargs[*]})" >> "$RES/commands.txt"
      (cd "$d" && "$PY" "$EST" "${bargs[@]}") > "$d/bracken.$L.stdout" 2> "$d/bracken.$L.stderr"
      st=$?
      echo "$st" > "$d/bracken.$L.exit"
      grep -v -E '^PROGRAM (START|END) TIME: ' "$d/bracken.$L.stdout" > "$d/bracken.$L.stdout.notime"
      log "$acc $side bracken -l $L: exit $st"
      [ "$st" = 0 ] || FAILED=1
    done
  done
  U="$WORK/$acc/upstream"; O="$WORK/$acc/ours"
  compare "$acc" - kraken.report "$U/kraken.report" "$O/kraken.report"
  compare "$acc" - kraken.out "$U/kraken.out" "$O/kraken.out"
  compare "$acc" - kraken.exit "$U/kraken.exit" "$O/kraken.exit"
  for L in "${LEVELS[@]}"; do
    compare "$acc" "$L" "bracken -o" "$U/bracken.$L.tsv" "$O/bracken.$L.tsv"
    compare "$acc" "$L" "bracken --out-report" "$U/bracken.$L.report" "$O/bracken.$L.report"
    compare "$acc" "$L" "bracken stdout (time lines removed)" "$U/bracken.$L.stdout.notime" "$O/bracken.$L.stdout.notime"
    compare "$acc" "$L" "bracken stderr" "$U/bracken.$L.stderr" "$O/bracken.$L.stderr"
    # Resolution: the check means something only if Bracken estimated and redistributed reads.
    rows=$(awk 'NR>1' "$U/bracken.$L.tsv" 2>/dev/null | wc -l | tr -d ' ')
    tot=$(awk -F': ' '/>>> Number of .* in sample:/{print $2+0}' "$U/bracken.$L.stdout")
    est=$(awk -F': ' '/Number of .* with reads > threshold:/{print $2+0}' "$U/bracken.$L.stdout")
    dist=$(awk -F': ' '/Reads distributed:/{print $2+0}' "$U/bracken.$L.stdout")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$acc" "$L" "$rows" "${tot:-}" "${est:-}" "${dist:-}" \
      "$(cat "$U/bracken.$L.exit")" "$(cat "$O/bracken.$L.exit")" >> "$RES/bracken.tsv"
    if [ "${rows:-0}" -lt 2 ] || [ "${dist:-0}" -le 0 ]; then
      log "FAIL $acc $L: Bracken estimated too little to resolve a difference (rows $rows, distributed ${dist:-none})"
      FAILED=1
    fi
  done
done
STOP=$(date -u +%FT%TZ)
# Bracken's outputs are small: keep the upstream side's as evidence (ours are byte-identical
# wherever cases.tsv says so; on a difference both sides are kept).
for acc in "${SAMPLES[@]}"; do
  for side in upstream ours; do
    [ "$side" = ours ] && [ "$FAILED" = 0 ] && continue
    mkdir -p "$RES/outputs/$acc/$side"
    cp "$WORK/$acc/$side"/bracken.*.tsv "$WORK/$acc/$side"/bracken.*.report "$WORK/$acc/$side"/bracken.*.stdout \
       "$WORK/$acc/$side/kraken.report" "$RES/outputs/$acc/$side/" 2>/dev/null
  done
done

# ---- manifest and summary ---------------------------------------------------------------------
dirty=false
if ! git diff --quiet HEAD -- . ':!results' || [ -n "$(git ls-files --others --exclude-standard -- . ':!results')" ]; then dirty=true; fi
canon=false; [ "$(uname -s)/$(uname -m)" = Linux/aarch64 ] && canon=true
reads='[]'
for acc in "${SAMPLES[@]}"; do
  reads=$(jq --arg stem "${acc}_$N" --rawfile src "$K2_READS/${acc}_$N.SOURCE" '. + [{stem: $stem, paired: true, source: $src}]' <<< "$reads")
done
total=$(awk 'NR>1' "$RES/cases.tsv" | wc -l | tr -d ' ')
ident=$(awk -F'\t' 'NR>1 && $8=="yes"' "$RES/cases.tsv" | wc -l | tr -d ' ')
expected=$(( ${#SAMPLES[@]} * (3 + 4 * ${#LEVELS[@]}) ))
[ "$total" = "$expected" ] || { log "FAIL: $total comparisons recorded, $expected expected"; FAILED=1; }
RESULT=PASS; [ "$FAILED" = 0 ] || RESULT=FAIL
jq -n \
  --arg gate g1 --arg what "make bracken-check: Bracken on upstream's vs our --report, byte-identity (#19)" \
  --arg invocation "$INVOCATION" --arg result "$RESULT" --argjson threads "$TH" \
  --arg commit "$(git rev-parse HEAD)" --argjson dirty "$dirty" \
  --arg pin "$UPSTREAM_PIN" --arg describe "$UPDESC" --rawfile upbuild "$K2DIR/BUILD" \
  --arg kraken2_sha "$(sha "$K2DIR/kraken2")" --arg classify_sha "$(sha "$K2DIR/classify")" \
  --arg ours_sha "$(sha "$OURS")" --arg go "$(go version)" \
  --arg brepo "$BRACKEN_REPO" --arg btag "$BRACKEN_TAG" --arg bpin "$BRACKEN_PIN" \
  --arg bdesc "$(git -C "$BSRC" describe --tags HEAD)" --arg est_sha "$(sha "$EST")" \
  --arg py "$("$PY" --version 2>&1)" --arg pypath "$(command -v "$PY")" \
  --argjson readlen "$READ_LEN" --argjson thresh "$THRESH" --arg levels "${LEVELS[*]}" \
  --arg dbname "$(basename "$DB")" --rawfile dbsource "$DB/SOURCE" \
  --arg etag "$(awk '$1=="etag"{print $2}' "$DB/SOURCE" | tr -d '"')" \
  --arg kmer_sha "$(sha "$DB/database${READ_LEN}mers.kmer_distrib")" \
  --argjson reads "$reads" \
  --arg os "$(uname -s)" --arg arch "$(uname -m)" --arg kernel "$(uname -r)" \
  --arg hostname "$(hostname -s 2>/dev/null || hostname)" \
  --arg model "$(sysctl -n hw.model 2>/dev/null || cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null || echo unknown)" \
  --argjson canonical "$canon" \
  --arg start "$START" --arg stop "$STOP" \
  --argjson comparisons "$total" --argjson identical "$ident" --argjson expected "$expected" \
  '{gate:$gate, what:$what, invocation:$invocation, result:$result,
    commit:$commit, dirty:$dirty,
    upstream_pin:$pin, upstream_describe:$describe,
    upstream:{kraken2_sha256:$kraken2_sha, classify_sha256:$classify_sha, build:$upbuild},
    ours:{aws_kraken2_sha256:$ours_sha, go:$go},
    bracken:{repo:$brepo, tag:$btag, commit:$bpin, describe:$bdesc, est_abundance_sha256:$est_sha,
             python:$py, python_path:$pypath, read_len:$readlen, threshold:$thresh, levels:$levels,
             kmer_distrib_sha256:$kmer_sha},
    kraken_args:{threads:$threads, paired:true},
    db:{dir:$dbname, source:$dbsource, etag:$etag},
    reads:$reads,
    host:{hostname:$hostname, os:$os, arch:$arch, kernel:$kernel, model:$model, canonical_platform:$canonical,
          note:(if $canonical then "Linux aarch64: the canonical oracle platform"
                else "local development host (not Linux aarch64); acceptable for this spot-check (#19)" end)},
    start:$start, stop:$stop,
    comparisons:$comparisons, comparisons_identical:$identical, comparisons_expected:$expected}' \
  > "$RES/manifest.json"

{
  m="$RES/manifest.json"
  echo "# make bracken-check: $TS"
  echo
  echo "Bracken $(jq -r .bracken.tag "$m") (\`$(jq -r .bracken.commit "$m")\`, $(jq -r .bracken.python "$m")) on the"
  echo "\`--report\` of upstream \`kraken2\` at \`$(jq -r .upstream_pin "$m")\` ($(jq -r .upstream_describe "$m")) and of"
  echo "\`bin/aws-kraken2\` at \`$(jq -r .commit "$m")\` (dirty: $(jq -r .dirty "$m")), same arguments,"
  echo "DB $(jq -r .db.dir "$m") (ETag $(jq -r .db.etag "$m")), \`-r $(jq -r .bracken.read_len "$m") -t $(jq -r .bracken.threshold "$m")\`,"
  echo "levels $(jq -r .bracken.levels "$m"). Host: $(jq -r '.host.hostname + ", " + .host.os + " " + .host.arch + " (" + .host.model + ")"' "$m"); $(jq -r .host.note "$m")."
  echo
  echo "**Result: $(jq -r .result "$m")** — $(jq -r .comparisons_identical "$m") of $(jq -r .comparisons "$m") byte comparisons identical ($(jq -r .comparisons_expected "$m") expected)."
  echo
  echo "| sample | level | file | bytes (upstream) | identical |"
  echo "|---|---|---|---|---|"
  awk -F'\t' 'NR>1{printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $8}' "$RES/cases.tsv"
  echo
  echo "What Bracken did on the upstream side (from its stdout), showing the comparison could resolve a difference:"
  echo
  echo "| sample | level | rows in -o table | taxa at level | above threshold | reads distributed |"
  echo "|---|---|---|---|---|---|"
  awk -F'\t' 'NR>1{printf "| %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6}' "$RES/bracken.tsv"
  awk -F'\t' 'NR>1 && $5+0 < 10 {w = w (w ? ", " : "") $1 " " $2 " (" $5 ")"}
    END { if (w) printf "\nLow resolution (fewer than 10 taxa above threshold, so few redistributions to disagree on): %s.\n", w }' "$RES/bracken.tsv"
} > "$RES/summary.md"
log "result: $RESULT ($ident/$total identical)"
log "results: $RES"
exit "$FAILED"
