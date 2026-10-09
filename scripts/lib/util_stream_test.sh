#!/usr/bin/env bash
# make util-stream-test [N=3] (docs/util.md), and the first step of every make rehearse: the
# utilisation sampler streams on every node, checked on observed output. N nodes, each an Amazon
# Linux 2023 container (podman; the kernel's /proc and /sys, as on an instance) running exactly
# what run.sh launches: the stub from scripts/lib/mkstub.sh, which starts the sampler and execs
# the payload (scripts/preamble.sh + a short body). The stand-ins are only at the edges: curl
# answers IMDS, the bucket-region HEAD and the payload GET; aws copies `s3 cp` uploads into a
# shared directory and keeps every upload as its own timestamped version; sudo runs the command.
# The body burns one vCPU for 8 s (phase burn), holds 256 MiB in /dev/shm for 6 s (phase shm),
# downloads 64 MiB over the container's eth0 from a host-side server (phase net), then exits 0.
# Fails unless, for every node:
#   - the container exits 0 and log/util.tsv was uploaded >= 2 times before the body's end phase,
#     each upload with more ticks than the one before (it streamed; it was not only pushed at exit);
#   - the last upload's first tick precedes the preamble (the stub started the sampler), its last
#     tick is the `final` one, at or after the end phase, no gap between ticks exceeds 2.5 s, and
#     the phases stub, preamble, body, burn, shm, net and end all appear;
#   - scripts/lib/util.py resolves the three effects it must see: burn's busy vCPU-s >= 0.8 x its
#     seconds (one vCPU at least), shm's peak used memory >= its start + 200 MiB (Shmem +250 MiB), and net's bytes
#     >= 64 MiB; and a sampler whose stub exits before exec (exit 97) stops with it.
# Prints the sampler's own CPU per tick (its overhead). Record: results/rehearse/util-stream-<UTC>-<commit>.log.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
N=${1:-${N:-3}}
command -v podman >/dev/null || { echo "util-stream-test: need podman (docs/util.md)" >&2; exit 1; }
IMG=public.ecr.aws/amazonlinux/amazonlinux:2023
SHA=$(git rev-parse --short=7 HEAD)
mkdir -p results/rehearse || exit 1
REC="results/rehearse/util-stream-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$REC") 2>&1
echo "util-stream-test: $N node(s) at $SHA ($(git diff --quiet HEAD -- scripts && echo clean || echo dirty)); shell flags $-; record $REC"
# Under $HOME: the podman machine shares it.
T=$(mktemp -d "$HOME/.ak2-util-stream.XXXXXX") || exit 1
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; podman rm -f $(for ((k = 0; k < N; k++)); do echo "ak2-util-$$-$k"; done) >/dev/null 2>&1
  [ "${KEEP:-0}" = 1 ] && echo "util-stream-test: kept $T" || rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/bucket" "$T/www"

# The download for phase net, served from the host (reached as host.containers.internal).
head -c 67108864 /dev/urandom > "$T/www/blob" || exit 1
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --directory "$T/www" > "$T/http.log" 2>&1 &
SRV=$!

scripts/lib/mkstub.sh > "$T/stub.sh" || exit 1
cat > "$T/body.sh" <<'EOF'
ak2_phase burn
end=$((SECONDS + 8)); while [ "$SECONDS" -lt "$end" ]; do :; done
ak2_phase shm
head -c 268435456 /dev/zero > /dev/shm/ak2-util-test; sleep 6; rm -f /dev/shm/ak2-util-test
ak2_phase net
/usr/bin/curl -sf -o /dev/null "http://host.containers.internal:$AK2T_PORT/blob" || ak2_say "net download failed"
up=$(cat /tmp/ak2-util.pid)
read -r -a st < "/proc/$up/stat"
ak2_say "util-overhead pid $up utime ${st[13]} stime ${st[14]} ticks $(grep -c '^S' /tmp/ak2-util.tsv)"
ak2_req Test 1
EOF
{ cat scripts/preamble.sh; printf '\n'; cat "$T/body.sh"; } > "$T/payload.sh"
# Negative controls (docs/util.md): BREAK=nopush removes the pusher's util.tsv push (the record
# then reaches S3 only at exit), BREAK=nostub removes the stub's sampler start (the preamble's
# fallback starts it late). Each must make this test FAIL.
PUSHLINE='    [ -s "$AK2_UTIL" ] && ak2_put "$AK2_UTIL" log/util.tsv; done ) >/dev/null 2>&1 &'
case ${BREAK:-} in
  "") ;;
  nopush)
    python3 -c 'import sys; p, a = sys.argv[1], sys.argv[2]; s = open(p).read(); assert a in s; open(p, "w").write(s.replace(a, "    done ) >/dev/null 2>&1 &"))' \
      "$T/payload.sh" "$PUSHLINE" || { echo "util-stream-test: BREAK=nopush did not apply" >&2; exit 2; } ;;
  nostub)
    python3 -c 'import sys; p, a = sys.argv[1], sys.argv[2]; s = open(p).read(); assert a in s; open(p, "w").write(s.replace(a, ":"))' \
      "$T/stub.sh" '( bash /tmp/ak2-util.sh loop "$$" < /dev/null > /dev/null 2>&1 & )' || { echo "util-stream-test: BREAK=nostub did not apply" >&2; exit 2; } ;;
  *) echo "util-stream-test: BREAK=$BREAK: want nopush or nostub" >&2; exit 2 ;;
