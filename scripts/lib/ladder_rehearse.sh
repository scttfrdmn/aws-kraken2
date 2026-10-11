#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034,SC2046  # stub bodies are literal; variables read by the checker; container ids split on purpose
# make rehearse-ladder, and make rehearse SPEC=runs/g3-l-<rung>-c1.json (#53; docs/ladder.md,
# "The rehearsal"): the ladder body (scripts/g3/ladder.body.sh, or a committed spec's command[2],
# unmodified) end to end before any ladder rung launches on AWS, checked on observed output only.
#
# Each node is an Amazon Linux 2023 aarch64 container (rootful podman, --privileged: the VM's own
# /proc/sys/vm/drop_caches, real tmpfs mounts with huge=, the real /sys THP knobs), running as
# ec2-user with sudo, exactly what run.sh launches: scripts/preamble.sh followed by the body, as
# `bash -e -c` (spawn's $- has e). Members of a cohort are containers on one podman network, so
# the engine's shards talk TCP to each other's addresses. The committed tree is cloned (a git
# bundle of HEAD) and built on the node: upstream at the pin by scripts/oracle-build.sh (a clone of
# the shared upstream checkout), ours by make build. Stand-ins, only at the edges:
#   - RODA is the viral database (k2_viral_20260626, real): head-object and the copies of
#     opts/taxo/hash.k2d come from it, with a real 16 MiB-part multipart ETag; the engine's ranged
#     GETs go to k2probe serve-file (Range, If-Match) on an infra container;
#   - S3 is one directory on the host (the stand-in bucket): aws and s5cmd are stubs over it (every
#     call logged; uploads under the cohort's out/ can be made slow), and the engine's SDK talks to
#     k2probe fakes3 over the same directory; the staged cohort objects carry Metadata.sha256;
#   - curl answers IMDS (region, AZ, the spec's instance type, the container's own address) and the
#     bucket-region HEAD; sudo answers `dnf install` of packages already in the image with rpm -q;
#   - the samples are real public read sets (200,000 pairs, .cache/reads), named by their run
#     accessions through the body's AK2_REHEARSE_SAMPLES/WEIGHTS seam.
# The viral database, not Standard-8: the podman VM has 8 GiB, and Standard-8's hash.k2d is 8.0 GB,
# so neither a resident table (upstream without -M, ours' engine) nor two shards of it fit.
# The oracle: upstream kraken2 at the pin (scripts/oracle-build.sh, the make oracle build), run on
# the host on the same uncompressed reads; every on-node output sha256 must equal it.
#
# Usage: scripts/lib/ladder_rehearse.sh all                  (make rehearse-ladder)
#        scripts/lib/ladder_rehearse.sh spec runs/<spec>.json (make rehearse SPEC=runs/g3-l-*)
#        scripts/lib/ladder_rehearse.sh tables RECORD_DIR     (ladder_tables.py on spec runs kept with LADREH_RECORD)
#        scripts/lib/ladder_rehearse.sh only GROUP...         (development: arms s5 law1 neg net resolver ttl specs;
#                                                              LADREH_CASES=REGEX narrows the arm cases)
# The cases, their checks and their negative controls: docs/ladder.md, "The rehearsal".
# KEEP=1 keeps the scratch dir; LADREH_RECORD=DIR keeps a spec run's record (for the tables).
# Record: results/rehearse/ladder-<UTC>-<sha7>.log (spec mode: ladder-<rung>-<UTC>-<sha7>.log),
# ending in a summary table, case by case.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
MODE=${1:-all}; [ $# -gt 0 ] && shift
case $MODE in all|spec|only|tables) ;; *) echo "ladder-rehearse: mode $MODE (all | spec SPEC | tables RECORD_DIR | only GROUP...)" >&2; exit 2 ;; esac
# The nodes run the committed tree: the body, lever.sh, the specs and everything they call.
if [ -n "$(git status --porcelain -- scripts cmd internal runs Makefile go.mod go.sum ':!scripts/lib/ladder_rehearse.sh' ':!scripts/lib/ladder_rehearse_check.py')" ]; then
  echo "ladder-rehearse: commit first (the nodes clone HEAD):" >&2
  git status --porcelain -- scripts cmd internal runs Makefile go.mod go.sum >&2; exit 2
fi
SELFDIRTY=$(git status --porcelain -- scripts/lib/ladder_rehearse.sh scripts/lib/ladder_rehearse_check.py)
SHA=$(git rev-parse --short=7 HEAD)
TS=$(date -u +%Y%m%dT%H%M%SZ)
SPEC=""
if [ "$MODE" = spec ]; then
  SPEC=${1:?spec mode needs runs/g3-l-<rung>-c1.json}
  [[ $SPEC =~ ^runs/g3-l-[a-z0-9-]+-c1\.json$ ]] && [ -f "$SPEC" ] || { echo "ladder-rehearse: SPEC $SPEC: want a committed runs/g3-l-<rung>-c1.json" >&2; exit 2; }
fi
if [ "$MODE" = tables ]; then
  TREC=${1:?tables mode needs the record dir (LADREH_RECORD of the spec runs)}
  [ -d "$TREC/results/g3" ] || { echo "ladder-rehearse: $TREC has no results/g3 (run make rehearse SPEC=... with LADREH_RECORD=$TREC first)" >&2; exit 2; }
fi
mkdir -p results/rehearse || exit 1
REC="results/rehearse/ladder-$TS-$SHA.log"
[ "$MODE" = spec ] && REC="results/rehearse/ladder-$(basename "$SPEC" .json | sed 's/^g3-l-//')-$TS-$SHA.log"
exec > >(tee "$REC") 2>&1
say() { echo "ladder-rehearse: $*"; }
say "mode $MODE${SPEC:+ $SPEC} at $SHA (rehearsal scripts $([ -z "$SELFDIRTY" ] && echo committed || echo "DIRTY: a development run")); shell flags $-; record $REC"
say "disk at start: $(df -h ~ | tail -1 | awk '{print $4 " free of " $2}')"

T=$(mktemp -d "$HOME/.ak2-ladreh.XXXXXX") || exit 1   # under $HOME: the podman machine shares it
chmod 0755 "$T"
mkdir -p "$T/cases" || exit 1; chmod 1777 "$T/cases"
NET=""; INFRA=""; PM=(true)
cleanup() {
  "${PM[@]}" rm -f $("${PM[@]}" ps -aq --filter "name=ak2lad-$$-") > /dev/null 2>&1
  [ -n "$NET" ] && "${PM[@]}" network rm -f "$NET" > /dev/null 2>&1
  if [ "${KEEP:-0}" = 1 ]; then say "kept $T"; else chmod -R u+w "$T" 2> /dev/null; rm -rf "$T"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ "$MODE" != tables ]; then   # (tables mode reads a record only: no containers)
# ---- podman: rootful (drop_caches, tmpfs mounts and --privileged need the VM's root) ----
command -v podman > /dev/null || { say "need podman"; exit 1; }
CONN=$(podman system connection list --format '{{.Name}}' 2> /dev/null | grep -- '-root$' | head -1)
[ -n "$CONN" ] || { say "need a rootful podman connection (podman machine set --rootful, or a -root connection)"; exit 1; }
PM=(podman --connection "$CONN")

cat > "$T/Containerfile" << 'EOF'
FROM public.ecr.aws/amazonlinux/amazonlinux:2023
RUN dnf install -y -q git gcc-c++ make zlib-devel perl jq gzip tar findutils python3 util-linux python3-pip sudo diffutils procps-ng shadow-utils bzip2 && dnf clean all
RUN useradd -m -u 1000 ec2-user && echo 'ec2-user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ec2-user && chmod 0440 /etc/sudoers.d/ec2-user
RUN git config --system safe.directory '*'
RUN python3 -m pip download -q --no-deps --only-binary=:all: -d /opt/wheels rapidgzip==0.14.5
RUN curl -fsSL https://go.dev/dl/go1.27.1.linux-arm64.tar.gz | tar -xz -C /usr/local
EOF
IMG=localhost/ak2-ladder-rehearse:$(shasum -a 256 "$T/Containerfile" | cut -c1-12)
if ! "${PM[@]}" image exists "$IMG"; then
  say "building $IMG"
  "${PM[@]}" build -q -t "$IMG" -f "$T/Containerfile" "$T" > /dev/null || { say "could not build $IMG"; exit 1; }
fi
say "image $IMG ($("${PM[@]}" image inspect --format '{{.Id}}' "$IMG" | cut -c1-12)); AL2023 $("${PM[@]}" run --rm "$IMG" uname -m)"

# ---- the database, the oracle, the samples ----
DB="$K2_DB_ROOT/k2_viral_20260626"
[ -s "$DB/hash.k2d" ] || { say "need the viral database at $DB (make stage-db DB=viral)"; exit 1; }
K2DIR=$(scripts/oracle-build.sh) || { say "upstream build at the pin failed"; exit 1; }
RB=kraken2-ncbi-refseq-complete-v205; RP=Kraken2_RefSeqCompleteV205
RESB=aws-kraken2-942542972736-us-west-2
DATAP=aws-kraken2/data
DATASETS="s3://$RB/$RP/hash.k2d s3://$RB/$RP/opts.k2d s3://$RB/$RP/taxo.k2d s3://$RESB/$DATAP/cohort/"
mkdir -p "$T/bin" "$T/s3/$RESB/$DATAP" "$T/calls" "$T/cases" "$T/ref" "$T/reads" "$T/gocache" || exit 1
chmod 1777 "$T/s3" "$T/calls" "$T/cases" "$T/gocache"
# hash.k2d's multipart ETag at 16 MiB parts (RODA's objects are multipart), and a wrong one with
# the same part count (the ETag negative tests).
read -r ETAG BADETAG < <(python3 - "$DB/hash.k2d" << 'PY'
import hashlib, sys
p, ds = 16 << 20, []
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(p), b""):
        ds.append(hashlib.md5(b).digest())
print(f"{hashlib.md5(b''.join(ds)).hexdigest()}-{len(ds)} {hashlib.md5(b'not ' + b''.join(ds)).hexdigest()}-{len(ds)}")
PY
)
say "RODA stand-in: $DB/hash.k2d ($(wc -c < "$DB/hash.k2d" | tr -d ' ') bytes), ETag $ETAG"
SRC=(SRR062634 ERR478965 SRR28305653)
ref() {  # NAME R1.fq R2.fq: upstream at the pin on the uncompressed reads -> $T/ref/NAME.{output,report}.sha256
  local n=$1
  "$K2DIR/kraken2" --db "$DB" --paired --threads 8 --output "$T/ref/$n.output" --report "$T/ref/$n.report" "$2" "$3" \
    > /dev/null 2> "$T/ref/$n.stderr" || { say "oracle failed on $n"; return 1; }
  for r in output report; do shasum -a 256 "$T/ref/$n.$r" | cut -d' ' -f1 > "$T/ref/$n.$r.sha256"; rm -f "$T/ref/$n.$r"; done
  say "oracle $n: $(grep -E 'sequences classified' "$T/ref/$n.stderr" | sed 's/^ *//'); output $(cut -c1-16 "$T/ref/$n.output.sha256") report $(cut -c1-16 "$T/ref/$n.report.sha256")"
}
for s in "${SRC[@]}"; do
  for m in 1 2; do
    # The .fq.gz the nodes read must decompress to the .fq the oracle reads.
    [ "$(gzip -dc "$K2_READS/${s}_200000_$m.fq.gz" | shasum -a 256 | cut -d' ' -f1)" = "$(shasum -a 256 < "$K2_READS/${s}_200000_$m.fq" | cut -d' ' -f1)" ] ||
      { say "$s mate $m: the .fq.gz does not decompress to the .fq"; exit 1; }
  done
  ref "$s" "$K2_READS/${s}_200000_1.fq" "$K2_READS/${s}_200000_2.fq" || exit 1
