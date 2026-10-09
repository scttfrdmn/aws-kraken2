#!/usr/bin/env bash
# make hosttune-test (docs/probes.md, "Host tunes"): scripts/g3/hosttune.sh on an Amazon Linux 2023
# container (podman; rootful when the machine has a root connection), whose /proc and /sys are the
# kernel's, as on an instance. Run under `bash -e -c` with `set +e` first, as a spec body runs.
# Stand-ins only at the edges: sudo and tee on PATH log every call and then run it; ak2_push keeps
# every upload as its own timestamped version. Fails unless:
#   real kernel
#   - ht_apply none returns 0, makes no write (HT_WRITES 0, no sudo and no tee call), every apply
#     row is "kept", and every knob (THP enabled, defrag, shmem_enabled, compaction_proactiveness,
#     read_ahead_kb of every block device) reads the same before and after;
#   - ht_record streams: after each of 3 calls, hosttune.jsonl and hosttune.txt have been pushed
#     once more, the k-th jsonl upload has k lines, each txt upload is longer than the one before,
#     and the record carries the kernel's buddyinfo zones, compact_* and thp_* vmstat lines and
#     the THP settings, and a numeric free_huge_frac;
#   - a set the container cannot write (defer: /sys is read-only here) returns non-zero with
#     HT_APPLIED false and a "failed" row, and the knobs still read as before (a failed set is
#     loud, not silent);
#   fake tree (HT_ROOT)
#   - ht_apply none leaves every file's content and mtime unchanged;
#   - an inline set (defrag, proactiveness, read_ahead_kb) and precompact are written and recorded
#     with before and after, HT_PRECOMPACT_S is a number, and ht_restore brings every knob back to
#     its baseline.
# Record: results/rehearse/hosttune-test-<UTC>-<commit>.log.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 1
command -v podman >/dev/null || { echo "hosttune-test: need podman" >&2; exit 1; }
PODMAN=(podman)
CONN=$(podman system connection list --format '{{.Name}}' 2>/dev/null | grep -- '-root$' | head -1)
[ -n "${AK2T_ROOTLESS:-}" ] && CONN=""
[ -n "$CONN" ] && PODMAN=(podman --connection "$CONN")
IMG=public.ecr.aws/amazonlinux/amazonlinux:2023
SHA=$(git rev-parse --short=7 HEAD)
mkdir -p results/rehearse || exit 1
REC="results/rehearse/hosttune-test-$(date -u +%Y%m%dT%H%M%SZ)-$SHA.log"
exec > >(tee "$REC") 2>&1
echo "hosttune-test: at $SHA ($(git diff --quiet HEAD -- scripts && echo clean || echo dirty)); shell flags $-; record $REC"
T=$(mktemp -d "$HOME/.ak2-hosttune-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cp scripts/g3/hosttune.sh "$T/hosttune.sh" || exit 1
cat > "$T/bin/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> /tmp/calls.log
[ "$1" = -n ] && shift
exec "$@"
EOF
cat > "$T/bin/tee" <<'EOF'
#!/bin/bash
echo "tee $*" >> /tmp/calls.log
exec /usr/bin/tee "$@"
EOF
chmod +x "$T/bin"/*
cat > "$T/inner.sh" <<'EOF'
set +e
echo "inner: shell flags $- (errexit off, as a body after the preamble)"
export PATH=/work/bin:$PATH
: > /tmp/calls.log
RC=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; RC=1; }
ak2_say() { echo "ak2: $*"; }
ak2_push() { local n=${2:-$(basename "$1")}; mkdir -p /tmp/bucket; cp "$1" "/tmp/bucket/$n.$(date +%s%N)"; }
same() { [ "$(cat "$1")" = "$(cat "$2")" ]; }  # the image has no cmp, diff or find
dif() { paste -d'|' "$1" "$2" | awk -F'|' '$1 != $2' | head -4 | tr '\n' ' '; }
vers() { ls /tmp/bucket/"$1".* 2>/dev/null | sort; }
snap() {
  local f
  for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag \
    /sys/kernel/mm/transparent_hugepage/shmem_enabled /proc/sys/vm/compaction_proactiveness /sys/block/*/queue/read_ahead_kb; do
    printf '%s=%s\n' "$f" "$(cat "$f" 2>/dev/null || echo absent)"
  done
}
DEVS=$(ls /sys/block 2>/dev/null | tr '\n' ' ')
echo "inner: kernel $(uname -r); block devices: ${DEVS:-none}"
snap > /tmp/s0; sed 's/^/  boot: /' /tmp/s0
HT_ROOT="" HT_DIR=/tmp/ht HT_BLOCKDEVS=$DEVS
. /work/hosttune.sh

