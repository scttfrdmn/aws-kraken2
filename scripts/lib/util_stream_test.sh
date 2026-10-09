#!/usr/bin/env bash
# make util-stream-test [N=3] (docs/util.md), and the first step of every make rehearse: the
# utilisation sampler streams on every node, checked on observed output. N nodes, each an Amazon
# Linux 2023 container (podman; the kernel's /proc and /sys, as on an instance) running exactly
# what run.sh launches: the stub from scripts/lib/mkstub.sh, under `bash -e -c` as spawn starts it
# ($- = ehB), which starts the sampler and execs the payload (scripts/preamble.sh + a short
# body). The stand-ins are only at the edges: curl answers IMDS, the bucket-region HEAD and the
# payload GET; aws copies `s3 cp` uploads into a shared directory and keeps every upload as its
# own timestamped version; sudo runs the command. The image is AL2023 plus util-linux-core (the
# AMI's renice), built once as localhost/ak2-util-test; containers get CAP_SYS_NICE and run
# rootful when the podman machine has a root connection (AK2T_ROOTLESS=1 forces rootless).
# The body: burn (one vCPU for 8 s), shm (256 MiB in /dev/shm for 6 s), net (64 MiB over eth0
# from a host-side server), starve (nproc un-niced busy loops for 15 s), hold (50 s: the pusher
# re-uploads util.tsv every 30 s), then exit 0.
# Rounds: N nodes at once; then, when N > 1, one node alone, where the CPU, memory and network
# magnitudes are checked from above too (no other container shares the kernel). Fails unless,
# for every node of every round:
#   - the container exits 0; the stub saw errexit on ($- has e) and the run went on;
#   - log/util.tsv was uploaded >= 2 times before the end phase, each upload with more ticks than
#     the one before (it streamed), and no stretch of the run longer than 36 s went without an
#     upload (what a TTL kill loses);
#   - the last upload's first tick is the stub's and precedes the preamble, its last tick is the
#     `final` one at or after the end phase, no gap between ticks exceeds 2.5 s, every phase
#     appears, and the header records nice -10 (rootful; rootless records what it got);
#   - scripts/lib/util.py sees the effects: burn's busy vCPU-s >= 0.8 x its seconds; shm's peak
#     used memory >= its start + 200 MiB and Shmem +250 MiB; net >= 64 MiB; starve with
#     mem_gap_s 0 (its largest tick gap is printed); alone, also burn <= 1.6 x its seconds, the
#     shm rise <= 330 MiB (Shmem <= 300 MiB) and net <= 80 MiB.
# Also: a sampler whose stub exits before exec (exit 97) stops with it, and a `once` tick after a
# loop that found no default route looks the interface up again. Prints the sampler's CPU per
# tick and the pusher's uploads. Record: results/rehearse/util-stream-<UTC>-<commit>.log.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
N=${1:-${N:-3}}
command -v podman >/dev/null || { echo "util-stream-test: need podman (docs/util.md)" >&2; exit 1; }
# Rootful when the machine has a root connection: an instance's root can renice the sampler to -10,
# and rootless podman cannot (a user namespace's CAP_SYS_NICE does not lower nice below 0). Without
# it the nice check records what the sampler got instead of requiring -10.
PODMAN=(podman)
ROOTFUL=0
CONN=$(podman system connection list --format '{{.Name}}' 2>/dev/null | grep -- '-root$' | head -1)
if [ -n "${AK2T_ROOTLESS:-}" ]; then CONN=""; fi
[ -n "$CONN" ] && { PODMAN=(podman --connection "$CONN"); ROOTFUL=1; }
BASE=public.ecr.aws/amazonlinux/amazonlinux:2023
IMG=localhost/ak2-util-test:al2023
SHA=$(git rev-parse --short=7 HEAD)
mkdir -p results/rehearse || exit 1
REC="results/rehearse/util-stream-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$REC") 2>&1
echo "util-stream-test: $N node(s) at $SHA ($(git diff --quiet HEAD -- scripts && echo clean || echo dirty)); shell flags $-; record $REC"
# Under $HOME: the podman machine shares it.
T=$(mktemp -d "$HOME/.ak2-util-stream.XXXXXX") || exit 1
SRV=""
cleanup() { [ -n "$SRV" ] && kill "$SRV" 2>/dev/null; "${PODMAN[@]}" rm -f $("${PODMAN[@]}" ps -aq --filter "name=ak2-util-$$-") >/dev/null 2>&1
  [ "${KEEP:-0}" = 1 ] && echo "util-stream-test: kept $T" || rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T/bin" "$T/bucket" "$T/www"

if ! "${PODMAN[@]}" image exists "$IMG"; then
  printf 'FROM %s\nRUN dnf install -y -q util-linux-core && dnf clean all\n' "$BASE" > "$T/Containerfile"
  "${PODMAN[@]}" build -q -t "$IMG" -f "$T/Containerfile" "$T" > /dev/null || { echo "util-stream-test: could not build $IMG" >&2; exit 1; }
fi
echo "util-stream-test: $([ $ROOTFUL = 1 ] && echo "rootful ($CONN)" || echo rootless) podman, image $IMG ($("${PODMAN[@]}" image inspect --format '{{.Id}}' "$IMG" | cut -c1-12), from $BASE)"

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
ak2_phase starve
bp=()
for _ in $(seq "$(nproc)"); do ( e=$((SECONDS + 15)); while [ "$SECONDS" -lt "$e" ]; do :; done ) & bp+=($!); done
wait "${bp[@]}"
ak2_phase hold
sleep 50
up=$(cat /tmp/ak2-util.pid)
read -r -a st < "/proc/$up/stat"
ak2_say "util-overhead pid $up utime ${st[13]} stime ${st[14]} ticks $(grep -c '^S' /tmp/ak2-util.tsv)"
ak2_req Test 1
EOF
{ cat scripts/preamble.sh; printf '\n'; cat "$T/body.sh"; } > "$T/payload.sh"
# Negative controls (docs/util.md): BREAK=nopush removes the pusher's util.tsv push (the record
# then reaches S3 only at exit), BREAK=nostub removes the stub's sampler start (the preamble's
# fallback starts it late). Each must make this test FAIL.
PUSHLINE='[ -s "$AK2_UTIL" ] && ak2_put "$AK2_UTIL" log/util.tsv; done )'
case ${BREAK:-} in
  "") ;;
  nopush)
    python3 -c 'import sys; p, a = sys.argv[1], sys.argv[2]; s = open(p).read(); assert a in s; open(p, "w").write(s.replace(a, "true; done )"))' \
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
      cp "${a[0]}" "/bucket/$k" && cp "${a[0]}" "/bucket/.v/$k.$(date +%s%N)"
      echo "$(date +%s) ${k##*/}" >> "/bucket/.calls.$AK2T_NODE" ;; *) exit 1 ;; esac ;;
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
OR=$("${PODMAN[@]}" run --rm -v "$T:/work:ro" "$IMG" bash /work/orphan.sh 2>&1); orc=$?
echo "util-stream-test: $([ $orc = 0 ] && echo 'ok  ' || echo FAIL) early stub exit: $OR"
[ $orc = 0 ] || RC=1
# A loop that started with no default route records iface "-" in its context file; a later
# `once` tick must look the interface up again, not read /sys/class/net/-/.
cat > "$T/iface.sh" <<'EOF'
printf -- '- -\n' > /tmp/ak2-util.ctx
bash /work/sampler.sh once phase
rx=$(awk -F'\t' '$1=="S"{print $18}' /tmp/ak2-util.tsv | tail -1)
case $rx in ''|*[!0-9]*) echo "once tick has no rx bytes ('$rx') after a '-' interface in the context"; exit 1 ;; esac
echo "once tick re-resolved the interface (rx $rx)"
EOF
OR=$("${PODMAN[@]}" run --rm -v "$T:/work:ro" "$IMG" bash /work/iface.sh 2>&1); orc=$?
echo "util-stream-test: $([ $orc = 0 ] && echo 'ok  ' || echo FAIL) interface re-resolved: $OR"
[ $orc = 0 ] || RC=1

