#!/usr/bin/env bash
# The upstream arm of a cohort (#25, Law 2): upstream kraken2 at the pin over the same samples,
# from the same cohort manifest the engine runs (AK2_COHORT format, cmd/aws-kraken2/cohort.go;
# docs/cohort.md). Upstream at its best for a cohort has the table resident once: `ramdb` copies
# the database onto a tmpfs mounted huge=always (G2's ram regime, scripts/g2-instance.sh
# g2i_ramdb), and the caller passes --db <tmpfs> --memory-mapping in the common arguments, so no
# sample reloads it.
#
#   scripts/upstream-cohort.sh ramdb SRC NAME SIZE
#       mount a huge=always tmpfs of SIZE at /mnt/ak2-ramdb/NAME (sudo; NAME a plain word; the
#       mount is owned by the invoking user, mode 0700) and copy SRC's opts.k2d, taxo.k2d and
#       hash.k2d onto it; checks the copy's sizes; prints the mount point and the copy seconds.
#       Refuses a mount point that exists already (a mounted or leftover directory).
#   scripts/upstream-cohort.sh umount NAME
#       unmount /mnt/ak2-ramdb/NAME and remove the directory (sudo).
#   scripts/upstream-cohort.sh run KRAKEN2 MANIFEST OUT.jsonl [common arguments...]
#       run every sample of MANIFEST in order, one upstream invocation each:
#       KRAKEN2 <common arguments> <the sample's arguments>. The batch, inflight, mode and client
#       columns are the engine's and are ignored here (upstream runs one sample at a time).
#       Outputs must be local paths. Appends one JSON line per sample to OUT.jsonl: name, batch,
#       exit, wall_s, classify_s (upstream's "processed in"), and the sha256 of every output file
#       the sample names (absent if not written). Exits 1 if any sample's exit is not 0.
set +e
set -uo pipefail
echo "upstream-cohort: shell flags $-" >&2
if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }; else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

case "${1:-}" in
ramdb)
  src=$2 name=$3 size=$4
  # The only paths sudo touches: /mnt/ak2-ramdb/<word>.
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "upstream-cohort: ramdb NAME must be a plain word" >&2; exit 2; }
  [[ "$size" =~ ^[0-9]+[kmgKMG]?$ ]] || { echo "upstream-cohort: ramdb SIZE $size (e.g. 1400g)" >&2; exit 2; }
  dst="/mnt/ak2-ramdb/$name"
  [ ! -e "$dst" ] || { echo "upstream-cohort: $dst exists (mounted or left over); umount it first" >&2; exit 1; }
  if mountpoint -q "$dst" 2>/dev/null; then echo "upstream-cohort: $dst is a mount point" >&2; exit 1; fi
  sudo -n mkdir -p "$dst" &&
    sudo -n mount -t tmpfs -o "size=$size,huge=always,mode=0700,uid=$(id -u),gid=$(id -g)" tmpfs "$dst" ||
    { echo "upstream-cohort: tmpfs mount at $dst failed" >&2; sudo -n rmdir "$dst" 2>/dev/null; exit 1; }
  echo "$dst"
  t0=$(now)
  cp "$src/opts.k2d" "$src/taxo.k2d" "$src/hash.k2d" "$dst/" || { echo "upstream-cohort: copy failed" >&2; exit 1; }
  t1=$(now)
  for f in opts.k2d taxo.k2d hash.k2d; do
    [ "$(stat -c%s "$src/$f")" = "$(stat -c%s "$dst/$f")" ] || { echo "upstream-cohort: tmpfs $f differs in size" >&2; exit 1; }
  done
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "upstream-cohort: ramdb copy %.1f s\n", b-a}' >&2
  ;;
umount)
  name=$2
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "upstream-cohort: umount NAME must be a plain word" >&2; exit 2; }
  dst="/mnt/ak2-ramdb/$name"
  mountpoint -q "$dst" || { echo "upstream-cohort: $dst is not mounted" >&2; exit 1; }
  sudo -n umount "$dst" && sudo -n rmdir "$dst" || { echo "upstream-cohort: umount $dst failed" >&2; exit 1; }
  ;;
run)
  shift
  K2=$1 MANIFEST=$2 OUT=$3; shift 3
  COMMON=("$@")
  [ -x "$K2" ] || { echo "upstream-cohort: no kraken2 at $K2" >&2; exit 1; }
  [ -s "$MANIFEST" ] || { echo "upstream-cohort: no manifest $MANIFEST" >&2; exit 1; }
  BAD=0
  while IFS=$'\t' read -r -a F; do
    [ "${#F[@]}" -ge 6 ] || continue
    [[ "${F[0]}" == \#* ]] && continue
    batch=${F[0]} name=${F[4]}
    args=("${F[@]:5}")
    outs=()
    for ((i = 0; i < ${#args[@]}; i++)); do
      case "${args[$i]}" in
        --output|--report|--classified-out|--unclassified-out)
          v=${args[$((i + 1))]}
          case "$v" in s3://*) echo "upstream-cohort: $name: upstream writes local files only ($v)" >&2; exit 2 ;; esac
          [ "$v" = - ] && continue
          if [[ "$v" == *#* ]]; then outs+=("${v/\#/_1}" "${v/\#/_2}"); else outs+=("$v"); fi ;;
      esac
    done
    err=$(mktemp)
    t0=$(now)
    "$K2" "${COMMON[@]}" "${args[@]}" 2> "$err" > /dev/null
    rc=$?
    t1=$(now)
    cs=$(sed -nE 's/.*processed in ([0-9.]+)s.*/\1/p' "$err" | tail -1)
    files='{}'
    for o in "${outs[@]}"; do
      h=absent; [ -f "$o" ] && h=$(sha "$o")
      files=$(jq -c --arg f "$o" --arg h "$h" '. + {($f): $h}' <<< "$files")
    done
    jq -nc --arg name "$name" --argjson batch "$batch" --argjson exit "$rc" --arg t0 "$t0" --arg t1 "$t1" \
      --arg cs "${cs:-}" --argjson files "$files" --arg stderr_tail "$(tail -3 "$err" | tr '\n' ' ' | cut -c1-300)" \
      '{name:$name, batch:$batch, exit:$exit, wall_s:(($t1|tonumber) - ($t0|tonumber)),
        classify_s:(if $cs == "" then null else ($cs|tonumber) end), outputs:$files, stderr_tail:$stderr_tail}' >> "$OUT"
    rm -f "$err"
    echo "upstream-cohort: $name exit $rc" >&2
    [ "$rc" = 0 ] || BAD=1
  done < "$MANIFEST"
  exit "$BAD"
  ;;
*) echo "usage: $0 ramdb SRC NAME SIZE | umount NAME | run KRAKEN2 MANIFEST OUT.jsonl [common arguments...]" >&2; exit 2 ;;
esac