esac
[ -n "${BREAK:-}" ] && echo "util-stream-test: BREAK=$BREAK: a negative control; this run must FAIL"
PSHA=$(shasum -a 256 "$T/payload.sh" | cut -d' ' -f1)

cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
# IMDS, the bucket-region HEAD, the payload GET; anything else goes to the real curl.
out=""; url=""; prev=""
for a in "$@"; do [ "$prev" = -o ] && out=$a; case $a in http*) url=$a ;; esac; prev=$a; done
case $url in
  *169.254.169.254*/api/token) echo tok ;;
  *meta-data/placement/region) echo us-west-2 ;;
  *meta-data/placement/availability-zone) echo us-west-2a ;;
  *meta-data/instance-id) echo "i-$AK2T_NODE" ;;
  *meta-data/instance-type) echo t.test ;;
  *meta-data/ami-id) echo ami-test ;;
  https://*.s3.*amazonaws.com/) printf 'HTTP/1.1 200 OK\r\nx-amz-bucket-region: us-west-2\r\n\r\n' ;;
  https://*.s3.us-west-2.amazonaws.com/*) cp /work/payload.sh "$out" ;;
  *) exec /usr/bin/curl "$@" ;;
esac
EOF
cat > "$T/bin/aws" <<'EOF'
#!/bin/bash
# s3 cp LOCAL s3://b/k: into /bucket/b/k, and every upload kept as /bucket/.v/b/k.<epoch ns>.
case "$1 $2" in
  "s3 cp")
    a=(); for x in "${@:3}"; do case $x in --*) ;; *) a+=("$x") ;; esac; done
    case ${a[1]} in s3://*) k=${a[1]#s3://}
      mkdir -p "/bucket/$(dirname "$k")" "/bucket/.v/$(dirname "$k")"
      cp "${a[0]}" "/bucket/$k" && cp "${a[0]}" "/bucket/.v/$k.$(date +%s%N)" ;; *) exit 1 ;; esac ;;
  "s3api get-bucket-request-payment") echo BucketOwner ;;
  *) [ "$1" = --version ] && echo aws-cli/stub; exit 0 ;;