# round NN LABEL ALONE: NN nodes at once; ALONE=1 adds the magnitude checks from above.
round() {
  local NN=$1 LABEL=$2 ALONE=$3 k rc T1 RUN P D V R NC MT BT
  local -a PIDS T0
  RUN="$(date -u +%Y%m%d-%H%M%S)-$SHA-util-$LABEL"
  echo "util-stream-test: round $LABEL: $NN node(s) at once$([ "$ALONE" = 1 ] && echo '; magnitudes checked from above')"
  for ((k = 0; k < NN; k++)); do
    P="s3://ak2-results-test/aws-kraken2/g9/$RUN-r$k"
    T0[$k]=$(date +%s)
    "${PODMAN[@]}" run --rm --name "ak2-util-$$-$LABEL-$k" --cap-add=SYS_NICE --shm-size=512m -v "$T:/work:ro" -v "$T/bucket:/bucket" \
      -e PATH=/work/bin:/usr/local/bin:/usr/bin:/bin -e AK2T_NODE="$LABEL-r$k" -e AK2T_PORT="$PORT" \
      -e AK2_EXPECT_REGION=us-west-2 -e AK2_BUCKETS=ak2-results-test -e AK2_ALLOWED_BUCKETS=ak2-results-test \
      -e AK2_S3_PREFIX="$P" -e AK2_RUN_ID="$RUN-r$k" -e AK2_GATE=g9 -e AK2_PAYLOAD_URI="$P/payload.sh" \
      -e AK2_PAYLOAD_URL="https://ak2-results-test.s3.us-west-2.amazonaws.com/aws-kraken2/g9/$RUN-r$k/payload.sh" \
      -e AK2_PAYLOAD_SHA256="$PSHA" "$IMG" bash -e -c "$(cat "$T/stub.sh")" > "$T/$LABEL-node$k.out" 2>&1 &
    PIDS[$k]=$!
  done
  for ((k = 0; k < NN; k++)); do
    wait "${PIDS[$k]}"; rc=$?
    T1=$(date +%s)
    echo "util-stream-test: $LABEL r$k container exit $rc"
    [ "$rc" = 0 ] || { RC=1; tail -20 "$T/$LABEL-node$k.out" | sed "s/^/  $LABEL r$k | /"; }
    D="$T/bucket/ak2-results-test/aws-kraken2/g9/$RUN-r$k"
    V="$T/bucket/.v/ak2-results-test/aws-kraken2/g9/$RUN-r$k/log"
    # A run dir as run.sh leaves it: the pushed log and util record, and a manifest whose billed
    # window runs from the VM kernel's btime (the container shares the podman VM's kernel, booted
    # long before) to the container's exit on the host's clock.
    R="$T/runs/g9/$RUN-r$k"; mkdir -p "$R/log"
    cp "$D/log/util.tsv" "$D/log/run.log" "$R/log/" 2>/dev/null
    NC=$(awk -F'\t' '$1=="H" && $2=="ncpu"{print $3}' "$R/log/util.tsv" 2>/dev/null)
    MT=$(awk -F'\t' '$1=="S"{print $15; exit}' "$R/log/util.tsv" 2>/dev/null)
    BT=$(awk -F'\t' '$1=="H" && $2=="btime"{print $3}' "$R/log/util.tsv" 2>/dev/null)
    jq -n --argjson l "${BT:-$((T0[$k] - 1))}" --argjson e "$((T1 + 1))" --argjson nc "${NC:-0}" --argjson mt "${MT:-0}" '{run_id:"test",
      region:"us-west-2", billed_seconds:($e - $l), cost_usd:1, instance:{type:"t.test", launch_time:($l | todate),
      terminated_at:($e | todate), type_info:{vcpus:$nc, memory_mib:(($mt / 1024) | floor), baseline_gbps:10, peak_gbps:10}}}' > "$R/manifest.json"
    python3 - "$R" "$V" "$LABEL r$k" "$ALONE" "$ROOTFUL" <<'PY' || RC=1
