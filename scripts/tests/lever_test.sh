#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2319  # checks read the $? of a test; A && B || C is meant
# make lever-test (docs/ladder.md): the ladder lever library, scripts/g3/lever.sh, in Amazon Linux
# 2023 (podman). The payload is exactly what a spec runs, scripts/preamble.sh followed by a body
# (scripts/tests/lever_body.sh) that sources lever.sh, started as `bash -e -c` the way spawn starts
# it ($- has e), with the preamble's traps, FIFO tee and pusher. The stand-ins are only at the
# edges: curl answers IMDS and the bucket-region HEAD; aws and s5cmd are stubs over a shared
# directory (/work/bucket) that log every call with its start and end time (uploads under up/
# take 2 s, input gets 0.4 s, so overlap and lane concurrency are visible); sudo runs the command;
# the image (localhost/ak2-lever-test) carries the real rapidgzip 0.14.5 wheel (installed by
# lever.sh with pip --require-hashes), the real s5cmd 2.3.0 tarball (its pinned sha256 checked)
# and AL2023's real awscli-2 rpm (the auto-rule check).
# Three cases, each its own container:
#   main    must exit 0 with no helper errors: lv_nvme (rehearsal seam), lv_stage_db with the
#           stock CLI as shipped (no config, even with one exported), classic and s5cmd (the
#           classic config in effect, each client recorded, the auto rule on the real CLI, s5cmd's flags, anonymous fallback, files identical,
#           request counts), lv_etag in its own phase (a real multipart ETag), lv_fetch_inputs
#           serial and lanes3 with the default client and lanes2 crt (all sha256-verified; serial never overlaps, lanes do), the
#           gunzip shim byte-identical to gzip -dc (plain and multi-member gz, directly and
#           through perl's open as upstream's wrapper does), uploads serial (blocks: the
#           contrast) and overlapped (by timestamps: enqueue returns at once, upload 1 inside
#           the body's next work, enqueue order, drain waits), the sha256 recorded before each
#           upload and equal to the object's, and lv_s5 letting a declared bucket through;
#   refuse  lv_s5 refuses an undeclared bucket (in any argument position) and `run`, never
#           reaching s5cmd; the run exits 126 with the refusals in helper-errors.tsv;
#   fail    a wrong ETag, a fetch with one bad sha256, a failed upload in the lane, bad modes:
#           each returns non-zero and the run exits 1 with them in helper-errors.tsv.
# Also: lever.sh passes scripts/lib/errexit_check.py (run.sh does not see sourced files) and the
# run log streamed "lever {json}" lines. Record: results/rehearse/lever-test-<UTC>-<commit>.log.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
command -v podman > /dev/null || { echo "lever-test: need podman (docs/ladder.md)" >&2; exit 1; }
SHA=$(git rev-parse --short=7 HEAD)
mkdir -p results/rehearse || exit 1
REC="results/rehearse/lever-test-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$REC") 2>&1
echo "lever-test: at $SHA ($(git diff --quiet HEAD -- scripts && echo clean || echo dirty)); shell flags $-; record $REC"
RC=0
say() { echo "lever-test: $*"; }
need() { if [ "$1" = 0 ]; then say "ok   $2"; else say "FAIL $2"; RC=1; fi; }

python3 scripts/lib/errexit_check.py < scripts/g3/lever.sh > /dev/null; need $? "lever.sh passes errexit_check.py"
bash -n scripts/g3/lever.sh && bash -n scripts/tests/lever_body.sh; need $? "lever.sh and the body parse"

# The image: AL2023 plus what an instance has (gzip, tar, perl, cmp) and the pinned rapidgzip wheel.
T=$(mktemp -d "$HOME/.ak2-lever-test.XXXXXX") || exit 1
cleanup() { [ "${KEEP:-0}" = 1 ] && echo "lever-test: kept $T" || rm -rf "$T"; }
trap cleanup EXIT
cat > "$T/Containerfile" << 'EOF'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023
RUN dnf install -y -q gzip tar perl-interpreter python3-pip diffutils findutils util-linux-core awscli-2 && dnf clean all
RUN python3 -m pip download -q --no-deps --only-binary=:all: -d /opt/wheels rapidgzip==0.14.5
RUN mkdir -p /opt/s5 && a=$(case $(uname -m) in aarch64) echo arm64 ;; *) echo 64bit ;; esac) && \
    curl -fsSL -o /opt/s5/s5cmd_2.3.0_Linux-$a.tar.gz https://github.com/peak/s5cmd/releases/download/v2.3.0/s5cmd_2.3.0_Linux-$a.tar.gz