esac
EOF
printf '#!/bin/bash\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$T/bin/sudo"
chmod +x "$T/bin"/*

RC=0
# The sampler must not outlive a stub that exits before exec (exit 97: spored would otherwise
# wait on it until the TTL): it watches the stub's PID.
cp scripts/util-sampler.sh "$T/sampler.sh"
cat > "$T/orphan.sh" <<'EOF'
bash -c '( bash /work/sampler.sh loop "$$" < /dev/null > /dev/null 2>&1 & ); sleep 2; exit 97'
sleep 3
p=$(cat /tmp/ak2-util.pid); n=$(grep -c '^S' /tmp/ak2-util.tsv)
if kill -0 "$p" 2>/dev/null; then echo "sampler $p still running after its stub exited ($n ticks)"; exit 1; fi
echo "sampler $p exited with its stub ($n ticks)"
EOF
OR=$(podman run --rm -v "$T:/work:ro" "$IMG" bash /work/orphan.sh 2>&1); orc=$?
echo "util-stream-test: $([ $orc = 0 ] && echo 'ok  ' || echo FAIL) early stub exit: $OR"
[ $orc = 0 ] || RC=1

RUN="$(date -u +%Y%m%d-%H%M%S)-$SHA-util-n$N"
declare -a PIDS T0
for ((k = 0; k < N; k++)); do
  P="s3://ak2-results-test/aws-kraken2/g9/$RUN-r$k"
  T0[$k]=$(date +%s)
  podman run --rm --name "ak2-util-$$-$k" --shm-size=512m -v "$T:/work:ro" -v "$T/bucket:/bucket" \
    -e PATH=/work/bin:/usr/local/bin:/usr/bin:/bin -e AK2T_NODE="r$k" -e AK2T_PORT="$PORT" \
    -e AK2_EXPECT_REGION=us-west-2 -e AK2_BUCKETS=ak2-results-test -e AK2_ALLOWED_BUCKETS=ak2-results-test \
    -e AK2_S3_PREFIX="$P" -e AK2_RUN_ID="$RUN-r$k" -e AK2_GATE=g9 -e AK2_PAYLOAD_URI="$P/payload.sh" \
    -e AK2_PAYLOAD_URL="https://ak2-results-test.s3.us-west-2.amazonaws.com/aws-kraken2/g9/$RUN-r$k/payload.sh" \
    -e AK2_PAYLOAD_SHA256="$PSHA" "$IMG" bash -c "$(cat "$T/stub.sh")" > "$T/node$k.out" 2>&1 &
  PIDS[$k]=$!
done
for ((k = 0; k < N; k++)); do
  wait "${PIDS[$k]}"; rc=$?
  T1=$(date +%s)
  echo "util-stream-test: node r$k container exit $rc"
  [ "$rc" = 0 ] || { RC=1; tail -20 "$T/node$k.out" | sed "s/^/  r$k | /"; }
  D="$T/bucket/ak2-results-test/aws-kraken2/g9/$RUN-r$k"
  V="$T/bucket/.v/ak2-results-test/aws-kraken2/g9/$RUN-r$k/log"
  # A run dir as run.sh leaves it: the pushed log and util record, and a manifest whose billed
  # window runs from the VM kernel's btime to the container's exit on the host's clock.
  R="$T/runs/g9/$RUN-r$k"; mkdir -p "$R/log"
  cp "$D/log/util.tsv" "$D/log/run.log" "$R/log/" 2>/dev/null
  NC=$(awk -F'\t' '$1=="H" && $2=="ncpu"{print $3}' "$R/log/util.tsv" 2>/dev/null)
  MT=$(awk -F'\t' '$1=="S"{print $15; exit}' "$R/log/util.tsv" 2>/dev/null)
  # launch = the kernel's btime: the container shares the podman VM's kernel, booted long before.
  BT=$(awk -F'\t' '$1=="H" && $2=="btime"{print $3}' "$R/log/util.tsv" 2>/dev/null)
  jq -n --argjson l "${BT:-$((T0[$k] - 1))}" --argjson e "$((T1 + 1))" --argjson nc "${NC:-0}" --argjson mt "${MT:-0}" '{region:"us-west-2",
    billed_seconds:($e - $l), cost_usd:1, instance:{type:"t.test", launch_time:($l | todate), terminated_at:($e | todate),
    type_info:{vcpus:$nc, memory_mib:(($mt / 1024) | floor), baseline_gbps:10, peak_gbps:10}}}' > "$R/manifest.json"
  python3 - "$R" "$V" "$k" <<'PY' || RC=1
import glob, os, sys
sys.path.insert(0, "scripts/lib")
import util
R, V, k = sys.argv[1], sys.argv[2], sys.argv[3]
bad = []
def need(cond, what):
    print(f"util-stream-test: r{k} {'ok  ' if cond else 'FAIL'} {what}")
    if not cond:
        bad.append(what)
log = open(os.path.join(R, "log", "run.log")).read().splitlines() if os.path.exists(os.path.join(R, "log", "run.log")) else []
ph = {}
for l in log:
    p = l.split("\t")
    if p[0] == "ak2-phase" and len(p) >= 4:
        ph.setdefault(p[3], int(p[2]))
need("preamble" in ph and "end" in ph, f"run.log streamed with phases preamble..end ({sorted(ph)})")
vers = sorted(glob.glob(os.path.join(V, "util.tsv.*")), key=lambda f: int(f.rsplit(".", 1)[1]))
ticks = [sum(1 for l in open(f) if l.startswith("S\t")) for f in vers]
end = ph.get("end", 0)
during = [n for f, n in zip(vers, ticks) if int(f.rsplit(".", 1)[1]) / 1e9 < end]
need(len(during) >= 2, f"util.tsv uploaded {len(during)} time(s) before the end phase ({len(vers)} in all; ticks {ticks})")
need(all(b > a for a, b in zip(during, during[1:])), "each upload during the run has more ticks than the last")
up = os.path.join(R, "log", "util.tsv")
need(os.path.exists(up) and os.path.getsize(up) > 0, "the last upload is non-empty")
if bad:
    sys.exit(1)
head, rows, eth, nbad = util.parse_util(up)
need(nbad == 0, f"no malformed lines ({nbad})")
need(rows[0]["phase"] == "stub" and int(rows[0]["t"]) <= ph["preamble"], f"first tick ({rows[0]['phase']}, {rows[0]['t']:.3f}) precedes the preamble ({ph['preamble']}): the stub started it")
need(rows[-1]["tag"] == "final" and rows[-1]["t"] >= end, f"last tick is final ({rows[-1]['tag']}) at/after the end phase")
gaps = [b["t"] - a["t"] for a, b in zip(rows, rows[1:])]
need(max(gaps) <= 2.5, f"max gap between ticks {max(gaps):.2f} s")
seen = list(dict.fromkeys(r["phase"] for r in rows))
need(all(p in seen for p in ("stub", "preamble", "body", "burn", "shm", "net", "end")), f"phases in the ticks: {seen}")
need(len(rows) >= (rows[-1]["t"] - rows[0]["t"]) * 0.9, f"{len(rows)} ticks over {rows[-1]['t'] - rows[0]['t']:.1f} s (1 Hz)")
util.main([R])
import csv
tab = {(r["scope"], r["phase"]): r for r in csv.DictReader(open(os.path.join(R, "tables", "util.tsv")), delimiter="\t")}
b, s, n = tab[("node-phase", "burn")], tab[("node-phase", "shm")], tab[("node-phase", "net")]
need(float(b["busy_vcpu_s"]) >= 0.8 * float(b["seconds"]), f"burn: {b['busy_vcpu_s']} busy vCPU-s in {b['seconds']} s (one vCPU burnt)")
# The VM's other memory drifts by hundreds of MiB, so the reference is shm's own boundary tick
# (taken by ak2_phase before the write); the table's peak must carry the rise too.
srows = [r for r in rows if r["phase"] == "shm"]
u0 = util.used_kib(srows[0]) / 1024
need(float(s["mem_used_peak_gib"]) * 1024 >= u0 + 200 and max(r["shmem_kib"] for r in srows) - srows[0]["shmem_kib"] >= 250 * 1024,
     f"shm: peak used {float(s['mem_used_peak_gib']) * 1024:.0f} MiB vs {u0:.0f} MiB at the phase's start; "
     f"Shmem +{(max(r['shmem_kib'] for r in srows) - srows[0]['shmem_kib']) / 1024:.0f} MiB (256 MiB written to /dev/shm)")
need(float(n["net_bytes"]) >= 64 * 1048576, f"net: {n['net_bytes']} bytes on {head.get('iface')} (64 MiB downloaded)")
node = tab[("node", "(billed window)")]
print(f"util-stream-test: r{k} node U_cpu {node['U_cpu']} U_mem {node['U_mem_mean']} (peak {node['U_mem_peak']}) "
      f"U_net {node['U_net_baseline']}; unobservable {node['unobs_launch_to_boot_s']}/{node['unobs_boot_to_sampler_s']}/{node['unobs_last_to_term_s']} s")
sys.exit(1 if bad else 0)
PY
  grep -h 'util-overhead' "$R/log/run.log" 2>/dev/null | sed 's/.*util-overhead/util-overhead/' |
    awk -v k="$k" '{printf "util-stream-test: r%s sampler CPU %.2f s over %d ticks (%.2f ms per tick)\n", k, ($5+$7)/100, $9, ($5+$7)*10/$9}'
done
[ "$RC" = 0 ] && echo "util-stream-test: ok ($N node(s))" || echo "util-stream-test: FAILED (KEEP=1 keeps the work dir)"
exit "$RC"