import csv, glob, os, re, sys
sys.path.insert(0, "scripts/lib")
import util
R, V, who, alone, rootful = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1", sys.argv[5] == "1"
bad = []
def need(cond, what):
    print(f"util-stream-test: {who} {'ok  ' if cond else 'FAIL'} {what}")
    if not cond:
        bad.append(what)
log = open(os.path.join(R, "log", "run.log")).read().splitlines() if os.path.exists(os.path.join(R, "log", "run.log")) else []
ph = {}
for l in log:
    p = l.split("\t")
    if p[0] == "ak2-phase" and len(p) >= 4:
        ph.setdefault(p[3], int(p[2]))
need("preamble" in ph and "end" in ph, f"run.log streamed with phases preamble..end ({sorted(ph)})")
m = re.search(r"as spawn started it: \$-=(\S+)\)", "\n".join(log))
need(bool(m) and "e" in m.group(1), f"the stub ran under errexit, as spawn starts it ($-={m.group(1) if m else '?'}), and the run went on")
vers = sorted(glob.glob(os.path.join(V, "util.tsv.*")), key=lambda f: int(f.rsplit(".", 1)[1]))
ticks = [sum(1 for l in open(f) if l.startswith("S\t")) for f in vers]
end = ph.get("end", 0)
during = [n for f, n in zip(vers, ticks) if int(f.rsplit(".", 1)[1]) / 1e9 < end]
need(len(during) >= 2, f"util.tsv uploaded {len(during)} time(s) before the end phase ({len(vers)} in all; ticks {ticks})")
need(all(b > a for a, b in zip(during, during[1:])), "each upload during the run has more ticks than the last")
# What a TTL kill would lose: the longest stretch of the run with no util.tsv upload.
ut = [int(f.rsplit(".", 1)[1]) / 1e9 for f in vers]
marks = [ph.get("preamble", 0)] + [t for t in ut if t < end] + [end]
loss = max(b - a for a, b in zip(marks, marks[1:]))
need(loss <= 36, f"longest run stretch without an upload {loss:.1f} s (a TTL kill loses at most that; pusher every 30 s)")
up = os.path.join(R, "log", "util.tsv")
need(os.path.exists(up) and os.path.getsize(up) > 0, "the last upload is non-empty")
if bad:
    sys.exit(1)
