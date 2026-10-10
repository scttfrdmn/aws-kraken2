# aws-kraken2 user-data stub (scripts/run.sh puts this, not the preamble, in command[2]).
# EC2 caps user data at 16384 bytes after base64 decoding, and spawn's own bootstrap uses about
# 10.4 KB of that, already gzipped, so precompressing the payload gains nothing. The full payload
# (scripts/preamble.sh + the spec body) therefore travels via the run's in-region results
# prefix, uploaded by run.sh before launch and fetched here with a presigned URL for that one
# object (no IAM grant needed). This stub keeps Law 4's order: $- first, set +e, the region
# assert before any I/O, then one GET, a sha256 check, and exec. The sampler reads only /proc and
# /sys (and runs ethtool -S once), so it starts ahead of the assert.
AK2_STUB_FLAGS="$-"
set +e
# The utilisation sampler first, before any I/O (docs/run.md, "Utilisation"): run.sh splices
# scripts/util-sampler.sh in at the marker (scripts/lib/mkstub.sh); double-forked, so no shell's
# bare `wait` waits for it, with no inherited stdio.
cat > /tmp/ak2-util.sh <<'AK2UTIL'
set +e
OUT=${AK2_UTIL_OUT:-/tmp/ak2-util.tsv}
PHASEF=${AK2_UTIL_PHASE:-/tmp/ak2-state/phase}
CTX=${OUT%.tsv}.ctx
IF=""; CG=""; T=""
ak2u_now() { if [ -n "${EPOCHREALTIME:-}" ]; then T=${EPOCHREALTIME%???}; T=${T/,/.}; else T=$(date +%s); fi; }
ak2u_iface() {
  local i d r
  while read -r i d r; do [ "$d" = 00000000 ] && { IF=$i; return 0; }; done < /proc/net/route
  return 1
}
ak2u_cgroup() {
  local l
  while read -r l; do case $l in 0::*) CG=/sys/fs/cgroup${l#0::}; CG=${CG%/} ;; esac; done < /proc/self/cgroup
  [ -n "$CG" ] && [ -r "$CG/cpu.stat" ] || CG=""
}
ak2u_sample() {
  local k v r u n s id io irq sirq st g gn mt="" ma="" sh="" rx="" tx="" pf="" pmf="" cu="" cus="" css="" ph=stub
  read -r k u n s id io irq sirq st g gn r < /proc/stat
  while read -r k v r; do
    case $k in MemTotal:) mt=$v ;; MemAvailable:) ma=$v ;; Shmem:) sh=$v; break ;; esac
  done < /proc/meminfo
  while read -r k v; do case $k in pgfault) pf=$v ;; pgmajfault) pmf=$v; break ;; esac; done < /proc/vmstat
  [ -n "$IF" ] || { ak2u_iface && { printf '%s %s\n' "$IF" "${CG:--}" > "$CTX"; printf 'H\tiface\t%s\n' "$IF" >> "$OUT"; }; }
  if [ -n "$IF" ]; then
    read -r rx < "/sys/class/net/$IF/statistics/rx_bytes"; read -r tx < "/sys/class/net/$IF/statistics/tx_bytes"
  fi
  if [ -n "$CG" ]; then
    while read -r k v; do case $k in usage_usec) cu=$v ;; user_usec) cus=$v ;; system_usec) css=$v; break ;; esac; done < "$CG/cpu.stat"
  fi
  [ -r "$PHASEF" ] && { read -r ph < "$PHASEF"; ph=${ph:-stub}; }
  ak2u_now
  printf 'S\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$T" "$ph" "$1" "$u" "$n" "$s" "$id" "$io" "$irq" "$sirq" "$st" "${g:-0}" "${gn:-0}" \
    "$mt" "$ma" "$sh" "$rx" "$tx" "$pf" "$pmf" "$cu" "$cus" "$css" >> "$OUT"
}
ak2u_ethtool() {
  local e x k v n=0
  [ -n "$IF" ] || ak2u_iface || { ak2u_now; printf 'E\t%s\t%s\tnone\tno-default-route\n' "$T" "$1" >> "$OUT"; return; }
  for e in ethtool /usr/sbin/ethtool /sbin/ethtool; do command -v "$e" >/dev/null 2>&1 && break; e=""; done
  ak2u_now
  [ -n "$e" ] || { printf 'E\t%s\t%s\tnone\tno-ethtool\n' "$T" "$1" >> "$OUT"; return; }
  x=$("$e" -S "$IF" 2>/dev/null) || x=$(sudo -n "$e" -S "$IF" 2>/dev/null)
  while read -r k v; do
    case $k in *_allowance_exceeded:) printf 'E\t%s\t%s\t%s\t%s\n' "$T" "$1" "${k%:}" "$v" >> "$OUT"; n=$((n + 1)) ;; esac
  done <<< "$x"
  [ "$n" -gt 0 ] || printf 'E\t%s\t%s\tnone\tno-allowance-counters\n' "$T" "$1" >> "$OUT"
}
case ${1:-loop} in
  once)
    [ -r "$CTX" ] && read -r IF CG < "$CTX"
    [ "$IF" = - ] && IF=""
    [ "$CG" = - ] && CG=""
    [ -n "$CG" ] || ak2u_cgroup
    ak2u_sample "${2:-final}"; [ "${2:-final}" = final ] && ak2u_ethtool end ;;
  loop)
    trap '' HUP; trap 'exit 0' TERM INT
    ak2u_now; START=$T
    ak2u_iface; ak2u_cgroup
    BT=""; NC=0
    while read -r k v r; do case $k in btime) BT=$v ;; cpu[0-9]*) NC=$((NC + 1)) ;; esac; done < /proc/stat
    read -r UP r < /proc/uptime
    HZ=$(getconf CLK_TCK 2>/dev/null) || HZ=100
    renice -n -10 -p "$BASHPID" > /dev/null 2>&1 || sudo -n renice -n -10 -p "$BASHPID" > /dev/null 2>&1
    read -r -a PS < "/proc/$BASHPID/stat"
    printf '%s %s\n' "${IF:--}" "${CG:--}" > "$CTX"
    printf 'H\tformat\tak2-util-1\nH\tevery\t%s\nH\tbtime\t%s\nH\tclk_tck\t%s\nH\tncpu\t%s\nH\tiface\t%s\nH\tcgroup\t%s\nH\tuptime_s\t%s\nH\tkernel\t%s\nH\tpid\t%s\nH\tnice\t%s\nH\tstarted_at\t%s\n' \
      "${AK2_UTIL_EVERY:-1}" "$BT" "${HZ:-100}" "$NC" "${IF:--}" "${CG:--}" "$UP" "$(uname -r 2>/dev/null)" "$BASHPID" "${PS[18]:-?}" "$START" >> "$OUT"
    echo "$BASHPID" > "${OUT%.tsv}.pid"
    ak2u_ethtool start
    FIFO=${OUT%.tsv}.fifo; rm -f "$FIFO"; mkfifo "$FIFO" && exec 9<>"$FIFO"
    W=${2:-}
    while :; do
      [ -n "$W" ] && ! kill -0 "$W" 2>/dev/null && exit 0
      ak2u_sample tick
      read -r -t "${AK2_UTIL_EVERY:-1}" -u 9 _ 2>/dev/null || [ $? -gt 128 ] || sleep "${AK2_UTIL_EVERY:-1}"
    done ;;
