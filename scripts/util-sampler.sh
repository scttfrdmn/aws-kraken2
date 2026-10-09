# aws-kraken2 utilisation sampler (docs/run.md, "Utilisation"; issue #25). Dependency-free bash:
# builtins only per tick (no fork; the wait is `read -t` on a private FIFO). scripts/lib/mkstub.sh
# splices this file into the user-data stub, which writes it to /tmp/ak2-util.sh and starts
# `loop` before anything else; the preamble's pusher streams $OUT to <run prefix>/log/util.tsv
# every 30 s, and ak2_finish stops the loop and appends one `once final` sample before the last push.
#   bash /tmp/ak2-util.sh loop PID header, ethtool at start, then one S record per second until
#                                  PID (the stub's shell, which execs the payload) is gone
#   bash /tmp/ak2-util.sh once TAG one S record tagged TAG (ak2_phase: `phase`, at each phase start,
#                                  so phase boundaries are exact; ak2_finish: `final`, then ethtool)
# Records (tab-separated, appended to $AK2_UTIL_OUT, default /tmp/ak2-util.tsv):
#   H key value   format, every, btime, clk_tck, ncpu, iface, cgroup, uptime_s, kernel, pid, started_at
#                 (a later `H iface` line: the default route appeared after the start)
#   S t phase tag user nice system idle iowait irq softirq steal guest guest_nice
#     mem_total_kib mem_avail_kib shmem_kib rx_bytes tx_bytes pgfault pgmajfault
#     cg_usage_usec cg_user_usec cg_system_usec
#   E t when name value   ethtool -S <iface> *_allowance_exceeded (when = start|end)
# t is the epoch in seconds (ms precision); cpu fields are /proc/stat's aggregate line (USER_HZ
# ticks since boot); rx/tx are the default-route interface's byte counters; cg_* is cpu.stat of
# the sampler's own cgroup (the task's: spored's service), empty if unreadable.
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
  # No default route yet: look again every tick; when found, record it for `once` and the header.
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
    printf '%s %s\n' "${IF:--}" "${CG:--}" > "$CTX"
    printf 'H\tformat\tak2-util-1\nH\tevery\t%s\nH\tbtime\t%s\nH\tclk_tck\t%s\nH\tncpu\t%s\nH\tiface\t%s\nH\tcgroup\t%s\nH\tuptime_s\t%s\nH\tkernel\t%s\nH\tpid\t%s\nH\tstarted_at\t%s\n' \
      "${AK2_UTIL_EVERY:-1}" "$BT" "${HZ:-100}" "$NC" "${IF:--}" "${CG:--}" "$UP" "$(uname -r 2>/dev/null)" "$BASHPID" "$START" >> "$OUT"
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