# 1. none on the real kernel.
ht_apply none; r=$?
snap > /tmp/s1
nk=$(awk -F'\t' 'NR > 1 && $3 == "none" && $8 != "kept"' /tmp/ht/apply.tsv | wc -l)
nr=$(awk -F'\t' 'NR > 1 && $3 == "none"' /tmp/ht/apply.tsv | wc -l)
calls=$(wc -l < /tmp/calls.log)
if [ "$r" = 0 ] && [ "$HT_WRITES" = 0 ] && [ "$calls" = 0 ] && [ "$nr" -ge 3 ] && [ "$nk" = 0 ] && same /tmp/s0 /tmp/s1; then
  ok "ht_apply none: rc 0, 0 writes, 0 sudo/tee calls, $nr rows all kept, every knob unchanged"
else
  bad "ht_apply none: rc $r, writes $HT_WRITES, calls $calls, rows $nr ($nk not kept); diff: $(dif /tmp/s0 /tmp/s1)"
fi

# 2. ht_record streams, on the kernel's own state.
for k in 1 2 3; do
  ht_record "r$k" > /tmp/rec.out; r=$?
  nj=$(vers hosttune.jsonl | wc -l); nt=$(vers hosttune.txt | wc -l)
  lj=$(wc -l < "$(vers hosttune.jsonl | tail -1)"); st=$(wc -c < "$(vers hosttune.txt | tail -1)")
  if [ "$r" = 0 ] && [ "$nj" = "$k" ] && [ "$nt" = "$k" ] && [ "$lj" = "$k" ] && [ "$st" -gt "${prev:-0}" ]; then
    ok "ht_record r$k: pushed at once (jsonl upload $nj with $lj lines, txt upload $nt of $st bytes)"
  else
    bad "ht_record r$k: rc $r, jsonl uploads $nj ($lj lines), txt uploads $nt ($st bytes, previous ${prev:-0})"
  fi
  prev=$st
  sleep 1
done
last=$(vers hosttune.txt | tail -1)
zb=$(grep -c 'zone' "$last"); zk=$(grep -c 'zone' /proc/buddyinfo)
vc=$(grep -c '^compact_' "$last"); vt=$(grep -c '^thp_' "$last")
kc=$(grep -c '^compact_' /proc/vmstat); kt=$(grep -c '^thp_' /proc/vmstat)
th=$(grep -c '^-- thp enabled=' "$last")
fh=$(tail -1 "$(vers hosttune.jsonl | tail -1)" | sed -n 's/.*"free_huge_frac":\([0-9.]*\).*/\1/p')
if [ "$zb" = $((3 * zk)) ] && [ "$vc" = $((3 * kc)) ] && [ "$vt" = $((3 * kt)) ] && [ "$kt" -gt 0 ] && [ "$th" = 3 ] && [ -n "$fh" ]; then
  ok "ht_record content: $zk buddyinfo zones, $kc compact_ and $kt thp_ lines and the THP settings per record; free_huge_frac $fh"
else
  bad "ht_record content: zones $zb (want $((3 * zk))), compact_ $vc (want $((3 * kc))), thp_ $vt (want $((3 * kt))), settings $th, free_huge_frac '$fh'"
fi
tail -1 /tmp/rec.out | cut -c1-240 | sed 's/^/  /'

# 3. A set the container cannot write fails loudly and changes nothing.
: > /tmp/calls.log
ht_apply defer; r=$?
snap > /tmp/s2
fr=$(awk -F'\t' -v s="$HT_SEQ" '$1 == s && $4 == "defrag" {print $8}' /tmp/ht/apply.tsv)
if [ "$r" != 0 ] && [ "$HT_APPLIED" = false ] && [ "$fr" = failed ] && same /tmp/s0 /tmp/s2; then
  ok "ht_apply defer on a read-only /sys: rc $r, applied false, defrag row $fr, knobs unchanged ($(wc -l < /tmp/calls.log) sudo/tee calls tried)"