done
# put PREFIX NAME FILE1 FILE2: a staged sample in the stand-in bucket (a hard link when possible).
put() {
  local d="$T/s3/$RESB/$DATAP/$1"; mkdir -p "$d" || return 1
  ln -f "$3" "$d/$2_1.fastq.gz" 2> /dev/null || cp "$3" "$d/$2_1.fastq.gz" || return 1
  ln -f "$4" "$d/$2_2.fastq.gz" 2> /dev/null || cp "$4" "$d/$2_2.fastq.gz"
}
for s in "${SRC[@]}"; do put cohort "$s" "$K2_READS/${s}_200000_1.fq.gz" "$K2_READS/${s}_200000_2.fq.gz" || exit 1; done
# Variants of real inputs (the oracle's own, scripts/oracle.sh): zeropad, SRR28305653's mate 1 with
# 4096 zero bytes appended; cut, SRR062634's mate 1 cut at half its bytes.
{ cat "$K2_READS/SRR28305653_200000_1.fq.gz"; head -c 4096 /dev/zero; } > "$T/reads/zp_1.fq.gz" || exit 1
head -c $(( $(wc -c < "$K2_READS/SRR062634_200000_1.fq.gz") / 2 )) "$K2_READS/SRR062634_200000_1.fq.gz" > "$T/reads/cut_1.fq.gz" || exit 1
# garbage: ERR478965's mate 1 with a garbage line appended (GNU gzip: "trailing garbage ignored", exit 2).
{ cat "$K2_READS/ERR478965_200000_1.fq.gz"; printf 'trailing garbage\n'; } > "$T/reads/gb_1.fq.gz" || exit 1
WEIGHTS=(200000 200000 200000)

# ---- the committed tree for the nodes: a bundle of HEAD, k2probe for the infra container ----
git bundle create "$T/repo.bundle" HEAD > /dev/null 2>&1 || { say "git bundle failed"; exit 1; }
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o "$T/bin/k2probe-linux" ./cmd/k2probe || { say "k2probe build failed"; exit 1; }
git show HEAD:scripts/preamble.sh > "$T/preamble.sh" && git show HEAD:scripts/g3/ladder.body.sh > "$T/ladder.body.sh" || exit 1

# ---- stand-ins ----
cat > "$T/bin/aws-stub.py" << 'PY'
"""The aws CLI over /work/s3/<bucket>/<key> (RODA's three objects from /db). Every call is a line
of /work/calls/aws-<node>.log. Uploads whose key contains $AK2T_UP_MATCH sleep $AK2T_UP_SLEEP s."""
import hashlib, json, os, shutil, sys, time
a = sys.argv[1:]
with open(f"/work/calls/aws-{os.environ.get('AK2T_NODE', 'x')}.log", "a") as lg:
    lg.write(f"{time.time():.3f}\t{' '.join(a)}\n")
RB, RP, S3 = os.environ["AK2T_RODA_BUCKET"], os.environ["AK2T_RODA_PREFIX"], "/work/s3"
FLAGS = {"--no-sign-request", "--only-show-errors", "--recursive", "--no-progress"}
pos, opt, i = [], {}, 0
while i < len(a):
    if a[i] in FLAGS:
        opt[a[i]] = True; i += 1
    elif a[i].startswith("--"):
        opt[a[i]] = a[i + 1] if i + 1 < len(a) else ""; i += 2
    else:
        pos.append(a[i]); i += 1
def path(b, k):
    if b == RB and k.startswith(RP + "/") and k[len(RP) + 1:] in ("hash.k2d", "opts.k2d", "taxo.k2d"):
        return os.path.join("/db", k[len(RP) + 1:])
    return os.path.join(S3, b, k)
def split(u):
    b, _, k = u[len("s3://"):].partition("/")
    return b, k
def digest(p, alg):
    h = hashlib.new(alg)
    with open(p, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()
if a[:1] == ["--version"]:
    print("aws-cli/2.0.0-rehearsal-stub Python/3 Linux"); sys.exit(0)
if pos[:1] == ["configure"]:
    sys.exit(1)   # nothing configured, as on the AMI
if pos[:2] == ["s3", "cp"] and len(pos) == 4:
    src, dst = pos[2], pos[3]
    if src.startswith("s3://") and not dst.startswith("s3://"):
        p = path(*split(src))
        if not os.path.isfile(p):
            print(f"fatal error: An error occurred (404) when calling the HeadObject operation: Key \"{split(src)[1]}\" does not exist", file=sys.stderr); sys.exit(1)
        if os.path.isdir(dst):
            dst = os.path.join(dst, os.path.basename(p))
        shutil.copyfile(p, dst); sys.exit(0)
    if dst.startswith("s3://") and not src.startswith("s3://"):
        b, k = split(dst)
        m = os.environ.get("AK2T_UP_MATCH")
        if m and m in k:
            time.sleep(float(os.environ.get("AK2T_UP_SLEEP", "0")))
        p = os.path.join(S3, b, k)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        shutil.copyfile(src, p + ".tmp-stub"); os.replace(p + ".tmp-stub", p)
        if os.environ.get("AK2T_KEEP_VERSIONS") and k.endswith("log/run.log"):
            v = os.path.join(S3, ".v", b, k + f".{time.time_ns()}")
            os.makedirs(os.path.dirname(v), exist_ok=True); shutil.copyfile(src, v)
        sys.exit(0)
    sys.exit(f"rehearsal aws stub: unsupported cp {src} {dst}")
if pos[:2] == ["s3", "ls"]:
    sys.exit(0)
if pos[:2] == ["s3api", "get-bucket-request-payment"]:
    print("BucketOwner" if opt.get("--query") == "Payer" else json.dumps({"Payer": "BucketOwner"})); sys.exit(0)
if pos[:2] == ["s3api", "head-object"]:
    b, k = opt.get("--bucket"), opt.get("--key")
    p = path(b, k)
    if not os.path.isfile(p):
        print("An error occurred (404) when calling the HeadObject operation: Not Found", file=sys.stderr); sys.exit(254)
    n = os.path.getsize(p)
    if p == "/db/hash.k2d":
        etag, meta = os.environ["AK2T_HASH_ETAG"], {}
    else:
        etag = digest(p, "md5")
        meta = {"sha256": digest(p, "sha256")} if "/cohort" in k else {}
    q = opt.get("--query")
    if q == "[ETag,ContentLength]":
        print(f'"{etag}"\t{n}')
    elif q == "Metadata.sha256":
        print(meta.get("sha256", "None"))
    elif q == "ETag":
        print(f'"{etag}"')
    elif q == "ContentLength":
        print(n)
    else:
        print(json.dumps({"ETag": f'"{etag}"', "ContentLength": n, "Metadata": meta}))
    sys.exit(0)
sys.exit(f"rehearsal aws stub: unsupported: {' '.join(a)}")
PY
printf '#!/bin/bash\nexec python3 -I /work/bin/aws-stub.py "$@"\n' > "$T/bin/aws"
cat > "$T/bin/s5cmd" << 'EOF'
#!/bin/bash
# s5cmd over /work/s3 (RODA's objects from /db): cp both ways; every call a line of /work/calls/s5-<node>.log.
[ "${1:-}" = version ] && { echo "v2.3.0-rehearsal-stub"; exit 0; }
printf '%s\t%s\n' "$(date +%s.%3N)" "$*" >> "/work/calls/s5-${AK2T_NODE:-x}.log"
a=("$@"); i=0
while [[ ${a[$i]:-} == -* ]]; do case ${a[$i]} in --numworkers|-numworkers|--log|-log|-r|--retry-count) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac; done
sub=${a[$i]:-}; i=$((i + 1)); pos=()
while [ "$i" -lt "${#a[@]}" ]; do
  case ${a[$i]} in --concurrency|--part-size|-c|-p) i=$((i + 2)); continue ;; -*) ;; *) pos+=("${a[$i]}") ;; esac
  i=$((i + 1))
done
p() { local u=${1#s3://} b k; b=${u%%/*}; k=${u#*/}
  if [ "$b" = "$AK2T_RODA_BUCKET" ] && [ "${k%/*}" = "$AK2T_RODA_PREFIX" ]; then echo "/db/${k##*/}"; else echo "/work/s3/$b/$k"; fi; }
[ "$sub" = cp ] && [ "${#pos[@]}" = 2 ] || { echo "rehearsal s5cmd: unsupported: $*" >&2; exit 1; }
s=${pos[0]} d=${pos[1]}
if [[ $s == s3://* ]]; then
  f=$(p "$s"); [ -f "$f" ] || { echo "ERROR \"cp $s $d\": NoSuchKey" >&2; exit 1; }
  [ -d "$d" ] && d="$d/${f##*/}"; cp "$f" "$d"
else
  f=$(p "$d")
  [ -n "${AK2T_UP_MATCH:-}" ] && [[ $d == *"$AK2T_UP_MATCH"* ]] && sleep "${AK2T_UP_SLEEP:-0}"
  mkdir -p "$(dirname "$f")" && cp "$s" "$f.tmp-stub" && mv -f "$f.tmp-stub" "$f"
fi
EOF
cat > "$T/bin/curl" << 'EOF'
#!/bin/bash
# IMDS and the bucket-region HEAD; anything else goes to the real curl.
url=""; for x in "$@"; do case $x in http*) url=$x ;; esac; done
case $url in
  *169.254.169.254*/api/token) echo rehearsal-token ;;
  *meta-data/placement/region) echo us-west-2 ;;
  *meta-data/placement/availability-zone) echo us-west-2b ;;
  *meta-data/instance-id) echo "i-rehearsal-$AK2T_NODE" ;;
  *meta-data/instance-type) echo "$AK2T_TYPE" ;;
  *meta-data/ami-id) echo ami-rehearsal ;;
  *meta-data/local-ipv4) echo "$AK2T_IP" ;;
  https://*.s3.*amazonaws.com/) printf 'HTTP/1.1 200 OK\r\nx-amz-bucket-region: us-west-2\r\n\r\n' ;;
  *169.254.169.254*) exit 22 ;;
  *) exec /usr/bin/curl "$@" ;;