head, rows, eth, nbad = util.parse_util(up)
need(nbad == 0, f"no malformed lines ({nbad})")
need(rows[0]["phase"] == "stub" and int(rows[0]["t"]) <= ph["preamble"], f"first tick ({rows[0]['phase']}, {rows[0]['t']:.3f}) precedes the preamble ({ph['preamble']}): the stub started it")
need(rows[-1]["tag"] == "final" and rows[-1]["t"] >= end, f"last tick is final ({rows[-1]['tag']}) at/after the end phase")
if rootful:
    need(head.get("nice") == "-10", f"the sampler runs at nice {head.get('nice')} (want -10)")
else:
    need(head.get("nice") not in (None, "", "?"), f"the sampler recorded nice {head.get('nice')} (rootless podman cannot grant -10; recorded, not required)")
gaps = [b["t"] - a["t"] for a, b in zip(rows, rows[1:])]
need(max(gaps) <= 2.5, f"max gap between ticks {max(gaps):.2f} s")
seen = list(dict.fromkeys(r["phase"] for r in rows))
need(all(p in seen for p in ("stub", "preamble", "body", "burn", "shm", "net", "starve", "hold", "end")), f"phases in the ticks: {seen}")
need(len(rows) >= (rows[-1]["t"] - rows[0]["t"]) * 0.9, f"{len(rows)} ticks over {rows[-1]['t'] - rows[0]['t']:.1f} s (1 Hz)")
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    util.main([R])
tab = {(r["scope"], r["phase"]): r for r in csv.DictReader(open(os.path.join(R, "tables", "util.tsv")), delimiter="\t")}
b, s, n, st = (tab[("node-phase", x)] for x in ("burn", "shm", "net", "starve"))
bs, bsec = float(b["busy_vcpu_s"]), float(b["seconds"])
need(bs >= 0.8 * bsec and (not alone or bs <= 1.6 * bsec), f"burn: {bs} busy vCPU-s in {bsec} s (one vCPU burnt{'; alone: <= 1.6 x' if alone else ''})")
# The VM's other memory drifts, so the reference is shm's own boundary tick (taken by ak2_phase
# before the write); the table's peak must carry the rise too.
srows = [r for r in rows if r["phase"] == "shm"]
u0 = util.used_kib(srows[0]) / 1024
rise = float(s["mem_used_peak_gib"]) * 1024 - u0
shr = (max(r["shmem_kib"] for r in srows) - srows[0]["shmem_kib"]) / 1024
need(rise >= 200 and shr >= 250 and (not alone or (rise <= 330 and shr <= 300)),
     f"shm: used +{rise:.0f} MiB, Shmem +{shr:.0f} MiB at peak (256 MiB written to /dev/shm{'; alone: <= 330 / 300' if alone else ''})")