esac
AK2UTIL
( bash /tmp/ak2-util.sh loop "$$" < /dev/null > /dev/null 2>&1 & )
echo "ak2-stub: inherited \$-=$AK2_STUB_FLAGS"
AK2_T=$(curl -sf -X PUT -m 5 http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
AK2_R=$(curl -sf -m 5 -H "X-aws-ec2-metadata-token: $AK2_T" http://169.254.169.254/latest/meta-data/placement/region)
AK2_PB=${AK2_PAYLOAD_URI#s3://}; AK2_PB=${AK2_PB%%/*}
AK2_PBR=$(curl -sI -m 10 "https://$AK2_PB.s3.$AK2_R.amazonaws.com/" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-amz-bucket-region"{print $2}')
echo "ak2-stub: imds region=$AK2_R expected=$AK2_EXPECT_REGION payload bucket $AK2_PB region=$AK2_PBR"
if [ -z "$AK2_R" ] || [ "$AK2_R" != "$AK2_EXPECT_REGION" ] || [ "$AK2_PBR" != "$AK2_R" ]; then
  echo "ak2-stub: FATAL: region assert failed before any I/O"; exit 97
fi
case "$AK2_PAYLOAD_URL" in
  "https://$AK2_PB.s3.$AK2_R.amazonaws.com/"*) ;;
  *) echo "ak2-stub: FATAL: payload URL is not the in-region endpoint of $AK2_PB"; exit 97 ;;
esac
curl -sf -m 60 --retry 3 -o /tmp/ak2-payload.sh "$AK2_PAYLOAD_URL" ||
  { echo "ak2-stub: FATAL: could not fetch $AK2_PAYLOAD_URI"; exit 97; }
AK2_SUM=$(sha256sum /tmp/ak2-payload.sh | cut -d' ' -f1)
[ "$AK2_SUM" = "$AK2_PAYLOAD_SHA256" ] ||
  { echo "ak2-stub: FATAL: payload sha256 $AK2_SUM != $AK2_PAYLOAD_SHA256"; exit 97; }
echo "ak2-stub: payload verified (sha256 $AK2_SUM); exec"
export AK2_STUB_FLAGS
unset AK2_PAYLOAD_URL   # a credential for one object; the payload has no use for it
# bash -c, exactly as spawn ran the inlined script before (same parsing, same $- semantics).
exec bash -c "$(cat /tmp/ak2-payload.sh)"
