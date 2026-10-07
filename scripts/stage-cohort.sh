#!/usr/bin/env bash
# make stage-cohort (docs/cohort.md): the real cohort the G3 sweep uses (#25), PRJNA398089
# (IBDMDB/HMP2 stool metagenomes, ENA).
#
#   scripts/stage-cohort.sh record [PROJECT] [COUNT]
#       Record the cohort before any use (the #6 procedure): query ENA's filereport for PROJECT,
#       keep paired WGS runs with exactly two files <run>_1.fastq.gz and <run>_2.fastq.gz, order by
#       run accession (numerically), and write the first COUNT (default 1000) to
#       results/cohort/<PROJECT>/runs.tsv (rank, run, sample, read_count, base_count, and per mate:
#       URL, bytes, md5), with query.json (URL, time, the rule, sha256 of the raw response). Refuses
#       to overwrite a recorded cohort: the cohort is fixed once recorded.
#   scripts/stage-cohort.sh stage [PROJECT] [COUNT]
#       Stage the first COUNT runs (default 10) of the recorded cohort into
#       s3://<results bucket>/aws-kraken2/data/cohort/<run>_{1,2}.fastq.gz: download from ENA,
#       check bytes and md5 against runs.tsv, upload with sha256 and md5 as metadata, check them
#       with head-object, tag. Idempotent: an object whose metadata matches is skipped. Appends to
#       results/cohort/<PROJECT>/staged.tsv (run, mate, bytes, md5, sha256, key, version, at).
#       Downloads go to the shared .cache/cohort/ and are deleted once staged (STAGE_KEEP=1 keeps).
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/pin.env
. scripts/paths.sh
. scripts/ak2.env
# shellcheck source=/dev/null
. scripts/lib/tags.sh
export AWS_PROFILE
echo "stage-cohort: shell flags $-"
PART=${1:-stage}; PROJECT=${2:-PRJNA398089}
[[ "$PROJECT" =~ ^PRJ[A-Z]{2}[0-9]+$ ]] || { echo "stage-cohort: bad project $PROJECT" >&2; exit 2; }
DIR="results/cohort/$PROJECT"
for t in curl jq python3 aws; do command -v "$t" >/dev/null || { echo "stage-cohort: need $t" >&2; exit 1; }; done
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
if command -v md5sum >/dev/null; then md5of() { md5sum "$1" | cut -d" " -f1; }; else md5of() { md5 -q "$1"; }; fi

case "$PART" in
record)
  COUNT=${3:-1000}
  [[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "stage-cohort: bad COUNT $COUNT" >&2; exit 2; }
  [ ! -e "$DIR/runs.tsv" ] || { echo "stage-cohort: $DIR/runs.tsv is recorded; a cohort is never re-recorded" >&2; exit 1; }
  mkdir -p "$DIR" || exit 1
  FIELDS=run_accession,sample_accession,library_strategy,library_layout,read_count,base_count,fastq_ftp,fastq_bytes,fastq_md5
  URL="https://www.ebi.ac.uk/ena/portal/api/filereport?accession=$PROJECT&result=read_run&fields=$FIELDS&format=tsv&limit=0"
  RAW=$(mktemp) || exit 1
  curl -fsS --retry 5 --retry-delay 5 "$URL" -o "$RAW" || { echo "stage-cohort: ENA query failed" >&2; exit 1; }
  AT=$(date -u +%FT%TZ)
  python3 - "$RAW" "$COUNT" "$DIR/runs.tsv" <<'EOF' || { echo "stage-cohort: selection failed" >&2; exit 1; }
import csv, re, sys
raw, count, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = list(csv.DictReader(open(raw), delimiter="\t"))
keep = []
for r in rows:
    if r["library_layout"] != "PAIRED" or r["library_strategy"] != "WGS":
        continue
    run = r["run_accession"]
    ftp, by, md = r["fastq_ftp"].split(";"), r["fastq_bytes"].split(";"), r["fastq_md5"].split(";")
    names = [f.rsplit("/", 1)[-1] for f in ftp]
    if names != [f"{run}_1.fastq.gz", f"{run}_2.fastq.gz"] or len(by) != 2 or len(md) != 2:
        continue
    if not r["read_count"] or not all(re.fullmatch(r"[0-9a-f]{32}", m) for m in md):
        continue
    keep.append((run, r, ftp, by, md))
num = lambda run: (re.match(r"[A-Z]+", run).group(0), int(re.search(r"[0-9]+$", run).group(0)))
keep.sort(key=lambda k: num(k[0]))
if len(keep) < count:
    sys.exit(f"only {len(keep)} runs qualify, {count} asked")
with open(out, "w") as f:
    f.write("rank\trun\tsample\tread_count\tbase_count\turl_1\tbytes_1\tmd5_1\turl_2\tbytes_2\tmd5_2\n")
    for i, (run, r, ftp, by, md) in enumerate(keep[:count], 1):
        f.write(f"{i}\t{run}\t{r['sample_accession']}\t{r['read_count']}\t{r['base_count']}\t"
                f"https://{ftp[0]}\t{by[0]}\t{md[0]}\thttps://{ftp[1]}\t{by[1]}\t{md[1]}\n")
print(f"stage-cohort: {len(keep)} runs qualify; recorded the first {count}", file=sys.stderr)
EOF
  jq -n --arg project "$PROJECT" --arg url "$URL" --arg at "$AT" --argjson count "$COUNT" \
    --arg raw_sha256 "$(sha "$RAW")" --arg raw_rows "$(($(wc -l < "$RAW") - 1))" --arg tsv_sha256 "$(sha "$DIR/runs.tsv")" \
    --arg commit "$(git rev-parse HEAD)" '{project:$project, query_url:$url, queried_at:$at, ena_rows:($raw_rows|tonumber),
      raw_response_sha256:$raw_sha256, rule:"library_layout PAIRED, library_strategy WGS, exactly two files <run>_1.fastq.gz and <run>_2.fastq.gz with md5s; ordered by run accession numerically; the first count",
      count:$count, runs_tsv_sha256:$tsv_sha256, recorded_at_commit:$commit}' > "$DIR/query.json"
  rm -f "$RAW"
  awk -F'\t' 'NR>1{p+=$4; b+=$7+$10} END{printf "stage-cohort: %d runs, %.2f G pairs, %.2f TB fastq.gz\n", NR-1, p/1e9, b/1e12}' "$DIR/runs.tsv"
  ;;
