#!/bin/bash
# The -M memory measurement behind 9126a6f (ladder O0 at c1, the engine env leak): in an AL2023
# aarch64 container, peak VmRSS / RssAnon / RssFile / RssShmem (from /proc/PID/status every 20 ms)
# of upstream classify at the pin with -M, ours (bin/aws-kraken2) with --memory-mapping at
# 8 / 32 / 96 threads, ours -M under a cohort node's engine env, and both without -M, on the
# viral DB staged to a tmpfs and SRR062634 (200,000 pairs). Mounts: /t (this script and ours,
# linux/arm64), /upsrc (upstream source at the pin), /db (k2_viral_20260626), /reads.
# Byte identity (Law 1) is make oracle's; this measures memory only.
set +e
echo "shell flags $-"
dnf -q -y install gcc-c++ make libgomp procps-ng > /dev/null 2>&1 || echo "dnf failed"
cp -r /upsrc /tmp/up && rm -f /tmp/up/src/*.o /tmp/up/src/classify && make -s -C /tmp/up/src classify > /tmp/up.log 2>&1 || { echo "upstream build failed"; tail -5 /tmp/up.log; }
UP=/tmp/up/src/classify
echo "upstream classify sha256 $(sha256sum $UP | cut -d' ' -f1)"
echo "ours sha256 $(sha256sum /t/aws-kraken2 | cut -d' ' -f1)"
echo "kernel $(uname -r); nproc $(nproc); $(grep MemTotal /proc/meminfo)"
mkdir -p /mnt/ram/db && cp /db/hash.k2d /db/taxo.k2d /db/opts.k2d /mnt/ram/db/
D=/mnt/ram/db
echo "$(stat -f -c %T /mnt/ram) $(ls -l $D/hash.k2d)"
R1=/reads/SRR062634_200000_1.fq; R2=/reads/SRR062634_200000_2.fq
peak() {  # LABEL CMD...: run CMD, sample /proc/PID/status every 20 ms, print peaks (kB)
  local label=$1; shift
  "$@" > /dev/null 2> /tmp/err.$$ & local pid=$!
  local a=0 f=0 s=0 r=0 x
  while kill -0 $pid 2> /dev/null; do
    x=$(awk '/^VmRSS/{r=$2} /^RssAnon/{a=$2} /^RssFile/{f=$2} /^RssShmem/{s=$2} END{print r, a, f, s}' /proc/$pid/status 2> /dev/null)
    set -- $x
    [ -n "$1" ] && { [ "$1" -gt $r ] && r=$1; [ "$2" -gt $a ] && a=$2; [ "$3" -gt $f ] && f=$3; [ "$4" -gt $s ] && s=$4; }
    sleep 0.02
  done
  wait $pid; local rc=$?
  [ $rc = 0 ] || head -3 /tmp/err.$$
  printf '%s\trc=%s\tVmRSS_kB=%d\tRssAnon_kB=%d\tRssFile_kB=%d\tRssShmem_kB=%d\n' "$label" "$rc" $r $a $f $s
}
echo "--- results (peak, kB)"
for T in 8 32 96; do
  peak "upstream -M T=$T" $UP -H $D/hash.k2d -t $D/taxo.k2d -o $D/opts.k2d -M -p $T -P -O /tmp/up.out -R /tmp/up.rep $R1 $R2
  peak "ours -M T=$T" /t/aws-kraken2 --db $D --memory-mapping --paired --threads $T --output /tmp/o1.out --report /tmp/o1.rep $R1 $R2
done
T=8
peak "ours -M T=8, node env (AK2_ENGINE_N=1 RANK=0 RENDEZVOUS)" env AK2_ENGINE_N=1 AK2_ENGINE_RANK=0 AK2_ENGINE_RENDEZVOUS=/tmp/rv AK2_ENGINE_LISTEN=127.0.0.1 /t/aws-kraken2 --db $D --memory-mapping --paired --threads $T --output /tmp/o2.out --report /tmp/o2.rep $R1 $R2
peak "upstream (no -M) T=8" $UP -H $D/hash.k2d -t $D/taxo.k2d -o $D/opts.k2d -p $T -P -O /tmp/up2.out -R /tmp/up2.rep $R1 $R2
peak "ours (no -M) T=8" /t/aws-kraken2 --db $D --paired --threads $T --output /tmp/o3.out --report /tmp/o3.rep $R1 $R2