esac
EOF
cat > "$T/bin/git" << 'EOF'
#!/bin/bash
# clone: the committed tree (a bundle of HEAD; then the case's tree mutation, if any) and the
# shared upstream checkout; nothing else is cloned.
if [ "${1:-}" = clone ]; then
  dst=${*: -1}; src=${*: -2:1}
  case $src in
    https://github.com/scttfrdmn/aws-kraken2.git)
      /usr/bin/git clone -q /work/repo.bundle "$dst" || exit 1
      if [ -n "${AK2T_MUTATE:-}" ]; then bash "$AK2T_MUTATE" "$dst" || { echo "rehearsal: tree mutation $AK2T_MUTATE failed" >&2; exit 1; }; fi
      exit 0 ;;
    https://github.com/DerrickWood/kraken2.git) exec /usr/bin/git clone -q /upstream-src "$dst" ;;
    *) echo "rehearsal git: no clone of $src" >&2; exit 1 ;;
  esac
fi
exec /usr/bin/git "$@"
EOF
cat > "$T/bin/sudo" << 'EOF'
#!/bin/bash
# `dnf install` of packages already in the image: answered by rpm -q; everything else: real sudo.
if [ "${1:-}" = -n ] && [ "${2:-}" = dnf ] && [ "${3:-}" = install ]; then
  pk=(); for x in "${@:4}"; do case $x in -*) ;; *) pk+=("$x") ;; esac; done
  rpm -q "${pk[@]}" > /dev/null && exit 0
fi
exec /usr/bin/sudo "$@"
EOF
chmod 0755 "$T/bin"/*

# ---- the network and the infra container (serve-file x 2, fakes3) ----
for o in $(seq 101 140); do
  NETP=10.$((RANDOM % 50 + 150)).$o
  "${PM[@]}" network create --subnet "$NETP.0/24" "ak2lad-$$" > /dev/null 2>&1 && { NET=ak2lad-$$; break; }
done
[ -n "$NET" ] || { say "could not create a podman network"; exit 1; }
INFRA=$NETP.2
"${PM[@]}" run -d --rm --name "ak2lad-$$-infra" --network "$NET" --ip "$INFRA" -v "$T:/work" -v "$DB:/db:ro" "$IMG" bash -c "
  /work/bin/k2probe-linux serve-file -file /db/hash.k2d -path /$RP/hash.k2d -etag $ETAG -addr 0.0.0.0:8001 &
  /work/bin/k2probe-linux serve-file -file /db/hash.k2d -path /$RP/hash.k2d -etag $BADETAG -addr 0.0.0.0:8002 &
  /work/bin/k2probe-linux fakes3 -dir /work/s3 -addr 0.0.0.0:8003 &
  wait" > /dev/null || { say "infra container did not start"; exit 1; }
for _ in $(seq 50); do
  "${PM[@]}" exec "ak2lad-$$-infra" bash -c "/usr/bin/curl -sf -o /dev/null -r 0-0 http://127.0.0.1:8001/$RP/hash.k2d && /usr/bin/curl -s -o /dev/null http://127.0.0.1:8003/" && break
  sleep 0.2
done
HASHURL=http://$INFRA:8001/$RP/hash.k2d; BADURL=http://$INFRA:8002/$RP/hash.k2d; S3EP=http://$INFRA:8003
say "network $NET ($NETP.0/24); infra $INFRA: hash.k2d at $HASHURL (and a wrong ETag at :8002), fakes3 at $S3EP"
fi

# ---- one cohort ----
NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# body_arm OUT PARAMS: the committed body with its @PARAMS@ line replaced, as the generator does.
body_arm() { awk -v p="$2" '$0 == "@PARAMS@" {print p; n++; next} {print} END {exit n != 1}' "$T/ladder.body.sh" > "$1"; }
# payload OUT BODY: the preamble, one rehearsal line (pipefail's state, the only addition), the body.
payload() {
  { cat "$T/preamble.sh"; printf '\n'; printf '%s\n' "ak2_say \"rehearsal: pipefail \$(set -o | awk '\$1 == \"pipefail\" {print \$2}')\""; cat "$2"; } > "$1"
}
# mutate FILE OLD NEW: one exact replacement (a negative control's planted defect); fails unless OLD occurs once.
mutate() {
  python3 -c 'import sys; p, a, b = sys.argv[1:4]; s = open(p).read(); n = s.count(a)
if n != 1: sys.exit("mutate: %d occurrences in %s of %r" % (n, p, a))
open(p, "w").write(s.replace(a, b))' "$1" "$2" "$3"
}
# launch CASE PAYLOAD WANT_N TYPE COHORT DATA_PREFIX "SAMPLES" "WEIGHTS" [KEY=VALUE...]: the cohort's
# nodes at once, failing fast as run-multi.sh does. Sets CID, CD.
launch() {
  local case=$1 pl=$2 n=$3 type=$4 coh=$5 dp=$6 sam=$7 wts=$8 k pid
  shift 8
  CD="$T/cases/$case"; mkdir -p "$CD"; chmod 1777 "$CD"
  CID="$(date -u +%Y%m%d-%H%M%S)-$SHA-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')-n$n"; echo "$CID" > "$CD/cid"
  local pre="s3://$RESB/aws-kraken2/g3/$CID" ds="${DATASETS% *} s3://$RESB/$DATAP/$dp/"
  local -a pids=() extra=() rcs=()
  for kv in "$@"; do extra+=(-e "$kv"); done
  for ((k = 0; k < n; k++)); do
    date -u +%Y-%m-%dT%H:%M:%SZ > "$CD/r$k.start"
    "${PM[@]}" run --rm --privileged --name "ak2lad-$$-$case-r$k" --network "$NET" --ip "$NETP.$((10 + k))" --user ec2-user \
      --tmpfs /mnt/nvme-rehearse:rw,size=6g,mode=1777 --tmpfs /home/ec2-user:rw,size=4g,mode=1777 \
      --tmpfs /tmp:rw,size=2g,mode=1777 -v "$T:/work" -v "$DB:/db:ro" -v "$ORACLE_SRC:/upstream-src:ro" \
      -v "$(go env GOMODCACHE):/gomod:ro" \
      -e PATH=/work/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin -e GOFLAGS=-mod=mod -e GOPROXY=off -e GOTOOLCHAIN=local \
      -e GOMODCACHE=/gomod -e GOCACHE=/work/gocache \
      -e AK2_EXPECT_REGION=us-west-2 -e AK2_BUCKETS="$RB $RESB" -e AK2_ALLOWED_BUCKETS="$RB $RESB" \
      -e AK2_S3_PREFIX="$pre-r$k" -e AK2_RUN_ID="$CID-r$k" -e AK2_GATE=g3 -e AK2_COHORT_ID="$CID" -e AK2_COHORT_PREFIX="$pre" \
      -e AK2_ENGINE_N="$n" -e AK2_ENGINE_RANK="$k" -e AK2_ENGINE_RENDEZVOUS="$pre/rendezvous" \
      -e AK2_REGION=us-west-2 -e AK2_ACCESSIONS="@PRJNA398089:1-$coh" -e AK2_DATASETS="$ds" \
      -e AK2_REHEARSE_NVME=/mnt/nvme-rehearse -e AK2_REHEARSE_S5CMD=/work/bin/s5cmd -e AK2_REHEARSE_WHEELS=/opt/wheels \
      -e AK2_REHEARSE_GO=1 -e AK2_REHEARSE_HASH_URL="$HASHURL" -e AK2_REHEARSE_SAMPLES="$sam" -e AK2_REHEARSE_WEIGHTS="$wts" \
      -e AK2_S3_ENDPOINT="$S3EP" \
      -e AK2T_NODE="$case-r$k" -e AK2T_IP="$NETP.$((10 + k))" -e AK2T_TYPE="$type" -e AK2T_HASH_ETAG="$ETAG" \
      -e AK2T_RODA_BUCKET="$RB" -e AK2T_RODA_PREFIX="$RP" "${extra[@]}" \
      "$IMG" bash -e -c "$(cat "$pl")" > "$CD/r$k.out" 2>&1 &
    pids+=($!)
  done
  local left=$n failed=""
  while [ "$left" -gt 0 ]; do
    for k in "${!pids[@]}"; do
      [ -n "${rcs[$k]:-}" ] && continue
      kill -0 "${pids[$k]}" 2> /dev/null && continue
      wait "${pids[$k]}"; rcs[$k]=$?; left=$((left - 1)); NOW > "$CD/r$k.end"; echo "${rcs[$k]}" > "$CD/r$k.rc"
      if [ "${rcs[$k]}" != 0 ] && [ -z "$failed" ] && [ "$left" -gt 0 ]; then
        failed=$k; say "$case: rank $k exited ${rcs[$k]}: stopping the others (fail fast, as run-multi.sh)"
        for j in "${!pids[@]}"; do [ -z "${rcs[$j]:-}" ] && "${PM[@]}" kill "ak2lad-$$-$case-r$j" > /dev/null 2>&1; done
      fi
    done
    [ "$left" -gt 0 ] && sleep 1
  done
  say "$case: cohort $CID: node exits ${rcs[*]}"
}
# casejson CASE RUNG PARAMS "SAMPLES" TYPE EXPECT_JSON [REFMAP_JSON]: the checker's input for the last launch.
casejson() {
  local nodes='[]' k
  for f in "$CD"/r*.rc; do
    k=$(basename "$f" .rc); k=${k#r}
    nodes=$(jq -c --argjson k "$k" --arg out "$CD/r$k.out" --argjson rc "$(cat "$f")" --arg s "$(cat "$CD/r$k.start")" --arg e "$(cat "$CD/r$k.end")" \
      '. + [{rank:$k, out:$out, rc:$rc, start:$s, end:$e}]' <<< "$nodes")
  done
  jq -n --arg name "$1" --arg rung "$2" --arg cid "$CID" --arg b "$T/s3/$RESB/aws-kraken2/g3" --argjson nodes "$nodes" \
    --arg sam "$4" --arg refdir "$T/ref" --arg params "$3" --arg type "$5" --argjson ex "$6" --argjson refmap "${7:-{\}}" '
    {name:$name, rung:$rung, cid:$cid, bucket:$b, nodes:($nodes | sort_by(.rank)), samples:($sam | split(" ")), refdir:$refdir,
     refmap:$refmap, type:$type, expect:$ex,
     params:($params | split("; ") | map(split("=") | {key:.[0], value:(.[1:] | join("="))}) | from_entries)}' > "$CD/case.json"
}
declare -a SUMMARY=()
NFAIL=0
# verdict CASE ITEM WHAT RC: one summary row.
verdict() {
  local nok nf
  nok=$(grep -c "^ok   $1: " "$T/cases/$1/check.txt" 2> /dev/null); nf=$(grep -c "^FAIL $1: " "$T/cases/$1/check.txt" 2> /dev/null)
  SUMMARY+=("$(printf '%-4s | %-26s | %-58s | %3s ok | %3s FAIL | %s' "$2" "$1" "$3" "${nok:-0}" "${nf:-0}" "$([ "$4" = 0 ] && echo PASS || echo FAIL)")")
  [ "$4" = 0 ] || NFAIL=$((NFAIL + 1))
  say "disk: $(df -h ~ | tail -1 | awk '{print $4}') free"
}
# runcheck CASE [--expect-fail IDS]: the checker on the last launch; prints and records its lines.
runcheck() {
  local c=$1; shift
  python3 scripts/lib/ladder_rehearse_check.py check "$T/cases/$c/case.json" "$@" > "$T/cases/$c/check.txt" 2>&1
  local rc=$?
  cat "$T/cases/$c/check.txt"
  if [ "$rc" != 0 ]; then for f in "$T/cases/$c"/r*.out; do say "$c: tail of $(basename "$f")"; tail -25 "$f" | sed 's/^/    | /'; done; fi
  return "$rc"
}
# drop the case's uploaded outputs once checked (the logs and records stay until cleanup).
tidy() { rm -rf "$T/s3/$RESB/aws-kraken2/g3/$CID/out"; rm -f "$T/cases/$1"/payload.sh; }

# Payload mutations (negative controls): each plants one defect in a copy of the body.
mut_nofallback() { mutate "$1" '    [ "$ok" = true ] || S5BAD[$s]=1' '    :'; }
mut_net() { mutate "$1" '(($id|tonumber) + ($sg|tonumber) + ($sc|tonumber))' '(($sg|tonumber) + ($sc|tonumber))'; }
mut_law1() { mutate "$1" '--paired --threads "$T" --output' '--paired --minimum-hit-groups 3 --threads "$T" --output'; }
mut_noline() { mutate "$1" '2> >(tee "$W/eng.stderr" |' '2> >(grep --line-buffered -v $'"'"'\tname\tERR478965\t'"'"' | tee "$W/eng.stderr" |'; }
mut_nb1() { mutate "$1" '    if [ -n "${LV_UP_TSV:-}" ] && [ -f "$LV_UP_TSV" ]; then' '    if false; then'; }
# Tree mutations (AK2T_MUTATE, run by the git stub on the fresh clone): pyfix NAME FILE OLD NEW,
# OLD and NEW as python string literals; the script fails unless OLD occurs exactly once.
pyfix() {
  { printf '%s\n' '#!/bin/bash' "python3 - \"\$1/$2\" << 'PY'" 'import sys'
    printf 'p, a, b = sys.argv[1], %s, %s\n' "$3" "$4"
    printf '%s\n' 's = open(p).read()' 'assert s.count(a) == 1, "%s: %d occurrences" % (p, s.count(a))' 'open(p, "w").write(s.replace(a, b))' 'PY'
  } > "$T/cases/$1.sh"
}

# ---- the parameter sets ----
P_BASE="CLASSIFIER=upstream; THREADS=vcpus; PROCS=1; DB_STAGE=s5cmd; DB_PLACE=tmpfs-huge; DB_LOAD=mmap; HOST_TUNES=none; GUNZIP=gzip; IN_FETCH=lanes16; IN_CLIENT=default; IN_DEST=tmpfs; OUT_UPLOAD=s5cmd-serial; REPLICAS=1; SHARDS=1; PLACEMENT=mod; INFLIGHT=-; SETUP=serial; ETAG_CHECK=on"
# pset BASE KEY=VALUE...: BASE with values replaced.
pset() {
  local s=$1; shift
  awk -v s="$s" 'BEGIN { n = split(s, a, "; "); for (i = 2; i < ARGC; i++) { k = ARGV[i]; sub(/=.*/, "", k); for (j = 1; j <= n; j++) if (index(a[j], k "=") == 1) a[j] = ARGV[i] }
    o = a[1]; for (j = 2; j <= n; j++) o = o "; " a[j]; print o }' - "$@"
}
hdr() { echo "RUNG=$1; ARM=$2; COHORT=$3; WANT_N=$4; $5"; }
ALL3="${SRC[*]}"; W3="${WEIGHTS[*]}"

