#!/usr/bin/env bash
# #25/#44 probe (d): does the #44 fix (HitCounts, internal/classify/hitcounts.go) change our
# classifier's speed? The pre-fix engine (the last campaign commit, PRE, default 3201a75: the E4
# run) against POST (default HEAD), each built from a git archive of its commit, on a real read
# set (SRR062634, 8,000,000 pairs, fq) against Standard-8, single node, THREADS threads, warm
# (the DB in the page cache: one unrecorded run each first), REPS repetitions alternating
# pre/post. Records wall and the classifier's own "processed in" seconds per run, and each run's
# output and report sha256 (Law 1 is checked elsewhere; a pre/post difference is reported here).
#
#   scripts/g3/hitbench.sh [PRE] [POST]   -> results/g3/hitbench/<UTC>-<post7>/{runs.tsv,summary.tsv,env.txt}
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
echo "hitbench: shell flags $-"
PRE=${1:-3201a75}; POST=${2:-HEAD}; THREADS=${THREADS:-8}; REPS=${REPS:-5}
PRE=$(git rev-parse --short=7 "$PRE") && POST=$(git rev-parse --short=7 "$POST") || exit 2
DB="$K2_DB_ROOT/k2_standard_08_GB_20260626"; R="$K2_READS/SRR062634_8000000"
[ -s "$DB/hash.k2d" ] && [ -s "${R}_1.fq" ] && [ -s "${R}_2.fq" ] || { echo "hitbench: need Standard-8 and SRR062634_8000000 fq" >&2; exit 1; }
OUT="results/g3/hitbench/$(date -u +%Y%m%dT%H%M%SZ)-$POST"; mkdir -p "$OUT" || exit 1
T=$(mktemp -d "${TMPDIR:-/tmp}/ak2-hitbench.XXXXXX"); trap 'rm -rf "$T"' EXIT
for c in "$PRE" "$POST"; do
  mkdir -p "$T/$c" && git archive "$c" | tar -x -C "$T/$c" || exit 1
  (cd "$T/$c" && CGO_ENABLED=0 go build -o "$T/ak2-$c" ./cmd/aws-kraken2) || { echo "hitbench: build $c failed" >&2; exit 1; }
done
{ echo "pre $PRE post $POST threads $THREADS reps $REPS"; go version; uname -a; sysctl -n machdep.cpu.brand_string 2>/dev/null; } > "$OUT/env.txt"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
printf 'rep\timpl\tcommit\twall_s\tclassify_s\texit\toutput_sha256\treport_sha256\n' > "$OUT/runs.tsv"
one() {
  local rep=$1 impl=$2 c=$3 t0 t1 rc cs
  t0=$(now)
  "$T/ak2-$c" --db "$DB" --paired --threads "$THREADS" --output "$T/o" --report "$T/r" "${R}_1.fq" "${R}_2.fq" > /dev/null 2> "$T/e"
  rc=$?; t1=$(now)
  cs=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$T/e" | tail -1)
  [ "$rep" = 0 ] && return 0   # the unrecorded warm-up
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rep" "$impl" "$c" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')" \
    "${cs:--}" "$rc" "$(shasum -a 256 "$T/o" | cut -d' ' -f1)" "$(shasum -a 256 "$T/r" | cut -d' ' -f1)" | tee -a "$OUT/runs.tsv"
}
one 0 pre "$PRE"; one 0 post "$POST"
for ((k = 1; k <= REPS; k++)); do
  if [ $((k % 2)) = 1 ]; then one "$k" pre "$PRE"; one "$k" post "$POST"; else one "$k" post "$POST"; one "$k" pre "$PRE"; fi
done
python3 - "$OUT" <<'EOF'
import csv, statistics, sys
d = sys.argv[1]
R = list(csv.DictReader(open(f"{d}/runs.tsv"), delimiter="\t"))
out = [["impl", "n", "wall_median_s", "wall_min_s", "wall_max_s", "classify_median_s", "classify_min_s", "classify_max_s", "exits_nonzero", "distinct_outputs"]]
med = {}
for impl in ("pre", "post"):
    x = [r for r in R if r["impl"] == impl]
    w = [float(r["wall_s"]) for r in x]
    c = [float(r["classify_s"]) for r in x if r["classify_s"] != "-"]
    med[impl] = (statistics.median(w), statistics.median(c) if c else float("nan"), min(w), max(w))
    out.append([impl, len(x), f"{med[impl][0]:.3f}", f"{min(w):.3f}", f"{max(w):.3f}",
                f"{med[impl][1]:.3f}" if c else "-", f"{min(c):.3f}" if c else "-", f"{max(c):.3f}" if c else "-",
                sum(r["exit"] != "0" for r in x), len({r["output_sha256"] for r in x})])
sp = max(med["pre"][3] - med["pre"][2], med["post"][3] - med["post"][2])
out.append(["post/pre", "-", f"{med['post'][0] / med['pre'][0]:.4f}", "-", "-", f"{med['post'][1] / med['pre'][1]:.4f}", "-", "-", "-",
            "same" if {r["output_sha256"] for r in R if r["impl"] == "pre"} == {r["output_sha256"] for r in R if r["impl"] == "post"} else "differ"])
out.append(["resolution", "-", f"max within-impl wall spread {sp:.3f} s", "-", "-", "-", "-", "-", "-", "-"])
with open(f"{d}/summary.tsv", "w") as fh:
    for r in out:
        fh.write("\t".join(map(str, r)) + "\n")
print(open(f"{d}/summary.tsv").read())
EOF
echo "hitbench: $OUT"