stage)
  COUNT=${3:-10}
  [ -s "$DIR/runs.tsv" ] || { echo "stage-cohort: no recorded cohort $DIR/runs.tsv (stage-cohort.sh record first)" >&2; exit 1; }
  BUCKET=$AK2_RESULTS_BUCKET_us_west_2
  KEY="$AK2_RESULTS_ROOT/data/cohort"
  CACHE="$K2_SHARED_ROOT/.cache/cohort"; mkdir -p "$CACHE" || exit 1
  [ -s "$DIR/staged.tsv" ] || printf 'run\tmate\tbytes\tmd5\tsha256\tkey\tversion_id\tat\n' > "$DIR/staged.tsv"
  FAILED=0
  while IFS=$'\t' read -r rank run sample reads bases u1 b1 m1 u2 b2 m2; do
    [ "$rank" = rank ] && continue
    [ "$rank" -le "$COUNT" ] || break
    for m in 1 2; do
      if [ $m = 1 ]; then u=$u1; b=$b1; want=$m1; else u=$u2; b=$b2; want=$m2; fi
      f="${run}_$m.fastq.gz"; k="$KEY/$f"
      have=$(aws s3api head-object --region us-west-2 --bucket "$BUCKET" --key "$k" --query 'Metadata.md5' --output text 2>/dev/null)
      if [ "$have" = "$want" ]; then echo "stage-cohort: $f present (md5 $want)"; continue; fi
      p="$CACHE/$f"
      if [ ! -s "$p" ] || [ "$(wc -c < "$p" | tr -d ' ')" != "$b" ]; then
        curl -fsS --retry 5 --retry-delay 10 -C - "$u" -o "$p" || curl -fsS --retry 5 --retry-delay 10 "$u" -o "$p" ||
          { echo "stage-cohort: download of $u failed" >&2; FAILED=1; continue; }
      fi
      [ "$(wc -c < "$p" | tr -d ' ')" = "$b" ] || { echo "stage-cohort: $f is $(wc -c < "$p") bytes, ENA says $b" >&2; FAILED=1; continue; }
      got=$(md5of "$p")
      [ "$got" = "$want" ] || { echo "stage-cohort: $f md5 $got, ENA says $want" >&2; FAILED=1; continue; }
      h=$(sha "$p")
      aws s3 cp --only-show-errors --region us-west-2 --metadata "sha256=$h,md5=$want" "$p" "s3://$BUCKET/$k" ||
        { echo "stage-cohort: upload of $f failed" >&2; FAILED=1; continue; }
      hd=$(aws s3api head-object --region us-west-2 --bucket "$BUCKET" --key "$k" --output json) ||
        { echo "stage-cohort: head-object $f failed" >&2; FAILED=1; continue; }
      [ "$(echo "$hd" | jq -r '[.Metadata.sha256, .Metadata.md5, (.ContentLength|tostring)] | join(" ")')" = "$h $want $b" ] ||
        { echo "stage-cohort: $f: head-object disagrees: $(echo "$hd" | jq -c '{Metadata, ContentLength}')" >&2; FAILED=1; continue; }
      ak2_tag_object "$BUCKET" "$k" data >/dev/null || { echo "stage-cohort: tagging $f failed" >&2; FAILED=1; continue; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$run" "$m" "$b" "$want" "$h" "$k" "$(echo "$hd" | jq -r '.VersionId // "null"')" \
        "$(date -u +%FT%TZ)" >> "$DIR/staged.tsv"
      echo "stage-cohort: $f staged ($b bytes, md5 $want, sha256 $h)"
      [ "${STAGE_KEEP:-0}" = 1 ] || rm -f "$p"
    done
  done < "$DIR/runs.tsv"
  [ "$FAILED" = 0 ] || { echo "stage-cohort: FAILED" >&2; exit 1; }
  echo "s3://$BUCKET/$KEY/"
  ;;
*) echo "usage: $0 record|stage [PROJECT] [COUNT]" >&2; exit 2 ;;
esac