EOF
IMG=localhost/ak2-lever-test:$(shasum -a 256 "$T/Containerfile" | cut -c1-12)
if ! podman image exists "$IMG"; then
  podman build -q -t "$IMG" -f "$T/Containerfile" "$T" > /dev/null || { echo "lever-test: could not build $IMG" >&2; exit 1; }
fi
say "image $IMG ($(podman image inspect --format '{{.Id}}' "$IMG" | cut -c1-12))"

mkdir -p "$T/bin" "$T/s5" "$T/out"
# ---- stand-ins ----
cat > "$T/bin/curl" << 'EOF'
#!/bin/bash
# IMDS and the bucket-region HEAD; anything else goes to the real curl.
url=""; for a in "$@"; do case $a in http*) url=$a ;; esac; done
case $url in
  *169.254.169.254*/api/token) echo tok ;;
  *meta-data/placement/region) echo us-west-2 ;;
  *meta-data/placement/availability-zone) echo us-west-2a ;;
  *meta-data/instance-id) echo i-levertest ;;
  *meta-data/instance-type) echo t.test ;;
  *meta-data/ami-id) echo ami-test ;;
  https://*.s3.*amazonaws.com/) printf 'HTTP/1.1 200 OK\r\nx-amz-bucket-region: us-west-2\r\n\r\n' ;;
  *) exec /usr/bin/curl "$@" ;;