else
  bad "ht_apply defer on a read-only /sys: rc $r, applied $HT_APPLIED, defrag row '$fr'; diff: $(dif /tmp/s0 /tmp/s2)"
fi
ht_restore > /dev/null; r=$?
[ "$r" = 0 ] && ok "ht_restore after it: rc 0 (nothing differs from boot)" || bad "ht_restore after it: rc $r"

# 4. A fake tree: none touches nothing; a set and precompact write and are restored.
F=/tmp/fake
mkdir -p $F/sys/kernel/mm/transparent_hugepage $F/proc/sys/vm $F/sys/block/xvda/queue
echo 'always [madvise] never' > $F/sys/kernel/mm/transparent_hugepage/enabled
echo 'always defer defer+madvise [madvise] never' > $F/sys/kernel/mm/transparent_hugepage/defrag
echo 20 > $F/proc/sys/vm/compaction_proactiveness; : > $F/proc/sys/vm/compact_memory
echo 128 > $F/sys/block/xvda/queue/read_ahead_kb
cp /proc/buddyinfo /proc/vmstat /proc/meminfo $F/proc/
FF="$F/sys/kernel/mm/transparent_hugepage/enabled $F/sys/kernel/mm/transparent_hugepage/defrag
  $F/proc/sys/vm/compaction_proactiveness $F/proc/sys/vm/compact_memory $F/sys/block/xvda/queue/read_ahead_kb
  $F/proc/buddyinfo $F/proc/vmstat $F/proc/meminfo"
touch -d '2020-01-01 00:00:00' $FF
tree() { local x; for x in $FF; do printf '%s %s\n' "$(stat -c '%n %.9Y %s' "$x")" "$(md5sum < "$x")"; done; }
tree > /tmp/f0
HT_ROOT=$F HT_DIR=/tmp/htf HT_BLOCKDEVS=xvda
ht_apply none; r=$?
tree > /tmp/f1
if [ "$r" = 0 ] && [ "$HT_WRITES" = 0 ] && same /tmp/f0 /tmp/f1; then ok "fake tree: ht_apply none left every file's content and mtime as it was"
else bad "fake tree: ht_apply none rc $r writes $HT_WRITES; $(dif /tmp/f0 /tmp/f1)"; fi
ht_apply "defrag=defer,proactiveness=100,ra=4096,precompact=1"; r=$?
got="$(ht__read defrag) $(ht__read proactiveness) $(ht__read ra:xvda) $(cat $F/proc/sys/vm/compact_memory)"
rows=$(awk -F'\t' -v s="$HT_SEQ" '$1 == s && $8 == "set"' /tmp/htf/apply.tsv | wc -l)
pre=$(awk -F'\t' -v s="$HT_SEQ" '$1 == s && $4 == "precompact" {print $8}' /tmp/htf/apply.tsv)
if [ "$r" = 0 ] && [ "$got" = "defer 100 4096 1" ] && [ "$rows" = 3 ] && [ "$pre" = done ] && [[ "$HT_PRECOMPACT_S" =~ ^[0-9]+\.[0-9]+$ ]]; then
  ok "fake tree: inline set applied ($got), 3 rows set with before and after, precompact done in ${HT_PRECOMPACT_S}s"
else
  bad "fake tree: inline set rc $r, got '$got', $rows rows set, precompact '$pre' (${HT_PRECOMPACT_S:-})"
fi
ht_restore; r=$?
got="$(ht__read enabled) $(ht__read defrag) $(ht__read proactiveness) $(ht__read ra:xvda)"
[ "$r" = 0 ] && [ "$got" = "madvise madvise 20 128" ] && ok "fake tree: ht_restore back to the baseline ($got)" || bad "fake tree: ht_restore rc $r, got '$got'"
exit "$RC"
EOF
"${PODMAN[@]}" run --rm -v "$T:/work:ro" "$IMG" bash -e -c "$(cat "$T/inner.sh")"
RC=$?
echo "hosttune-test: container ($([ -n "$CONN" ] && echo "rootful, $CONN" || echo rootless); $IMG) exit $RC"
[ "$RC" = 0 ] && echo "hosttune-test: ok" || echo "hosttune-test: FAILED" >&2
exit "$RC"