# arm CASE ITEM WHAT RUNG ARM WANT_N TYPE PARAMS EXPECT [DATA SAMPLES WEIGHTS REFMAP] [-- KEY=VALUE...]
arm() {
  local c=$1 item=$2 what=$3 rung=$4 armv=$5 wn=$6 type=$7 ps=$8 ex=$9; shift 9
  if [ -n "${LADREH_CASES:-}" ] && ! [[ $c =~ $LADREH_CASES ]]; then return 0; fi   # development: a subset
  local dp=cohort sam=$ALL3 wts=$W3 refmap='{}'
  if [ $# -gt 0 ] && [ "$1" != -- ]; then dp=$1 sam=$2 wts=$3 refmap=$4; shift 4; fi
  [ "${1:-}" = -- ] && shift
  local coh; coh=$(wc -w <<< "$sam" | tr -d ' ')
  local line; line=$(hdr "$rung" "$armv" "$coh" "$wn" "$ps")
  mkdir -p "$T/cases/$c"
  body_arm "$T/cases/$c/body.sh" "$line" || { say "$c: no @PARAMS@ in the body"; return 1; }
  [ -n "${MUTF:-}" ] && { "$MUTF" "$T/cases/$c/body.sh" || { say "$c: payload mutation $MUTF did not apply"; verdict "$c" "$item" "$what" 1; return 1; }; }
  payload "$T/cases/$c/payload.sh" "$T/cases/$c/body.sh"
  say "---- $c ($item): $what"
  say "$c: $line"
  launch "$c" "$T/cases/$c/payload.sh" "$wn" "$type" "$coh" "$dp" "$sam" "$wts" "$@"
  casejson "$c" "$rung" "$line" "$sam" "$type" "$ex" "$refmap"
  runcheck "$c" ${EXPECTFAIL:+--expect-fail "$EXPECTFAIL"}
  local rc=$?
  # POST: a case's own further checks on the same run (their lines join its check.txt).
  if [ -n "${POST:-}" ]; then "$POST" "$c" | tee -a "$T/cases/$c/check.txt"; [ "${PIPESTATUS[0]}" = 0 ] || rc=1; fi
  verdict "$c" "$item" "$what" "$rc"
  [ "${KEEPOUT:-0}" = 1 ] || tidy "$c"
  return "$rc"
}

# ---- cases ----
EX_OK='{"exit":"ok","pipefail_off":true}'
ex() { jq -c ". + $1" <<< "$EX_OK"; }
# Every committed c1 spec, as make rehearse SPEC= runs it.
spec_case() {   # SPEC [SUFFIX]; MUTF and EXPECTFAIL as for arm (a negative control of the tables)
  local spec=$1 c rung type line wn ex
  c=spec-$(basename "$spec" .json | sed 's/^g3-l-//; s/-c1$//')${2:+-$2}
  rung=$(git show "HEAD:$spec" | jq -r '.command[2]' | sed -n 's/^RUNG=\([^;]*\);.*/\1/p' | head -1)
  line=$(git show "HEAD:$spec" | jq -r '.command[2]' | grep -m1 '^RUNG=')
  type=$(git show "HEAD:$spec" | jq -r .resources.instance_type)
  wn=$(sed -n 's/.*WANT_N=\([0-9]*\);.*/\1/p' <<< "$line")
  mkdir -p "$T/cases/$c"
  git show "HEAD:$spec" | jq -r '.command[2]' > "$T/cases/$c/body.sh"
  # The spec's body is the committed body with its parameter block (the generator's only change).
  local same
  same=$(diff <(grep -v '^RUNG=\|^# TTL \|^# Parameters (scripts/g3/mkspec-ladder.sh' "$T/cases/$c/body.sh") <(grep -v '^@PARAMS@$' "$T/ladder.body.sh") > /dev/null && echo yes || echo no)
  if [ -n "${MUTF:-}" ]; then "$MUTF" "$T/cases/$c/body.sh" || { say "$c: mutation $MUTF did not apply"; verdict "$c" 6 "$spec, mutated" 1; return 1; }; fi
  payload "$T/cases/$c/payload.sh" "$T/cases/$c/body.sh"
  say "---- $c (6): $spec ($type, WANT_N $wn); its body is the committed body plus its parameters: $same"
  say "$c: $spec sha256 $(git show "HEAD:$spec" | shasum -a 256 | cut -d' ' -f1) (HEAD $SHA)"
  say "$c: $line"
  ex=$EX_OK; [[ $line == *GUNZIP=rapidgzip* ]] && ex=$(ex '{"s5":{}}')
  launch "$c" "$T/cases/$c/payload.sh" "$wn" "$type" 1 cohort "${SRC[0]}" "${WEIGHTS[0]}"
  casejson "$c" "$rung" "$line" "${SRC[0]}" "$type" "$ex"
  runcheck "$c" ${EXPECTFAIL:+--expect-fail "$EXPECTFAIL"}; local rc=$?
  [ "$same" = yes ] || { echo "FAIL $c: body: the spec's body is not the committed body plus its parameters" >> "$T/cases/$c/check.txt"; rc=1; }
  [ "$same" = yes ] && echo "ok   $c: body: the spec's body is the committed body plus its parameter block" >> "$T/cases/$c/check.txt"
  if [ -n "${LADREH_RECORD:-}" ]; then python3 scripts/lib/ladder_rehearse_check.py record "$CD/case.json" "$LADREH_RECORD" "$spec" || rc=1; fi
  verdict "$c" 6 "$spec end to end${MUTF:+ ($MUTF: a negative control)}" "$rc"
  tidy "$c"
  return "$rc"
}

case_arms() {
  # (1) upstream per-sample: serial and overlap uploads, 1 and 2 lanes; uploads to out/ take 2 s.
  local slow=(AK2T_UP_SLEEP=2)
  arm u-serial-1lane 1 "upstream, s5cmd-serial, 1 lane, 3 samples" S7a S 1 x8g.24xlarge "$P_BASE" "$(ex '{"order":"serial"}')" \
    -- "${slow[@]}" AK2T_UP_MATCH=/out/S7a/
  arm u-overlap-1lane 1 "upstream, s5cmd-overlap, 1 lane" S7b S 1 x8g.24xlarge "$(pset "$P_BASE" OUT_UPLOAD=s5cmd-overlap)" "$(ex '{"order":"overlap"}')" \
    -- "${slow[@]}" AK2T_UP_MATCH=/out/S7b/
  arm u-serial-2lanes 1 "upstream, awscp-default (stock), 2 lanes, NVMe, load" S0-Tv S 1 r8gd.48xlarge \
    "$(pset "$P_BASE" THREADS=vcpus/2 PROCS=2 DB_STAGE=awscp-default DB_PLACE=nvme DB_LOAD=load IN_FETCH=serial IN_DEST=nvme OUT_UPLOAD=awscp-default)" \
    "$(ex '{"order":"serial","lanes":2}')" -- "${slow[@]}" AK2T_UP_MATCH=/out/S0-Tv/
  arm u-overlap-2lanes 1 "upstream, s5cmd-overlap, 2 lanes, rapidgzip-Pauto, SETUP=overlap" S9 S 1 x8g.24xlarge \
    "$(pset "$P_BASE" THREADS=vcpus/2 PROCS=2 GUNZIP=rapidgzip-Pauto OUT_UPLOAD=s5cmd-overlap SETUP=overlap)" \
    "$(ex '{"order":"overlap","lanes":2,"s5":{}}')" -- "${slow[@]}" AK2T_UP_MATCH=/out/S9/
  # ours' plain path (O0: S*'s levers with ours), and the engine.
  arm ours-plain 1 "ours-plain (O0), AK2_DECOMPRESS=pipe under rapidgzip" O0 O 1 x8g.24xlarge \
    "$(pset "$P_BASE" CLASSIFIER=ours-plain GUNZIP=rapidgzip-Pauto OUT_UPLOAD=s5cmd-overlap SETUP=overlap)" "$(ex '{"s5":{}}')"
  local PE; PE=$(pset "$P_BASE" CLASSIFIER=ours-engine DB_STAGE=ranged-get DB_PLACE=memory DB_LOAD=resident INFLIGHT=1 OUT_UPLOAD=s5cmd-overlap)
  arm engine-k2 1 "the engine, K=2 replicas of N=1" O1 O 2 x8g.24xlarge "$(pset "$PE" REPLICAS=2)" "$EX_OK"
  arm engine-n2 1 "the engine, N=2 shards over TCP (lpt)" O3 O 2 x8g.24xlarge "$(pset "$PE" SHARDS=2 PLACEMENT=lpt GUNZIP=rapidgzip-Pauto)" "$(ex '{"s5":{}}')"
  arm o5-sdk 1 "O5: the engine's sdk-stream emitter at N=2, sha256 by GET" O5 O 2 x8g.24xlarge \
    "$(pset "$PE" SHARDS=2 INFLIGHT=2 OUT_UPLOAD=sdk-stream)" "$(ex '{"sdk":true}')"
}

case_s5() {
  # (2) real rapidgzip 0.14.5 on an input with trailing bytes (4096 zero bytes after mate 1's
  # member, the oracle's zeropad variant: GNU gzip ignores them) and on a corrupt input (mate 1
  # cut at half its bytes: GNU gzip fails).
  put cohort-s5 SRR062634 "$K2_READS/SRR062634_200000_1.fq.gz" "$K2_READS/SRR062634_200000_2.fq.gz"
  put cohort-s5 ERR478965 "$K2_READS/ERR478965_200000_1.fq.gz" "$K2_READS/ERR478965_200000_2.fq.gz"
  put cohort-s5 SRR28305653 "$T/reads/zp_1.fq.gz" "$K2_READS/SRR28305653_200000_2.fq.gz"
  put cohort-garbage SRR062634 "$K2_READS/SRR062634_200000_1.fq.gz" "$K2_READS/SRR062634_200000_2.fq.gz"
  put cohort-garbage ERR478965 "$T/reads/gb_1.fq.gz" "$K2_READS/ERR478965_200000_2.fq.gz"
  put cohort-garbage SRR28305653 "$K2_READS/SRR28305653_200000_1.fq.gz" "$K2_READS/SRR28305653_200000_2.fq.gz"
  put cohort-corrupt SRR062634 "$T/reads/cut_1.fq.gz" "$K2_READS/SRR062634_200000_2.fq.gz"
  put cohort-corrupt ERR478965 "$K2_READS/ERR478965_200000_1.fq.gz" "$K2_READS/ERR478965_200000_2.fq.gz"
  local P5; P5=$(pset "$P_BASE" GUNZIP=rapidgzip-Pauto)
  # The tools' real exits and sha256, from an independent run of each on the same file at the
  # same -P (P resolves to clamp(floor(8 / 2), 1, 16) = 4 on this 8-CPU VM).
  local ind
  ind=$("${PM[@]}" run --rm -v "$T:/work" "$IMG" bash -c '
    set +e; python3 -m venv /tmp/v > /dev/null && /tmp/v/bin/pip install -q --no-index --find-links /opt/wheels rapidgzip==0.14.5 > /dev/null || exit 1
    d=/work/s3/'"$RESB/$DATAP"'
    for f in cohort-s5/SRR28305653_1.fastq.gz cohort-s5/SRR062634_1.fastq.gz cohort-corrupt/SRR062634_1.fastq.gz cohort-garbage/ERR478965_1.fastq.gz; do
      g=$(gzip -dc "$d/$f" 2> /dev/null | sha256sum | cut -c1-64; exit "${PIPESTATUS[0]}"); gr=$?
      h=$(/tmp/v/bin/rapidgzip -d -c -P 4 "$d/$f" 2> /dev/null | sha256sum | cut -c1-64; exit "${PIPESTATUS[0]}"); hr=$?
      printf "%s %s %s %s %s\n" "$f" "$gr" "$hr" "$h" "$g"
    done')
  say "independent tool runs (file gzip_exit rapidgzip_exit rapidgzip_sha256 gzip_sha256):"; echo "$ind" | sed 's/^/    /'
  local -a zp cut
  local -a gb
  read -r -a zp <<< "$(sed -n 1p <<< "$ind")"; read -r -a cut <<< "$(sed -n 3p <<< "$ind")"; read -r -a gb <<< "$(sed -n 4p <<< "$ind")"
  [ "${zp[4]}" != "${zp[3]}" ] || say "WARNING: rapidgzip 0.14.5 kept every byte of the zero-padded input at -P 4 (the probe cannot resolve the fallback)"
  local exs
  exs=$(jq -nc --argjson zg "${zp[1]}" --argjson zr "${zp[2]}" --arg zh "${zp[3]}" '{exit:"ok", pipefail_off:true,
    s5:{differs:["SRR28305653"], defect:[], independent:{"SRR28305653_1.fastq.gz":[$zg, $zr, $zh]}}}')
  arm s5-trailing 2 "S5: real rapidgzip; SRR28305653 mate 1 has 4096 trailing zero bytes" S5 S 1 x8g.24xlarge "$P5" "$exs" \
    cohort-s5 "$ALL3" "$W3" '{}'
  # A garbage tail: GNU gzip warns (exit 2) with its output complete, so the input is kept (no
  # input_defect; gz_warning recorded); rapidgzip differs, so the sample falls back to GNU gzip.
  local exg
  exg=$(jq -nc --argjson g "${gb[1]}" --argjson r "${gb[2]}" --arg h "${gb[3]}" '{exit:"ok", pipefail_off:true,
    s5:{differs:["ERR478965"], defect:[], warning:["ERR478965_1.fastq.gz"], independent:{"ERR478965_1.fastq.gz":[$g, $r, $h]}}}')
  [ "${gb[1]}" = 2 ] || say "WARNING: GNU gzip exits ${gb[1]} on the garbage tail, not 2 (the probe cannot resolve gz_warning)"
  arm s5-garbage 2 "S5: ERR478965 mate 1 with a garbage tail (gzip exit 2: a warning)" S5 S 1 x8g.24xlarge "$P5" "$exg" \
    cohort-garbage "$ALL3" "$W3" '{}'
  # Negative control: no sample marked as differing (the fallback never installed); the zero-padded
  # sample is then classified from rapidgzip's short stream, so S5's check and Law 1 must fail.
  MUTF=mut_nofallback EXPECTFAIL=s5,law1 \
    arm s5-mut-nofallback 2 "negative control: the S5 fallback removed" S5 S 1 x8g.24xlarge "$P5" "$exs" cohort-s5 "$ALL3" "$W3" '{}'
  # Negative control (net accounting): lad-net leaves identity out of critical_measurement_s.
  MUTF=mut_net EXPECTFAIL=net \
    arm s5-mut-net 4 "negative control: identity left out of lad-net's sum" S5 S 1 x8g.24xlarge "$P5" "$exs" cohort-s5 "$ALL3" "$W3" '{}'
  # A corrupt input: GNU gzip fails on it, so input_defect; the run fails (the classifier sees a short mate).
  local exc
  exc=$(jq -nc --argjson g "${cut[1]}" --argjson r "${cut[2]}" --arg h "${cut[3]}" '{exit:"fail", pipefail_off:true,
    messages:["\"input_defect\":true"]}')
  # Its identity lines: input_defect on the cut mate only, with the tools' real exits (gzip's non-zero).
  CUT=("${cut[@]}")
  post_corrupt() {
    local L; L="$T/s3/$RESB/aws-kraken2/g3/$(cat "$T/cases/$1/cid")-r0/out/lad.jsonl"
    if jq -e -s --argjson g "${CUT[1]}" --argjson r "${CUT[2]}" 'map(select(.kind == "identity")) | (map(select(.input_defect)) | map(.file)) == ["SRR062634_1.fastq.gz"]
        and (map(select(.file == "SRR062634_1.fastq.gz"))[0] | .gzip_exit == $g and .rapidgzip_exit == $r and .gzip_exit != 0)' "$L" > /dev/null; then
      echo "ok   $1: s5: input_defect on SRR062634_1 only; its recorded exits (gzip ${CUT[1]}, rapidgzip ${CUT[2]}) are the tools' real ones (the independent run)"
    else
      echo "FAIL $1: s5: input_defect or the recorded exits are wrong: $(jq -c 'select(.kind == "identity") | [.file, .gzip_exit, .rapidgzip_exit, .input_defect]' "$L" 2> /dev/null | tr '\n' ' ')"; return 1
    fi
  }
  POST=post_corrupt arm s5-corrupt 2 "S5: a corrupt input (mate 1 cut at half its bytes)" S5 S 1 x8g.24xlarge "$P5" "$exc" \
    cohort-corrupt "SRR062634 ERR478965" "200000 200000" '{}'
}

case_law1_mut() {
  # Negative control for Law 1: the classifier called with --minimum-hit-groups 3; outputs differ.
  MUTF=mut_law1 EXPECTFAIL=law1 \
    arm law1-mut 1 "negative control: a classifier option changed (Law 1 must fail)" S7a S 1 x8g.24xlarge "$P_BASE" "$EX_OK" \
    cohort "${SRC[0]}" "${WEIGHTS[0]}" '{}'
}

case_neg() {
  # (3) each must fail the run, for the stated reason.
  local PE; PE=$(pset "$P_BASE" CLASSIFIER=ours-engine DB_STAGE=ranged-get DB_PLACE=memory DB_LOAD=resident INFLIGHT=1 OUT_UPLOAD=s5cmd-overlap)
  local one=(cohort "${SRC[0]}" "${WEIGHTS[0]}" '{}')
  # The upstream build leaves a gzip (or bzip2) in its install dir, KRAKEN2_DIR.
  pyfix mut-gzip scripts/oracle-build.sh "'\\necho \"\$DST\"\\n'" "'\\ntouch \"\$DST/gzip\"; chmod +x \"\$DST/gzip\"\\necho \"\$DST\"\\n'"
  pyfix mut-bzip2 scripts/oracle-build.sh "'\\necho \"\$DST\"\\n'" "'\\ntouch \"\$DST/bzip2\"\\necho \"\$DST\"\\n'"
  arm neg-gzip-k2dir 3 "a gzip in KRAKEN2_DIR" S7a S 1 x8g.24xlarge "$P_BASE" '{"exit":"fail","messages":["a gzip or bzip2 in KRAKEN2_DIR"]}' "${one[@]}" -- AK2T_MUTATE=/work/cases/mut-gzip.sh
  arm neg-bzip2-k2dir 3 "a bzip2 in KRAKEN2_DIR" S7a S 1 x8g.24xlarge "$P_BASE" '{"exit":"fail","messages":["a gzip or bzip2 in KRAKEN2_DIR"]}' "${one[@]}" -- AK2T_MUTATE=/work/cases/mut-bzip2.sh
  arm neg-etag-lv 3 "an ETag mismatch, via lv_etag" S7a S 1 x8g.24xlarge "$P_BASE" '{"exit":"fail","messages":["hash.k2d does not match its ETag","does not match ETag"]}' \
    "${one[@]}" -- AK2T_HASH_ETAG="$BADETAG"
  # The engine's own refusal must be the ETag (its stderr, in the run log), not a load or network failure.
  arm neg-etag-engine 3 "an ETag mismatch, via the engine's in-memory check" O0b O 1 x8g.24xlarge "$PE" \
    '{"exit":"fail","messages":["a classifier exited non-zero","stderr] classify: engine: hash.k2d does not match its ETag: computed"]}' \
    "${one[@]}" -- AK2T_HASH_ETAG="$BADETAG" AK2_REHEARSE_HASH_URL="$BADURL"
  # The classify rc, as the lad-sample line records it, is the classifier's own non-zero status.
  post_rc() {
    local r; r=$(sed -n 's/^lad-sample .*"rc":\([0-9]*\),.*/\1/p' "$T/cases/$1/r0.out" | head -1)
    if [ -n "$r" ] && [ "$r" != 0 ]; then echo "ok   $1: rc: the lad-sample line records the classifier's own exit $r"; else echo "FAIL $1: rc: no non-zero rc in a lad-sample line ('$r')"; return 1; fi
  }
  put cohort-cut SRR062634 "$T/reads/cut_1.fq.gz" "$K2_READS/SRR062634_200000_2.fq.gz"
  POST=post_rc arm neg-classifier-rc 3 "a classifier exiting non-zero (a truncated mate)" S7a S 1 x8g.24xlarge "$P_BASE" \
    '{"exit":"fail","messages":["a classifier exited non-zero"]}' cohort-cut "SRR062634" "200000" '{}'
  MUTF=mut_noline \
    arm neg-engine-noline 3 "an engine home sample with no ak2-sample line" O0b O 1 x8g.24xlarge "$PE" \
    '{"exit":"fail","messages":["home samples have no ak2-sample line: ERR478965"]}'
  # cohort_place.py: needs fails; table fails; needs reads one sample fewer than the table homes;
  # needs empty with a table that homes nothing on rank 0 (so only the empty-NEED check can catch it).
  pyfix mut-needs scripts/lib/cohort_place.py "'    if cmd == \"needs\":\\n'" "'    if cmd == \"needs\":\\n        sys.exit(3)\\n'"
  pyfix mut-table scripts/lib/cohort_place.py "'    elif cmd == \"table\":\\n'" "'    elif cmd == \"table\":\\n        sys.exit(3)\\n'"
  pyfix mut-disagree scripts/lib/cohort_place.py "'print(\"\\\\n\".join(need))'" "'print(\"\\\\n\".join(need[:-1]))'"
  pyfix mut-emptyneed scripts/lib/cohort_place.py "'print(\"\\\\n\".join(need))'" "'print(\"\")'"
  pyfix mut-emptyneed2 scripts/lib/cohort_place.py "\"{home[s['name']] if home[s['name']] is not None else 'all'}\"" "'{9}'"
  { cat "$T/cases/mut-emptyneed.sh"; tail -n +2 "$T/cases/mut-emptyneed2.sh"; } > "$T/cases/mut-emptyneed3.sh" && mv "$T/cases/mut-emptyneed3.sh" "$T/cases/mut-emptyneed.sh"
  arm neg-place-needs 3 "cohort_place.py needs fails" O0b O 1 x8g.24xlarge "$PE" '{"exit":"fail","messages":["cohort_place.py needs failed"]}' -- AK2T_MUTATE=/work/cases/mut-needs.sh
  arm neg-place-table 3 "cohort_place.py table fails" O0b O 1 x8g.24xlarge "$PE" '{"exit":"fail","messages":["cohort_place.py table failed"]}' -- AK2T_MUTATE=/work/cases/mut-table.sh
  arm neg-place-disagree 3 "needs and table disagree" O0b O 1 x8g.24xlarge "$PE" '{"exit":"fail","messages":["would read 2 samples but is home to 3"]}' -- AK2T_MUTATE=/work/cases/mut-disagree.sh
  arm neg-place-emptyneed 3 "an empty NEED" O0b O 1 x8g.24xlarge "$PE" '{"exit":"fail","messages":["no inputs to read with 3 samples planned"]}' -- AK2T_MUTATE=/work/cases/mut-emptyneed.sh
}

case_net() {
  # (4) SETUP=overlap with a slow build (oracle-build.sh sleeps 20 s first): build-wait, identity, load.
  pyfix mut-slowbuild scripts/oracle-build.sh "'\\nmkdir -p \"\$(dirname \"\$DST\")\"\\n'" "'\\nsleep 20\\nmkdir -p \"\$(dirname \"\$DST\")\"\\n'"
  arm overlap-slow-build 4 "SETUP=overlap with a slow build (20 s more)" S9 S 1 x8g.24xlarge \
    "$(pset "$P_BASE" GUNZIP=rapidgzip-Pauto OUT_UPLOAD=s5cmd-overlap SETUP=overlap)" "$(ex '{"slow_build":true,"s5":{}}')" -- AK2T_MUTATE=/work/cases/mut-slowbuild.sh
  # Tail uploads lag the hashes: 3 lanes over 3 identical 1M-pair samples finish together, and each
  # upload to out/ takes 4 s, so after the first output's hash an upload is always in flight.
  if [ ! -s "$T/reads/m_1.fq.gz" ]; then
    for m in 1 2; do
      head -n 4000000 "$K2_READS/SRR062634_8000000_$m.fq" > "$T/reads/m_$m.fq" && gzip -c "$T/reads/m_$m.fq" > "$T/reads/m_$m.fq.gz" || return 1
    done
    ref SRR062634m "$T/reads/m_1.fq" "$T/reads/m_2.fq" || return 1
    rm -f "$T/reads/m_1.fq" "$T/reads/m_2.fq"
    for x in a b c; do put cohort-tail "SRR062634$x" "$T/reads/m_1.fq.gz" "$T/reads/m_2.fq.gz"; done
  fi
  local PT; PT=$(pset "$P_BASE" THREADS=vcpus/3 PROCS=3 OUT_UPLOAD=s5cmd-overlap)
  local tailmap='{"SRR062634a":"SRR062634m","SRR062634b":"SRR062634m","SRR062634c":"SRR062634m"}' i rc
  for i in 1 2 3; do   # the three lanes must end within one 0.2 s watch poll: retried until the probe resolves
    arm "tail-crit-$i" 4 "tail uploads lag the hashes (try $i)" S7b S 1 x8g.24xlarge "$PT" "$(ex '{"tail":true,"lanes":3}')" \
      cohort-tail "SRR062634a SRR062634b SRR062634c" "1000000 1000000 1000000" "$tailmap" -- AK2T_UP_SLEEP=4 AK2T_UP_MATCH=/out/S7b/
    rc=$?
    grep -q '^FAIL tail-crit-[0-9]: tail-resolve: ' "$T/cases/tail-crit-$i/check.txt" || break
    say "tail-crit-$i: the lanes did not end together; the probe could not resolve, so it is run again"
    unresolved_retry "$i"
  done
  # Negative control: NB1 removed (uploads do not cover a hash); the tail's hashes are all critical.
  for i in 1 2 3; do
    MUTF=mut_nb1 EXPECTFAIL=tail \
      arm "tail-mut-$i" 4 "negative control: NB1 (uploads cover) removed (try $i)" S7b S 1 x8g.24xlarge "$PT" "$(ex '{"tail":true,"lanes":3}')" \
      cohort-tail "SRR062634a SRR062634b SRR062634c" "1000000 1000000 1000000" "$tailmap" -- AK2T_UP_SLEEP=4 AK2T_UP_MATCH=/out/S7b/
    grep -q '^FAIL tail-mut-[0-9]: tail-resolve: ' "$T/cases/tail-mut-$i/check.txt" || break
    say "tail-mut-$i: the probe could not resolve (tail-resolve failed), so it is run again"
    unresolved_retry "$i"
  done
}
# unresolved_retry TRY: a try whose probe could not resolve, with another try to come, is a retry,
# not a failure (its summary row says so); the last try's verdict stands.
unresolved_retry() {
  [ "$1" -lt 3 ] || return 0
  SUMMARY[${#SUMMARY[@]} - 1]="${SUMMARY[${#SUMMARY[@]} - 1]% FAIL} RETRY (the probe did not resolve)"
  NFAIL=$((NFAIL - 1))
}

case_resolver() {
  # (5) the generator's resolver (scripts/lib/ladder_levers.py params, as mkspec-ladder.sh calls it),
  # on synthetic ladder.resolved.tsv files under the scratch dir.
  local R="$T/resolver" rc=0 c=resolver src out r
  mkdir -p "$R" "$T/cases/$c"
  src=$(ls -d results/g3/2026*/manifest.json 2> /dev/null | head -1)   # a real run dir, as a resolution must cite
  rs() { printf 'origin\tcohort\tkey\tvalue\tsource\n' > "$R/$1.tsv"; shift; printf '%s\n' "$@" >> "$R/$1.tsv" 2> /dev/null; }
  res() { local f=$1; shift; printf 'origin\tcohort\tkey\tvalue\tsource\n' > "$R/$f.tsv"; for l in "$@"; do printf '%s\n' "$l" >> "$R/$f.tsv"; done; }
  chk() { if [ "$2" = 0 ]; then echo "ok   $c: $1"; else echo "FAIL $c: $1"; rc=1; fi; }
  lp() { python3 scripts/lib/ladder_levers.py params "$@"; }
  res nosource $'S4\t10\talias\tS4-t12\t'
  out=$(lp S5 10 --resolved "$R/nosource.tsv" 2>&1); r=$?
  [ "$r" = 3 ] && grep -q 'refused: .*has no source' <<< "$out"; chk "a resolution with no citation is refused (exit $r: $(tail -1 <<< "$out" | cut -c1-120))" $?
  res same "S4"$'\t'"10"$'\talias\tS4-t8\t'"$src"
  out=$(lp S5 10 --resolved "$R/same.tsv" 2>&1); r=$?
  [ "$r" = 3 ] && grep -q 'winner S4-t8 is not a candidate there' <<< "$out"; chk "an alias winner not run at the cohort (S4-t8: 12 processes > c10) is refused (exit $r: $(tail -1 <<< "$out" | cut -c1-140))" $?
  res good "S4"$'\t'"10"$'\talias\tS4-t12\t'"$src"
  out=$(lp S5 10 --resolved "$R/good.tsv" 2>&1); r=$?
  [ "$r" = 0 ] && grep -q 'THREADS=12; PROCS=vcpus/12' <<< "$out"; chk "positive control: S4 at c10 resolved to its candidate S4-t12 (12 x 8 on 96 vCPUs) reaches S5 (exit $r)" $?
  res alias "Sstar-time"$'\t'"1"$'\talias\tS7b\t'"$src"
  out=$(lp O0 1 --resolved "$R/alias.tsv" 2>&1); r=$?
  [ "$r" = 3 ] && grep -q 'winner S7b is not one of its alias_of' <<< "$out"; chk "an alias winner outside alias_of is refused (exit $r: $(tail -1 <<< "$out" | cut -c1-120))" $?
  for x in S4 S8; do
    out=$(lp "$x" 1 2>&1); r=$?
    [ "$r" = 3 ] && grep -q 'not-run at c1' <<< "$out"; chk "$x is not run at c1 (exit $r: $(tail -1 <<< "$out" | cut -c1-110))" $?
  done
  local p5 p2a p9 p7b
  p5=$(lp S5 1 | sed -n "s/^PARAMS='\(.*\)'$/\1/p"); p2a=$(lp S2a 1 | sed -n "s/^PARAMS='\(.*\)'$/\1/p")
  [ -n "$p5" ] && [ "$(grep -o 'THREADS=[^;]*; PROCS=[^;]*' <<< "$p5")" = "$(grep -o 'THREADS=[^;]*; PROCS=[^;]*' <<< "$p2a")" ]
  chk "at c1, S5 inherits S4's tokens as S2a's values ($(grep -o 'THREADS=[^;]*; PROCS=[^;]*' <<< "$p5"))" $?
  p9=$(lp S9 1 | sed -n "s/^PARAMS='\(.*\)'$/\1/p"); p7b=$(lp S7b 1 | sed -n "s/^PARAMS='\(.*\)'$/\1/p")
  [ -n "$p9" ] && [ "$(grep -o 'REPLICAS=[^;]*' <<< "$p9")" = "$(grep -o 'REPLICAS=[^;]*' <<< "$p7b")" ]
  chk "at c1, S9 inherits S8's K as S7b's ($(grep -o 'REPLICAS=[^;]*' <<< "$p9"))" $?
  res notrun "S4"$'\t'"1"$'\talias\tS4-t12\t'"$src"
  out=$(lp S5 1 --resolved "$R/notrun.tsv" 2>&1); r=$?
  [ "$r" = 0 ] && grep -q 'warning: .*S4 at c1.*is ignored' <<< "$out" && [ "$(sed -n "s/^PARAMS='\(.*\)'$/\1/p" <<< "$out")" = "$p5" ]
  chk "a resolution row for S4 at c1 (not run there) is ignored with a warning; S5 is unchanged (exit $r)" $?
  # Every committed c1 spec's parameter block is the resolver's.
  local s line want n=0 bad=""
  for s in runs/g3-l-*-c1.json; do
    line=$(jq -r '.command[2]' "$s" | grep -m1 '^RUNG=')
    want=$(lp "$(sed -n 's/^RUNG=\([^;]*\);.*/\1/p' <<< "$line")" 1 | sed -n "s/^PARAMS='\(.*\)'$/\1/p")
    n=$((n + 1)); [ "$line" = "$want" ] || bad="$bad $s"
  done
  [ -z "$bad" ] && [ "$n" = 15 ]; chk "the $n committed c1 specs' parameter blocks are the resolver's${bad:+ (not:$bad)}" $?
  return $rc
}

case_ttl() {
  # (7) a TTL kill mid-classify: the second sample (SRR062634, 8M pairs) is classifying when the
  # node is killed: KILL (a hard stop: only the 5 s pusher), then TERM (the preamble's trap).
  put cohort-ttl SRR062634 "$K2_READS/SRR062634_200000_1.fq.gz" "$K2_READS/SRR062634_200000_2.fq.gz"
  put cohort-ttl SRR062634L "$K2_READS/SRR062634_8000000_1.fq.gz" "$K2_READS/SRR062634_8000000_2.fq.gz"
  local sig c rc v
  # KILL-nopush, the negative control: the preamble's 5 s pusher removed from the payload, so a
  # hard kill leaves nothing pushed; the check must fail.
  for v in KILL TERM KILL-nopush; do
    sig=${v%-nopush}; c=ttl-$(tr '[:upper:]' '[:lower:]' <<< "$v")
    local line; line=$(hdr S7a S 2 1 "$(pset "$P_BASE" THREADS=2)")
    mkdir -p "$T/cases/$c"; body_arm "$T/cases/$c/body.sh" "$line"; payload "$T/cases/$c/payload.sh" "$T/cases/$c/body.sh"
    if [ "$v" = KILL-nopush ]; then
      mutate "$T/cases/$c/payload.sh" 'while sleep "$AK2_PUSH_EVERY"; do ak2_put "$AK2_LOG" log/run.log;' 'while sleep "$AK2_PUSH_EVERY"; do :;' ||
        { say "$c: the pusher mutation did not apply"; verdict "$c" 7 "negative control: no pusher" 1; continue; }
    fi
    say "---- $c (7): a $sig mid-classify; $line"
    ( launch "$c" "$T/cases/$c/payload.sh" 1 x8g.24xlarge 2 cohort-ttl "SRR062634 SRR062634L" "200000 8000000" AK2T_KEEP_VERSIONS=1 ) &
    local lp=$! t0=$SECONDS out="$T/cases/$c/r0.out" killed=""
    while kill -0 "$lp" 2> /dev/null && [ $((SECONDS - t0)) -lt 900 ]; do
      if grep -q '^lad-sample {.*"accession":"SRR062634"' "$out" 2> /dev/null && grep -q '^\[S7a SRR062634L\] Loading database information' "$out"; then
        # KILL leaves only what the 5 s pusher already pushed: the lines streamed by now must be
        # there; TERM runs the preamble's finish: every line streamed up to the kill must be there.
        cp "$out" "$T/cases/$c/before.out"
        sleep 7
        if grep -q '^lad-sample {.*"accession":"SRR062634L"' "$out"; then say "$c: the long sample finished before the kill"; break; fi
        cp "$out" "$T/cases/$c/at-kill.out"
        "${PM[@]}" kill --signal "$sig" "ak2lad-$$-$c-r0" > /dev/null 2>&1; killed=$(date +%s); break
      fi
      sleep 0.5
    done
    wait "$lp"
    local snap="$T/cases/$c/at-kill.out"; [ "$sig" = KILL ] && snap="$T/cases/$c/before.out"
    python3 - "$c" "$sig" "$snap" "$T/s3/$RESB/aws-kraken2/g3/$(cat "$T/cases/$c/cid")-r0" "$T/s3/.v/$RESB/aws-kraken2/g3/$(cat "$T/cases/$c/cid")-r0" "${killed:-0}" > "$T/cases/$c/check.txt" << 'PY'
import glob, os, sys
c, sig, cap, d, v, kt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
bad = 0
def need(ok, what):
    global bad
    print(f"{'ok  ' if ok else 'FAIL'} {c}: kill: {what}")
    bad += not ok
need(kt > 0 and os.path.exists(cap), f"the node was killed ({sig}) while the second sample classified")
streamed = open(cap, errors="replace").read().splitlines() if os.path.exists(cap) else []
p = os.path.join(d, "log", "run.log")
pushed = open(p, errors="replace").read().splitlines() if os.path.exists(p) else []
vers = sorted(glob.glob(os.path.join(v, "log", "run.log.*")), key=lambda f: int(f.rsplit(".", 1)[1]))
need(bool(pushed), f"a pushed log/run.log exists for the killed run ({len(pushed)} lines)")
key = [l for l in streamed if l.startswith("lad-sample ") or l.startswith("[S7a ") or l.startswith("ak2-phase\t") or l.startswith("lever ")]
missing = [l for l in key if l not in set(pushed)]
need(any(l.startswith("lad-sample ") for l in key) and any("Loading database information... done." in l for l in key),
     f"the stream before the kill had the first sample's lad-sample line and the classifier's own lines ({len(key)} such lines)")
need(not missing, f"every one of them is in the pushed log ({len(key) - len(missing)} of {len(key)}; missing {missing[:2]})")
need(any("ak2-phase\t" in l and "\tclassify\t" in l for l in pushed), "the pushed log shows the classify phase")
if sig == "TERM":
    need(any("spec body exit rc=143" in l for l in pushed), "TERM: the preamble's trap ran its finish (rc 143 in the pushed log)")
else:
    need(not any("spec body exit rc=" in l for l in pushed), "KILL: no finish ran (the hard stop): what is there came from the 5 s pusher")
    need(len(vers) >= 2, f"the pusher uploaded run.log {len(vers)} times before the kill")
sys.exit(1 if bad else 0)
PY
    rc=$?
    if [ "$v" = KILL-nopush ]; then
      if grep -q "^FAIL $c: kill: a pushed log/run.log exists\|^FAIL $c: kill: every one of them" "$T/cases/$c/check.txt"; then
        echo "ok   $c: negative control: with no pusher, a hard kill loses the streamed lines, and the check says so" >> "$T/cases/$c/check.txt"; rc=0
      else
        echo "FAIL $c: negative control: the check passed with no pusher: it cannot see a lost log" >> "$T/cases/$c/check.txt"; rc=1
      fi
    fi
    cat "$T/cases/$c/check.txt"
    verdict "$c" 7 "a $v mid-classify: the streamed lines are in the pushed log" "$rc"
    CID=$(cat "$T/cases/$c/cid"); tidy "$c"
  done
}

tables() {
  # (6) make g3-ladder's program on the rehearsal record of the 15 c1 specs: 0 DEFECTs, and the
  # aliases (Sstar-time, Sstar-cost at c1) read as their winner's runs. The resolved file is the
  # rehearsal's own, under the record dir, never scripts/g3/.
  local R=$1 rc=0 c=tables out
  mkdir -p "$T/cases/$c"
  printf 'origin\tcohort\tkey\tvalue\tsource\nSstar-time\t1\talias\tS9\t(rehearsal: a synthetic selection)\nSstar-cost\t1\talias\tSstar-r8gd\t(rehearsal: a synthetic selection)\n' > "$R/ladder.resolved.tsv"
  out=$(python3 scripts/lib/ladder_tables.py --results "$R/results" --levers scripts/g3/ladder.levers.tsv --resolved "$R/ladder.resolved.tsv" \
    --modelled "$R/none-modelled.tsv" --out "$R/ladder" 2>&1); rc=$?
  echo "$out" | sed 's/^/    /'
  {
    [ "$rc" = 0 ] && grep -q 'ladder_tables: 15 ladder run(s), .* 0 DEFECT(s)' <<< "$out" && echo "ok   $c: 15 ladder runs, 0 DEFECTs (exit $rc)" || echo "FAIL $c: want 15 runs and 0 DEFECTs (exit $rc)"
    local n1; n1=$(awk -F'\t' 'NR == 1 {for (i = 1; i <= NF; i++) h[$i] = i} NR > 1 && $h["status"] == "identical"' "$R/ladder/law1.tsv" 2> /dev/null | wc -l | tr -d ' ')
    [ "${n1:-0}" -ge 1 ] && ! awk -F'\t' 'NR == 1 {for (i = 1; i <= NF; i++) h[$i] = i} NR > 1 && $h["status"] != "identical"' "$R/ladder/law1.tsv" | grep -q . &&
      echo "ok   $c: law1.tsv: every accession identical across the 15 rungs" || echo "FAIL $c: law1.tsv is not all identical"
    # Each alias reads as its winner's runs: its rungs.tsv rows are the winner's, on an axis where
    # the three candidates differ (net wall, to the ms), so a wrong winner would show.
    local a w got want others
    for a in Sstar-time:S9 Sstar-cost:Sstar-r8gd; do
      w=${a#*:}; a=${a%%:*}
      got=$(awk -F'\t' -v r="$a" '$2 == r && $4 == "wall_net_s" {print $7 "|" $8 "|" $9}' "$R/ladder/rungs.tsv")
      want=$(awk -F'\t' -v r="$w" '$2 == r && $4 == "wall_net_s" {print $8 "|" $9}' "$R/ladder/rungs.tsv")
      others=$(awk -F'\t' '($2 == "S9" || $2 == "Sstar-r8g" || $2 == "Sstar-r8gd") && $4 == "wall_net_s" {print $9}' "$R/ladder/rungs.tsv" | sort -u | wc -l | tr -d ' ')
      [[ $got == "alias of $w "* ]] && [ "${got#*|}" = "$want" ] && [ "$others" = 3 ] &&
        echo "ok   $c: rungs.tsv reads $a at c1 as $w's runs (n|median ${got#*|}; the three candidates' net walls differ: $others values)" ||
        echo "FAIL $c: rungs.tsv: $a is '$got', $w is '$want' ($others distinct candidate values)"
    done
    awk -F'\t' '$1 == "S" && ($2 == "Sstar-time" || $2 == "Sstar-cost") && $8 == "wall_s"' "$R/ladder/deltas.tsv" | cut -f2-4,8,13-15,21 | sed 's/^/    deltas.tsv: /'
    awk -F'\t' 'NR == 1 {for (i = 1; i <= NF; i++) h[$i] = i} NR > 1 {print $h["in_attribution"]}' "$R/ladder/runs.tsv" | sort | uniq -c | sed 's/^/    runs.tsv in_attribution: /'
  } | tee "$T/cases/$c/check.txt"
  grep -q '^FAIL' "$T/cases/$c/check.txt" && rc=1
  verdict "$c" 6 "make g3-ladder on the rehearsal record" "$rc"
  # Every run rung's own lever phase is measured: the tables read it from the manifest phases the
  # body's ak2_phase markers give (run.sh's phases.tsv rule), so none may be missing.
  c=tables-lever-phase; mkdir -p "$T/cases/$c"
  awk -F'\t' -v c="$c" 'NR > 1 && $4 == "lever_phase_s" && $7 !~ /^alias/ {
      if ($8 >= 1) printf "ok   %s: %s: lever phase %s measured (n %s, %s s)\n", c, $2, $6, $8, $9
      else printf "FAIL %s: %s: lever phase %s missing (n %s): its manifest phases are there (phases.tsv), the tables do not read them\n", c, $2, $6, $8 }' \
    "$R/ladder/rungs.tsv" | tee "$T/cases/$c/check.txt"
  rc=0; grep -q '^FAIL' "$T/cases/$c/check.txt" && rc=1
  verdict "$c" 6 "every rung's lever phase in rungs.tsv" "$rc"
}

across_arms() {
  # Law 1 across arms (1): every passing, unmutated case's on-node sha256, sample by sample, is one
  # value, the oracle's. From the pushed lad-samples.jsonl of each node.
  local c=law1-across-arms rc
  mkdir -p "$T/cases/$c"
  python3 - "$T/cases" "$T/s3/$RESB/aws-kraken2/g3" "$T/ref" > "$T/cases/$c/check.txt" << 'PY'
import collections, glob, json, os, sys
cases, b, ref = sys.argv[1:4]
seen = collections.defaultdict(lambda: collections.defaultdict(set))   # (ref, role) -> sha -> cases
for cj in sorted(glob.glob(os.path.join(cases, "*", "case.json"))):
    c = json.load(open(cj))
    ck = os.path.join(os.path.dirname(cj), "check.txt")
    if c.get("expect", {}).get("exit", "ok") != "ok" or not os.path.exists(ck) or "FAIL " in open(ck).read():
        continue   # negative tests and negative controls (and any failing case) are not arms
    for n in c["nodes"]:
        for l in open(os.path.join(b, f"{c['cid']}-r{n['rank']}", "out", "lad-samples.jsonl")):
            s = json.loads(l)
            r = c["refmap"].get(s["accession"], s["accession"])
            for role in ("output", "report"):
                seen[(r, role)][s["outputs"][role]["sha256"]].add(f"{c['name']}:{c['params']['CLASSIFIER']}")
bad = 0
for (r, role), shas in sorted(seen.items()):
    want = open(os.path.join(ref, f"{r}.{role}.sha256")).read().split()[0]
    arms = sorted({x for v in shas.values() for x in v})
    cl = sorted({a.split(":")[1] for a in arms})
    ok = list(shas) == [want]
    bad += not ok
    print(f"{'ok  ' if ok else 'FAIL'} law1-across-arms: {r} {role}: one sha256 {want[:16]} (the oracle's) over {len(arms)} cases ({', '.join(cl)})"
          + ("" if ok else f"; got {dict((k[:16], sorted(v)) for k, v in shas.items())}"))
sys.exit(1 if bad or not seen else 0)
PY
  rc=$?; cat "$T/cases/$c/check.txt"
  verdict "$c" 1 "each sample's sha256 equal across every arm and the oracle" "$rc"
}

tables_neg() {
  # Negative controls of the tables step: (a) the record plus an S1 run whose classifier option was
  # changed must give a Law 1 DEFECT on that run; (b) an alias winner outside alias_of must give a
  # DEFECT (resolved). Either passing would mean "0 DEFECTs" above cannot fail.
  local R=$1 c=tables-neg rc=0 out
  mkdir -p "$T/cases/$c"
  out=$(python3 scripts/lib/ladder_tables.py --results "$R/results" --levers scripts/g3/ladder.levers.tsv --resolved "$LADREH_RECORD/ladder.resolved.tsv" \
    --modelled "$R/none-modelled.tsv" --out "$R/ladder" 2>&1); local r1=$?
  printf 'Sstar-time\t1\talias\tS7b\t(rehearsal: a winner outside alias_of)\n' | cat <(head -1 "$LADREH_RECORD/ladder.resolved.tsv") - > "$R/bad.resolved.tsv"
  local out2; out2=$(python3 scripts/lib/ladder_tables.py --results "$LADREH_RECORD/results" --levers scripts/g3/ladder.levers.tsv --resolved "$R/bad.resolved.tsv" \
    --modelled "$R/none-modelled.tsv" --out "$R/ladder-badalias" 2>&1); local r2=$?
  {
    echo "$out" | grep 'DEFECT' | head -3 | sed 's/^/    /'
    [ "$r1" = 1 ] && grep -q 'DEFECT (Law 1): .*spec-s1-law1mut\|DEFECT (Law 1)' <<< "$out" &&
      echo "ok   $c: a Law-1-mutated S1 run in the record gives a Law 1 DEFECT (exit $r1)" || echo "FAIL $c: no Law 1 DEFECT for the mutated run (exit $r1)"
    echo "$out2" | grep 'DEFECT' | head -2 | sed 's/^/    /'
    [ "$r2" = 1 ] && grep -q "DEFECT (resolved): .*Sstar-time at c1 names 'S7b'" <<< "$out2" &&
      echo "ok   $c: an alias winner outside alias_of gives a DEFECT (resolved) (exit $r2)" || echo "FAIL $c: no DEFECT for an alias winner outside alias_of (exit $r2)"
  } | tee "$T/cases/$c/check.txt"
  grep -q '^FAIL' "$T/cases/$c/check.txt" && rc=1
  verdict "$c" 6 "negative controls: the tables flag a Law 1 mismatch and a bad alias" "$rc"
}

# ---- run ----
case $MODE in
  spec)
    [ -n "${LADREH_RECORD:-}" ] && { mkdir -p "$LADREH_RECORD" || exit 1; say "record: $LADREH_RECORD (scripts/lib/ladder_rehearse.sh tables $LADREH_RECORD reads it)"; }
    spec_case "$SPEC"
    ;;
  tables)
    LADREH_RECORD=$TREC tables "$TREC"
    ;;
  all|only)
    WANT=" ${*:-arms s5 law1 neg net resolver ttl specs} "
    [[ $WANT == *" arms "* ]] && case_arms
    [[ $WANT == *" s5 "* ]] && case_s5
    [[ $WANT == *" law1 "* ]] && case_law1_mut
    [[ $WANT == *" neg "* ]] && case_neg
    [[ $WANT == *" net "* ]] && case_net
    if [[ $WANT == *" resolver "* ]]; then
      say "---- resolver (5)"
      case_resolver > "$T/cases/resolver.txt" 2>&1; rr=$?
      mkdir -p "$T/cases/resolver"; mv "$T/cases/resolver.txt" "$T/cases/resolver/check.txt"; cat "$T/cases/resolver/check.txt"
      verdict resolver 5 "the generator's resolver refusals and c1 fallbacks" "$rr"
    fi
    [[ $WANT == *" ttl "* ]] && case_ttl
    if [[ $WANT == *" specs "* ]]; then
      export LADREH_RECORD="$T/record"; mkdir -p "$LADREH_RECORD"
      for s in runs/g3-l-*-c1.json; do spec_case "$s"; done
      tables "$LADREH_RECORD"
      mkdir -p "results/rehearse/ladder-$TS-$SHA-tables" && cp "$LADREH_RECORD/ladder/"* "results/rehearse/ladder-$TS-$SHA-tables/" &&
        cp "$LADREH_RECORD/ladder.resolved.tsv" "results/rehearse/ladder-$TS-$SHA-tables/rehearsal.ladder.resolved.tsv" &&
        say "tables of the rehearsal record: results/rehearse/ladder-$TS-$SHA-tables/"
      cp -R "$LADREH_RECORD" "$T/record-neg" && rm -rf "$T/record-neg/ladder"
      LADREH_RECORD="$T/record-neg" MUTF=mut_law1 EXPECTFAIL=law1 spec_case runs/g3-l-s1-c1.json law1mut
      tables_neg "$T/record-neg"
    fi
    [ -n "$(ls "$T"/cases/*/case.json 2> /dev/null)" ] && across_arms
    ;;
esac

say "summary ($MODE${SPEC:+ $SPEC} at $SHA):"
printf '%-4s | %-26s | %-58s | %6s | %8s | %s\n' item case what checks failed result
for r in "${SUMMARY[@]}"; do echo "$r"; done
say "disk at end: $(df -h ~ | tail -1 | awk '{print $4}') free"
[ "$NFAIL" = 0 ] && say "ok (${#SUMMARY[@]} cases)" || say "FAILED: $NFAIL of ${#SUMMARY[@]} cases (KEEP=1 keeps $T)"
exit $(( NFAIL > 0 ))