esac
EOF
cat > "$T/bin/aws" << 'EOF'
#!/bin/bash
# The aws CLI over /work/bucket/<bucket>/<key>; metadata in /work/bucket/.meta/<bucket>/<key>.{sha256,etag}.
# Log: /work/bucket/.aws-calls.<case>, "t<TAB>op<TAB>src<TAB>dst<TAB>config<TAB>t0<TAB>t1". The bucket
# ak2-roda-test refuses signed head-object (the anonymous fallback); keys with FAILME fail.
B=/work/bucket
now() { date +%s.%3N; }
cfg=""; [ -n "${AWS_CONFIG_FILE:-}" ] && cfg=$(grep -h preferred_transfer_client "$AWS_CONFIG_FILE" 2> /dev/null | tr -d ' ')
log() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" "$cfg" "$4" "$5" >> "$B/.aws-calls.$LVT_CASE"; }
a=(); sign=signed
for x in "$@"; do case $x in --no-sign-request) sign=anon ;; --only-show-errors) ;; *) a+=("$x") ;; esac; done
case "${a[0]:-} ${a[1]:-}" in
  "s3 cp")
    s=${a[2]} d=${a[3]}
    if [[ $s == s3://* ]] && [[ $d != s3://* ]]; then
      k=${s#s3://}; [ -f "$B/$k" ] || { echo "download failed: $s NoSuchKey" >&2; exit 1; }
      t0=$(now); case $k in */cohort/*) sleep 0.4 ;; esac; cp "$B/$k" "$d" || exit 1; log get "$s" "$d" "$t0" "$(now)"
    elif [[ $d == s3://* ]]; then
      k=${d#s3://}; [[ $k == *FAILME* ]] && { echo "upload failed: $d" >&2; exit 1; }
      t0=$(now); case $k in */up/*) sleep 2 ;; esac
      mkdir -p "$B/$(dirname "$k")" && cp "$s" "$B/$k" || exit 1; log put "$s" "$d" "$t0" "$(now)"
    else exit 2; fi ;;
  "s3api head-object")
    b="" k="" q=""; prev=""
    for x in "${a[@]}"; do case $prev in --bucket) b=$x ;; --key) k=$x ;; --query) q=$x ;; esac; prev=$x; done
    [ "$b" = ak2-roda-test ] && [ "$sign" = signed ] && { echo "An error occurred (403) when calling the HeadObject operation: Forbidden" >&2; exit 254; }
    f=$B/$b/$k; [ -f "$f" ] || { echo "An error occurred (404) when calling the HeadObject operation: Not Found" >&2; exit 254; }
    if [ -f "$B/.meta/$b/$k.etag" ]; then e=$(cat "$B/.meta/$b/$k.etag"); else e=$(md5sum "$f" | cut -d' ' -f1); fi
    log head "s3://$b/$k" "" "$(now)" "$(now)"
    case $q in
      ETag) echo "\"$e\"" ;;
      ContentLength) stat -c%s "$f" ;;
      Metadata.sha256) if [ -f "$B/.meta/$b/$k.sha256" ]; then cat "$B/.meta/$b/$k.sha256"; else echo None; fi ;;
      '[ETag,ContentLength]') printf '"%s"\t%s\n' "$e" "$(stat -c%s "$f")" ;;
      *) exit 2 ;;
    esac ;;
  "s3api get-bucket-request-payment") echo BucketOwner ;;
  "configure get") [ -n "$cfg" ] && echo "${cfg#*=}" ;;
  *) [ "${a[0]:-}" = --version ] && echo "aws-cli/stub"; exit 0 ;;
esac
EOF
cat > "$T/s5/s5cmd" << 'EOF'
#!/bin/bash
# s5cmd over /work/bucket (cp both ways, ls). Every call but `version` is a line of
# /work/bucket/.s5-calls.<case> ("t<TAB>args"); uploads under up/ take 2 s; keys with FAILME fail.
B=/work/bucket
[ "${1:-}" = version ] && { echo "v2.3.0-stub"; exit 0; }
printf '%s\t%s\n' "$(date +%s.%3N)" "$*" >> "$B/.s5-calls.$LVT_CASE"
a=("$@"); i=0
while [[ ${a[$i]:-} == -* ]]; do case ${a[$i]} in --numworkers|-numworkers|--log|-log|--endpoint-url|-r|--retry-count|-retry-count) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac; done
sub=${a[$i]:-}; i=$((i + 1)); pos=()
while [ "$i" -lt "${#a[@]}" ]; do
  case ${a[$i]} in --concurrency|--part-size|-c|-p|--metadata) i=$((i + 2)); continue ;; -*) ;; *) pos+=("${a[$i]}") ;; esac
  i=$((i + 1))
done
case $sub in
  cp)
    s=${pos[0]} d=${pos[1]}
    if [[ $s == s3://* ]]; then k=${s#s3://}; [ -f "$B/$k" ] || exit 1; cp "$B/$k" "$d"
    else k=${d#s3://}; [[ $k == *FAILME* ]] && { echo "ERROR cp $s $d: stub failure" >&2; exit 1; }
      case $k in */up/*) sleep 2 ;; esac; mkdir -p "$B/$(dirname "$k")" && cp "$s" "$B/$k"; fi ;;
  ls) p=${pos[0]#s3://}; ls -1 "$B/$p" 2> /dev/null | sed 's/^/DATE TIME SIZE /' ;;
  *) exit 0 ;;
esac
EOF
printf '#!/bin/bash\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/bin/sudo"
chmod +x "$T/bin"/* "$T/s5/s5cmd"

# ---- the bucket (synthetic data: unit-test scope) ----
python3 - "$T/bucket" << 'PY'
import hashlib, os, random, sys
B = sys.argv[1]
r = random.Random(50)
def put(b, k, data, sha=None, etag=None):
    p = os.path.join(B, b, k); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data)
    m = os.path.join(B, ".meta", b, k); os.makedirs(os.path.dirname(m), exist_ok=True)
    if sha: open(m + ".sha256", "w").write(sha + "\n")
    if etag: open(m + ".etag", "w").write(etag + "\n")
put("ak2-roda-test", "db/opts.k2d", r.randbytes(56))
put("ak2-roda-test", "db/taxo.k2d", r.randbytes(100000))
h = r.randbytes(20 * 1048576 + 12345)
P = 8 * 1048576
parts = [hashlib.md5(h[i:i + P]).digest() for i in range(0, len(h), P)]
put("ak2-roda-test", "db/hash.k2d", h, etag=hashlib.md5(b"".join(parts)).hexdigest() + "-%d" % len(parts))
man = []
for i in range(1, 7):
    d = r.randbytes(r.randrange(200000, 600000))
    k = "cohort/SRRT%02d_1.fastq.gz" % i
    put("ak2-data-test", k, d, sha=hashlib.sha256(d).hexdigest()); man.append("s3://ak2-data-test/" + k)
open(os.path.join(B, "..", "manifest.txt"), "w").write("# lever-test inputs\n" + "\n".join(man) + "\n")
bad = []
for i in range(1, 4):
    d = r.randbytes(1000)
    k = "cohort/BAD%02d_1.fastq.gz" % i
    put("ak2-data-test", k, d, sha=hashlib.sha256(d if i != 2 else b"other").hexdigest()); bad.append("s3://ak2-data-test/" + k)
open(os.path.join(B, "..", "manifest-bad.txt"), "w").write("\n".join(bad) + "\n")
PY
need $? "synthetic bucket written"
mkdir -p "$T/bucket/ak2-results-test"
{ cat scripts/preamble.sh; printf '\n'; cat scripts/tests/lever_body.sh; } > "$T/payload.sh"

# run_case CASE WANT_RC: one container; then the run's own records.
run_case() {
  local c=$1 want=$2 rc P D
  rm -f "$T/bucket/.aws-calls.$c" "$T/bucket/.s5-calls.$c"   # per case: a host-side rm may lag inside the VM
  P="aws-kraken2/g9/lever-$c"
  rm -rf "$T/bucket/ak2-results-test/$P" "$T/bucket/ak2-results-test/lvt/$c"
  podman run --rm -v "$ROOT:/repo:ro" -v "$T:/work" -e PATH=/work/bin:/usr/local/bin:/usr/bin:/bin \
    -e AK2_EXPECT_REGION=us-west-2 -e AK2_BUCKETS="ak2-roda-test ak2-data-test" \
    -e AK2_ALLOWED_BUCKETS="ak2-roda-test ak2-data-test ak2-results-test" -e AK2_S3_PREFIX="s3://ak2-results-test/$P" \
    -e AK2_RUN_ID="lever-$c-$SHA" -e AK2_GATE=g9 -e LVT_CASE="$c" \
    -e AK2_REHEARSE_S5CMD=/work/s5/s5cmd -e AK2_REHEARSE_WHEELS=/opt/wheels -e AK2_REHEARSE_NVME=/tmp/nvme \
    "$IMG" bash -e -c "$(cat "$T/payload.sh")" > "$T/$c.out" 2>&1
  rc=$?
  D="$T/bucket/ak2-results-test/$P"
  [ "$rc" = "$want" ]; need $? "$c: container exit $rc (want $want)"
  [ "$rc" = "$want" ] || tail -30 "$T/$c.out" | sed "s/^/  $c | /"
  if [ -s "$T/out/$c.checks" ]; then
    while IFS=$'\t' read -r st n d; do [ "$st" = ok ]; need $? "$c: $n${d:+ -- $d}"; done < "$T/out/$c.checks"
  else
    need 1 "$c: the body wrote no checks"
  fi
  grep -q 'inherited \$-=[a-zA-Z]*e' "$D/log/run.log" 2> /dev/null; need $? "$c: the payload started under errexit (bash -e -c) and the preamble ran"
  [ "$(grep -c '^lever {' "$D/log/run.log" 2> /dev/null)" -gt 0 ] && [ -s "$D/out/lever.jsonl" ]
  need $? "$c: lever lines streamed into run.log ($(grep -c '^lever {' "$D/log/run.log" 2> /dev/null)) and lever.jsonl pushed ($(wc -l < "$D/out/lever.jsonl" 2> /dev/null) lines)"
  python3 - "$D/out/lever.jsonl" << 'PY'
import json, sys
n = 0
for l in open(sys.argv[1]):
    json.loads(l); n += 1
print(f"lever-test: lever.jsonl: {n} lines, all valid JSON")
PY
  need $? "$c: lever.jsonl is valid JSON lines"
  case $c in
    main) [ ! -s "$D/out/helper-errors.tsv" ]; need $? "main: no helper errors $(head -3 "$D/out/helper-errors.tsv" 2> /dev/null | tr '\n' ';')"
      [ -s "$D/out/lever-uploads.tsv" ] && [ -s "$D/out/lever-db-db-s5-SOURCE" ]; need $? "main: uploads.tsv and the db SOURCE pushed"
      grep -E '^(stage|fetch|upload|s5)' "$D/out/requests.tsv" | awk -F'\t' '{printf "lever-test: requests %s %s %s %s\n", $1, $2, $3, $4}' ;;
    refuse) n=$(grep -c REFUSED "$D/out/helper-errors.tsv" 2> /dev/null); [ "$n" = 9 ]; need $? "refuse: helper-errors.tsv has the 9 refusals ($n)" ;;
    fail) for m in 'does not match ETag' 'lv_fetch_inputs: 2 of 3 verified' 'upload of /tmp/x.bin to s3://ak2-results-test/lvt/fail/up/FAILME-2 failed' 'lv_upload_drain: s5cmd-overlap: 3 of 3 uploaded, 1 failed' "mode 'awscp-crt'" "mode 'rapidgzip-P0'" 'no session' "aws client 'bogus'" 'cannot write /tmp/ak2/lever/upq/END' '!= pinned' 'pip install --require-hashes rapidgzip==0.14.5 failed'; do
        grep -qF "$m" "$D/out/helper-errors.tsv" 2> /dev/null; need $? "fail: helper-errors.tsv: $m"
      done ;;
  esac
}
CASES=${CASES:-main refuse fail}   # CASES="refuse" runs one case (debugging; make lever-test runs all three)
for c in $CASES; do
  case $c in main) run_case main 0 ;; refuse) run_case refuse 126 ;; fail) run_case fail 1 ;; *) need 1 "unknown case $c" ;; esac
done
[ "$CASES" = "main refuse fail" ] || say "WARN: only the cases '$CASES' ran"
[ "$RC" = 0 ] && say "ok ($CASES)" || say "FAILED (KEEP=1 keeps the work dir)"
exit "$RC"
