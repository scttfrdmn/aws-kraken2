# Sourced by the runs/g2-*.json spec bodies after the clone (docs/g2.md). Instance setup for
# make g2 on AWS: toolchain and instruments, instance-store NVMe (RAID0 over every device),
# RODA v205 staged and checked against its ETag, the reads staged and checked against their
# sha256, read subsets derived, upstream and kraken2-madvrandom built. Every function logs what
# it did; a failure calls g2i_fail (the spec body's exit). Uses the preamble helpers
# (ak2_say, ak2_stage, ak2_req, ak2_push).
# shellcheck shell=bash

g2i_fail() { ak2_say "ERROR: $*"; exit 1; }

# g2i_setup: packages, perf access, the perf event list (G2_PERF_EVENTS), host facts.
g2i_setup() {
  sudo -n dnf install -y -q git gcc-c++ make zlib-devel perl jq bzip2 gzip tar findutils diffutils \
    python3 perf sysstat xfsprogs mdadm numactl util-linux > "$W/dnf.log" 2>&1 ||
    { tail -20 "$W/dnf.log"; g2i_fail "dnf install failed"; }
  sudo -n sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0 || g2i_fail "sysctl perf failed"
  local tf
  for tf in /sys/kernel/tracing /sys/kernel/debug/tracing; do
    [ -d "$tf" ] && sudo -n chmod -R a+rX "$tf/events/syscalls/sys_enter_futex" "$tf/events/syscalls" 2>/dev/null
    [ -d "$tf" ] && sudo -n chmod a+rx "$tf" "$tf/events" 2>/dev/null
  done
  sudo -n chmod a+rx /sys/kernel/debug 2>/dev/null
  local want="task-clock context-switches cpu-migrations page-faults major-faults minor-faults cycles instructions dTLB-loads dTLB-load-misses dtlb_walk stall_backend syscalls:sys_enter_futex"
  local ev ok=""
  for ev in $want; do
    if perf stat -x, -e "$ev" -o "$W/perf-probe.txt" -- true >/dev/null 2>&1 &&
       ! grep -q "not supported\|not counted" "$W/perf-probe.txt"; then ok="$ok,$ev"; fi
  done
  G2_PERF_EVENTS=${ok#,}
  export G2_PERF_EVENTS
  ak2_say "perf $(perf --version 2>&1 | head -1); events usable: $G2_PERF_EVENTS"
  ak2_say "host: $(nproc) CPUs; $(awk '/MemTotal/{print $2" kB"}' /proc/meminfo); kernel $(uname -r)"
  ak2_say "thp enabled=[$(cat /sys/kernel/mm/transparent_hugepage/enabled)] defrag=[$(cat /sys/kernel/mm/transparent_hugepage/defrag)] shmem_enabled=[$(cat /sys/kernel/mm/transparent_hugepage/shmem_enabled 2>/dev/null)]"
  ak2_say "lscpu: $(lscpu | grep -E 'Model name|Socket|NUMA node\(s\)|Core\(s\) per' | tr -s ' ' | tr '\n' ';')"
  ak2_say "numa: $(numactl -H 2>/dev/null | grep -E 'available|size' | tr '\n' ';')"
  ak2_say "disks: $(lsblk -dno NAME,SIZE,MODEL,SERIAL 2>/dev/null | tr '\n' ';')"
  # One cheap rate measurement for the gzip candidate: a single gzip -dc stream, CPU-bound.
  G2_HOST_FACTS="$W/host.txt"
  { lscpu; echo; numactl -H 2>/dev/null; echo; cat /proc/meminfo; echo; lsblk -o NAME,SIZE,MODEL,SERIAL,TYPE,MOUNTPOINT; } > "$G2_HOST_FACTS" 2>&1
  ak2_push "$G2_HOST_FACTS" host.txt >/dev/null
}

# g2i_nvme: format all instance-store NVMe devices as one xfs (RAID0 when there are several),
# mounted at /mnt/nvme (1777). Sets G2_NVME, G2_DEVS (array + members) and G2_STORAGE.
g2i_nvme() {
  local -a NV
  mapfile -t NV < <(lsblk -dpno NAME,MODEL | awk '/Instance Storage/{print $1}')
  [ "${#NV[@]}" -gt 0 ] || g2i_fail "no instance-store NVMe device"
  local dev members="" d
  for d in "${NV[@]}"; do members="$members,${d#/dev/}"; done
  members=${members#,}
  if [ "${#NV[@]}" -gt 1 ]; then
    sudo -n mdadm --create /dev/md0 --run --level=0 --chunk=512 --raid-devices="${#NV[@]}" "${NV[@]}" \
      > "$W/mdadm.log" 2>&1 || { cat "$W/mdadm.log"; g2i_fail "mdadm --create failed"; }
    dev=/dev/md0; G2_DEVS="md0,$members"
  else
    dev=${NV[0]}; G2_DEVS=$members
  fi
  sudo -n mkfs.xfs -f -q "$dev" || g2i_fail "mkfs.xfs $dev failed"
  sudo -n mkdir -p /mnt/nvme && sudo -n mount -o noatime "$dev" /mnt/nvme || g2i_fail "mount $dev failed"
  sudo -n chmod 1777 /mnt/nvme || g2i_fail "chmod /mnt/nvme failed"
  G2_NVME=/mnt/nvme
  local ra="" sch=""
  for d in ${G2_DEVS//,/ }; do
    ra="$ra $d=$(cat /sys/block/$d/queue/read_ahead_kb 2>/dev/null)KiB"
    sch="$sch $d=$(cat /sys/block/$d/queue/scheduler 2>/dev/null | tr -d ' ')"
  done
  G2_STORAGE="instance-store NVMe ${#NV[@]}x ($(lsblk -dno SIZE,MODEL "${NV[0]}" | tr -s ' ')) $( [ "${#NV[@]}" -gt 1 ] && echo "mdadm RAID0 chunk 512K as md0;") xfs noatime at /mnt/nvme; read_ahead_kb:$ra; scheduler:$sch"
  export G2_DEVS G2_STORAGE G2_NVME
  ak2_say "storage: $G2_STORAGE"
}

# g2i_awscfg: the CRT transfer client for the big object (the preamble's aws shim still applies).
g2i_awscfg() {
  printf '[default]\ns3 =\n  preferred_transfer_client = crt\n  target_bandwidth = %s\n  multipart_chunksize = 64MB\n' \
    "${1:-50Gb/s}" > "$W/aws-config"
  export AWS_CONFIG_FILE="$W/aws-config"
  ak2_say "aws: $(aws --version 2>&1); s3 transfer client crt, target_bandwidth ${1:-50Gb/s}, 64 MB parts"
}

# g2i_stage_roda DIR [FILE...]: RODA v205 files (default opts.k2d taxo.k2d hash.k2d) into DIR;
# each file's local ETag must equal the object's ETag (head-object now; the launch manifest
# recorded the same object). Sets G2_HASH_ETAG.
g2i_stage_roda() {
  local dst=$1 rb=kraken2-ncbi-refseq-complete-v205 rp=Kraken2_RefSeqCompleteV205 f t0 t1 et sz j
  shift
  [ $# -gt 0 ] || set -- opts.k2d taxo.k2d hash.k2d
  mkdir -p "$dst" || g2i_fail "mkdir $dst"
  for f in "$@"; do
    et=$(aws s3api head-object --no-sign-request --bucket "$rb" --key "$rp/$f" --query ETag --output text | tr -d '"')
    ak2_req HeadObject 1 "$rb"
    t0=$(date +%s.%N)
    aws s3 cp --only-show-errors --no-sign-request "s3://$rb/$rp/$f" "$dst/$f" || g2i_fail "stage of $f failed"
    t1=$(date +%s.%N)
    sz=$(stat -c%s "$dst/$f")
    ak2_req GetObject $(( (sz + 67108863) / 67108864 )) "$rb"
    ak2_say "staged $f bytes=$sz in $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') s ($(awk -v a="$t0" -v b="$t1" -v s="$sz" 'BEGIN{printf "%.3f", s/(b-a)/1e9}') GB/s)"
    j=$(python3 scripts/lib/etagcheck.py "$dst/$f" "$et") || { echo "$j"; g2i_fail "$f does not match ETag $et"; }
    ak2_say "etag $f: $j"
    echo "$f $et $j" >> "$dst/SOURCE"
    [ "$f" = hash.k2d ] && G2_HASH_ETAG=$et
  done
  ak2_push "$dst/SOURCE" roda-v205-SOURCE >/dev/null
}

# g2i_stage_reads DIR B DATA STEM...: STEM_{1,2}.fq, .fq.gz and STEM.SOURCE from the declared
# reads prefix; sha256 metadata and SOURCE checked.
g2i_stage_reads() {
  local rd=$1 b=$2 data=$3 stem f s want got m h
  shift 3
  mkdir -p "$rd" || g2i_fail "mkdir $rd"
  for stem in "$@"; do
    for f in "$stem.SOURCE" "${stem}_1.fq" "${stem}_2.fq" "${stem}_1.fq.gz" "${stem}_2.fq.gz"; do
      ak2_stage "s3://$b/$data/reads/$f" "$rd/$f" || g2i_fail "stage of reads/$f failed"
      s=$(stat -c%s "$rd/$f")
      ak2_req GetObject $(( s < 8388608 ? 1 : (s + 8388607) / 8388608 )) "$b"
      want=$(aws s3api head-object --bucket "$b" --key "$data/reads/$f" --query Metadata.sha256 --output text)
      ak2_req HeadObject 1 "$b"
      got=$(sha256sum "$rd/$f" | cut -d' ' -f1)
      [ "$got" = "$want" ] || g2i_fail "reads/$f sha256 $got != metadata $want"
    done
    for m in 1 2; do
      h=$(sha256sum "$rd/${stem}_$m.fq" | cut -d' ' -f1)
      grep -qx "sha256 $h ${stem}_$m.fq" "$rd/$stem.SOURCE" || g2i_fail "${stem}_$m.fq does not match $stem.SOURCE"
      h=$(gzip -dc "$rd/${stem}_$m.fq.gz" | sha256sum | cut -d' ' -f1)
      grep -qx "sha256 $h ${stem}_$m.fq" "$rd/$stem.SOURCE" || g2i_fail "${stem}_$m.fq.gz does not decompress to its SOURCE fq"
    done
    ak2_say "reads $stem verified against SOURCE"
  done
}

# g2i_subset DIR STEM N NEWSTEM: the first N pairs of STEM (a prefix of the same real sample),
# plain and gzip -6 -n, with a SOURCE naming the derivation and the sha256s.
g2i_subset() {
  local rd=$1 stem=$2 n=$3 ns=$4 m
  for m in 1 2; do
    head -n $((4 * n)) "$rd/${stem}_$m.fq" > "$rd/${ns}_$m.fq" || g2i_fail "subset $ns failed"
    [ "$(wc -l < "$rd/${ns}_$m.fq")" = $((4 * n)) ] || g2i_fail "subset ${ns}_$m: short"
  done
  gzip -6 -n -c "$rd/${ns}_1.fq" > "$rd/${ns}_1.fq.gz" & local p1=$!
  gzip -6 -n -c "$rd/${ns}_2.fq" > "$rd/${ns}_2.fq.gz" & local p2=$!
  wait $p1 || g2i_fail "gzip ${ns}_1 failed"
  wait $p2 || g2i_fail "gzip ${ns}_2 failed"
  { echo "derived_from $stem (first $n records per mate, head -n $((4 * n)); gzip -6 -n)"
    for m in 1 2; do echo "sha256 $(sha256sum "$rd/${ns}_$m.fq" | cut -d' ' -f1) ${ns}_$m.fq"; done
    for m in 1 2; do echo "sha256 $(sha256sum "$rd/${ns}_$m.fq.gz" | cut -d' ' -f1) ${ns}_$m.fq.gz"; done
  } > "$rd/$ns.SOURCE"
  ak2_say "subset $ns: $(tr '\n' ';' < "$rd/$ns.SOURCE")"
}

# g2i_stage_ours DIR B DATA NAME: one of our in-region database copies (make stage-db), every
# file checked against its sha256 metadata (smoke tests only; the measurements use RODA v205).
g2i_stage_ours() {
  local dst=$1 b=$2 data=$3 name=$4 f s want got
  mkdir -p "$dst" || g2i_fail "mkdir $dst"
  ak2_stage "s3://$b/$data/$name/" "$dst/" || g2i_fail "stage of $name failed"
  ak2_req ListObjectsV2 1 "$b"
  for f in hash.k2d opts.k2d taxo.k2d; do
    s=$(stat -c%s "$dst/$f")
    ak2_req GetObject $(( s < 8388608 ? 1 : (s + 8388607) / 8388608 )) "$b"
    want=$(aws s3api head-object --bucket "$b" --key "$data/$name/$f" --query Metadata.sha256 --output text)
    ak2_req HeadObject 1 "$b"
    got=$(sha256sum "$dst/$f" | cut -d' ' -f1)
    [ "$got" = "$want" ] || g2i_fail "$name/$f sha256 $got != metadata $want"
  done
  ak2_say "db $name verified against sha256 metadata"
}

# g2i_build: upstream at the pin (pristine) and kraken2-madvrandom (diagnostic), into
# G2_UPSTREAM and G2_MADV.
g2i_build() {
  G2_UPSTREAM=$(scripts/oracle-build.sh 2> "$W/oracle-build.err") || { tail -30 "$W/oracle-build.err"; g2i_fail "oracle-build failed"; }
  G2_MADV=$(scripts/madvrandom-build.sh 2> "$W/madv-build.err") || { tail -30 "$W/madv-build.err"; g2i_fail "madvrandom-build failed"; }
  export G2_UPSTREAM G2_MADV
  ak2_say "upstream: $(tr '\n' ';' < "$G2_UPSTREAM/BUILD")"
  ak2_say "madvrandom (diagnostic): $(tr '\n' ';' < "$G2_MADV/BUILD")"
}

# g2i_gzip_rate FILE: one gzip -dc stream's rate (the wrapper's decompressor), for the gzip
# candidate's resolution: gzip can bind only where classify consumes faster than this.
g2i_gzip_rate() {
  local t0 t1 n
  t0=$(date +%s.%N); n=$(gzip -dc "$1" | wc -c); t1=$(date +%s.%N)
  ak2_say "gzip -dc rate: $1 -> $n bytes in $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}') s ($(awk -v a="$t0" -v b="$t1" -v s="$n" 'BEGIN{printf "%.1f", s/(b-a)/1e6}') MB/s plain out)"
}

# g2i_ramdb SRC DST SIZE: the database copied onto a tmpfs mounted with huge=always (shmem THP),
# for the ram regime (table resident in RAM, -M on the tmpfs copy).
g2i_ramdb() {
  local src=$1 dst=$2 size=$3 etag=$4 t0 t1 j
  sudo -n mkdir -p "$dst" && sudo -n mount -t tmpfs -o "size=$size,huge=always,mode=1777" tmpfs "$dst" ||
    g2i_fail "tmpfs mount at $dst failed"
  t0=$(date +%s.%N)
  cp "$src/opts.k2d" "$src/taxo.k2d" "$src/hash.k2d" "$dst/" || g2i_fail "copy to tmpfs failed"
  t1=$(date +%s.%N)
  cmp -s "$src/opts.k2d" "$dst/opts.k2d" && [ "$(stat -c%s "$src/hash.k2d")" = "$(stat -c%s "$dst/hash.k2d")" ] ||
    g2i_fail "tmpfs copy differs"
  j=$(python3 scripts/lib/etagcheck.py "$dst/hash.k2d" "$etag") || { echo "$j"; g2i_fail "tmpfs hash.k2d does not match ETag $etag"; }
  ak2_say "etag tmpfs hash.k2d: $j"
  ak2_say "ramdb: $dst ($(df -h "$dst" | tail -1 | tr -s ' ')); copy $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') s; ShmemHugePages $(awk '/ShmemHugePages/{print $2" kB"}' /proc/meminfo)"
}