nb = float(n["net_bytes"])
need(nb >= 64 * 1048576 and (not alone or nb <= 80 * 1048576), f"net: {nb:.0f} bytes on {head.get('iface')} (64 MiB downloaded{'; alone: <= 80 MiB' if alone else ''})")
need(float(st["mem_gap_s"] or 0) == 0, f"starve: mem_gap_s {st['mem_gap_s']} s, largest tick gap {st['max_gap_s']} s, "
     f"{st['busy_vcpu_s']} busy vCPU-s in {st['seconds']} s ({head.get('ncpu')} CPUs, nproc loops un-niced; sampler nice {head.get('nice')})")
node = tab[("node", "(billed window)")]
print(f"util-stream-test: {who} node U_cpu {node['U_cpu']} U_mem {node['U_mem_mean']} (peak {node['U_mem_peak']}) "
      f"U_net {node['U_net_baseline']}; mem_gap_s {node['mem_gap_s']}; unobservable {node['unobs_launch_to_boot_s']}/{node['unobs_boot_to_sampler_s']}/{node['unobs_last_to_term_s']} s")
sys.exit(1 if bad else 0)
PY
    grep -h 'util-overhead' "$R/log/run.log" 2>/dev/null | sed 's/.*util-overhead/util-overhead/' |
      awk -v k="$LABEL r$k" '{printf "util-stream-test: %s sampler CPU %.2f s over %d ticks (%.2f ms per tick)\n", k, ($5+$7)/100, $9, ($5+$7)*10/$9}'
    # The pusher's uploads (each one an aws CLI process on an instance; the stub here costs nothing).
    awk -v k="$LABEL r$k" '{n[$2]++; if (!t0 || $1 < t0) t0 = $1; if ($1 > t1) t1 = $1}
      END {printf "util-stream-test: %s uploads over %d s:", k, t1 - t0; for (o in n) printf " %s x%d", o, n[o]; printf "\n"}' "$T/bucket/.calls.$LABEL-r$k"
  done
}

if [ "$N" -gt 1 ]; then
  round "$N" "n$N" 0
  round 1 alone 1
else
  round 1 alone 1
fi
[ "$RC" = 0 ] && echo "util-stream-test: ok ($N node(s)$([ "$N" -gt 1 ] && echo ', then 1 alone'))" || echo "util-stream-test: FAILED (KEEP=1 keeps the work dir)"
exit "$RC"
