# shellcheck shell=bash
# Host tunes for a spec body (#41, #25 WP-5; docs/probes.md, "Host tunes"). Sourced, not run.
#
#   ht_init                    record the boot (baseline) value of every knob, once
#   ht_apply SET [DEV...]      apply a named set (or an inline one, key=value[,key=value...])
#   ht_restore                 write back the baseline value of every knob that differs from it
#   ht_record LABEL            the host's fragmentation state and THP settings, appended to
#                              $HT_DIR/hosttune.txt and .jsonl, both pushed at once (ak2_push)
#
# Knobs (paths under $HT_ROOT, empty on an instance; a test or rehearsal points it at a tree):
#   enabled        /sys/kernel/mm/transparent_hugepage/enabled
#   defrag         /sys/kernel/mm/transparent_hugepage/defrag
#   proactiveness  /proc/sys/vm/compaction_proactiveness
#   ra:<dev>       /sys/block/<dev>/queue/read_ahead_kb, for DEV... (default $HT_BLOCKDEVS)
#   precompact     echo 1 > /proc/sys/vm/compact_memory, timed, after the other knobs (a step,
#                  not a setting: it has no baseline and nothing to restore)
#
# Sets (the #41 candidates; docs/probes.md gives each one's rationale):
#   none        nothing: no knob is written and no step runs
#   precompact  precompact=1
#   proactive   proactiveness=100
#   defer       defrag=defer
#   defermadv   defrag=defer+madvise
#   always      defrag=always
#   key=value,... an inline set of the knobs above (ra=<kb> applies to every DEV)
#
# ht_apply records, for every knob (the set's and all the others), the value before and after
# and what the set wanted, one line each in $HT_DIR/apply.tsv, echoed as "ht-apply ..." and
# pushed. It returns 0 only if every knob of the set reads back as wanted; for none, only if
# every knob still has its baseline value (none never writes, so a host that is not at its
# baseline is reported, not repaired: call ht_restore first). After it: HT_SET, HT_APPLIED
# (true|false), HT_WRITES (writes this call made), HT_PRECOMPACT_S (seconds, or "" if the set
# has no precompact step). A knob whose file is absent reads "absent"; a set that needs it fails.
# Writes go straight to a writable file, otherwise through `sudo -n tee`.
# Every function leaves errexit alone and returns a status; none exits the caller.

HT_ROOT=${HT_ROOT:-}
HT_DIR=${HT_DIR:-${W:-${TMPDIR:-/tmp}}/hosttune}
HT_BLOCKDEVS=${HT_BLOCKDEVS:-}
HT_SEQ=0
HT_SET="" HT_APPLIED="" HT_WRITES=0 HT_PRECOMPACT_S="" HT_LAST_JSON=""

ht__now() { local t; t=$(date +%s.%N); case $t in *N) t=$(date +%s) ;; esac; echo "$t"; }
ht__utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ht__say() { if declare -F ak2_say >/dev/null; then ak2_say "$*"; else echo "hosttune: $*"; fi; }
ht__push() { declare -F ak2_push >/dev/null || return 0; ak2_push "$1" "$2" > /dev/null; }

ht__path() {
  case $1 in
    enabled | defrag) echo "$HT_ROOT/sys/kernel/mm/transparent_hugepage/$1" ;;
    proactiveness) echo "$HT_ROOT/proc/sys/vm/compaction_proactiveness" ;;
    ra:*) echo "$HT_ROOT/sys/block/${1#ra:}/queue/read_ahead_kb" ;;
    *) return 1 ;;
  esac
}
# ht__read KNOB: the knob's value (the bracketed choice for the THP files), or "absent".
ht__read() {
  local p v
  p=$(ht__path "$1") || { echo absent; return 1; }
  [ -r "$p" ] || { echo absent; return 1; }
  v=$(cat "$p" 2>/dev/null) || { echo absent; return 1; }
  # The kernel brackets the active choice; a plain file (a test tree) holds just the value.
  case $1 in enabled | defrag) case $v in *\[*\]*) v=$(printf '%s\n' "$v" | sed -n 's/.*\[\([^]]*\)\].*/\1/p') ;; esac ;; esac
  [ -n "$v" ] || { echo absent; return 1; }
  echo "$v"
}
ht__write() {
  local p=$1 v=$2
  HT_WRITES=$((HT_WRITES + 1))
  if [ -w "$p" ]; then printf '%s\n' "$v" > "$p" 2>/dev/null; else printf '%s\n' "$v" | sudo -n tee "$p" > /dev/null 2>&1; fi
}
ht__knobs() {
  local d
  echo enabled; echo defrag; echo proactiveness
  for d in "$@"; do echo "ra:$d"; done
}
ht__base() { awk -F'\t' -v k="$1" '$1 == k {print $2; exit}' "$HT_DIR/base.tsv" 2>/dev/null; }
ht__note_base() {
  mkdir -p "$HT_DIR" || return 1
  [ -n "$(ht__base "$1")" ] || printf '%s\t%s\n' "$1" "$(ht__read "$1")" >> "$HT_DIR/base.tsv"
}
ht__line() {  # SET KNOB BEFORE WANT AFTER STATUS
  local l
  l=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$HT_SEQ" "$(ht__utc)" "$1" "$2" "$3" "$4" "$5" "$6")
  printf '%s\n' "$l" >> "$HT_DIR/apply.tsv"
  echo "ht-apply $l" | tr '\t' ' '
}

# ht_set_def SET: the set's key=value words, space-separated (empty for none).
ht_set_def() {
  case $1 in
    none) echo "" ;;
    precompact) echo "precompact=1" ;;
    proactive) echo "proactiveness=100" ;;
    defer) echo "defrag=defer" ;;
    defermadv) echo "defrag=defer+madvise" ;;
    always) echo "defrag=always" ;;
    *=*) echo "${1//,/ }" ;;
    *) return 1 ;;
  esac
}

ht_init() {
  local k
  mkdir -p "$HT_DIR" || return 1
  [ -f "$HT_DIR/apply.tsv" ] || printf 'seq\tutc\tset\tknob\tbefore\twant\tafter\tstatus\n' > "$HT_DIR/apply.tsv"
  # shellcheck disable=SC2086
  for k in $(ht__knobs $HT_BLOCKDEVS); do ht__note_base "$k"; done
  return 0
}

ht_apply() {
  local set=$1 def kv k v want before after st rc=0 t0 t1 p
  shift
  local -a devs=("$@")
  # shellcheck disable=SC2206
  [ "${#devs[@]}" -gt 0 ] || devs=($HT_BLOCKDEVS)
  HT_SET=$set HT_APPLIED=false HT_WRITES=0 HT_PRECOMPACT_S=""
  def=$(ht_set_def "$set") || { ht__say "unknown set $set"; return 2; }
  ht_init || return 1
  HT_SEQ=$((HT_SEQ + 1))
  local -A HW=()
  local pre=0
  for kv in $def; do
    k=${kv%%=*} v=${kv#*=}
    case $k in
      precompact) pre=$v ;;
      enabled | defrag | proactiveness) HW[$k]=$v ;;
      ra) for p in "${devs[@]}"; do HW["ra:$p"]=$v; done ;;
      *) ht__say "set $set: unknown knob $k"; return 2 ;;
    esac
  done
  for k in $(ht__knobs "${devs[@]}"); do
    ht__note_base "$k"
    before=$(ht__read "$k")
    if [ -n "${HW[$k]+x}" ]; then
      want=${HW[$k]}
      if [ "$before" = absent ]; then
        after=absent st=absent rc=1
      else
        [ "$before" = "$want" ] || ht__write "$(ht__path "$k")" "$want"
        after=$(ht__read "$k")
        if [ "$after" != "$want" ]; then st=failed rc=1
        elif [ "$before" = "$want" ]; then st=already
        else st=set
        fi
      fi
    else
      want=- after=$before st=kept
      if [ "$set" = none ] && [ "$before" != "$(ht__base "$k")" ]; then st=not-baseline rc=1; fi
    fi
    ht__line "$set" "$k" "$before" "$want" "$after" "$st"
  done
  if [ "$pre" = 1 ]; then
    p="$HT_ROOT/proc/sys/vm/compact_memory"
    t0=$(ht__now)
    ht__write "$p" 1; st=$?
    t1=$(ht__now)
    HT_PRECOMPACT_S=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b - a}')
    [ "$st" = 0 ] && st=done || { st=failed; rc=1; }
    ht__line "$set" precompact - 1 "${HT_PRECOMPACT_S}s" "$st"
  fi
  [ "$rc" = 0 ] && HT_APPLIED=true
  ht__push "$HT_DIR/apply.tsv" hosttune-apply.tsv
  return "$rc"
}

ht_restore() {
  local k b cur after st rc=0
  ht_init || return 1
  HT_SEQ=$((HT_SEQ + 1)); HT_WRITES=0
  while IFS=$'\t' read -r k b; do
    cur=$(ht__read "$k")
    [ "$cur" = "$b" ] && continue
    if [ "$b" = absent ] || [ "$cur" = absent ]; then st=absent; rc=1; after=$cur
    else ht__write "$(ht__path "$k")" "$b"; after=$(ht__read "$k"); [ "$after" = "$b" ] && st=restored || { st=failed; rc=1; }
    fi
    ht__line restore "$k" "$cur" "$b" "$after" "$st"
  done < "$HT_DIR/base.tsv"
  ht__push "$HT_DIR/apply.tsv" hosttune-apply.tsv
  return "$rc"
}

# ht_record LABEL: one section of hosttune.txt and one line of hosttune.jsonl, both pushed now.
# The JSON line (also in HT_LAST_JSON, and echoed as "ht-record {json}"): the THP settings and
# proactiveness; the page size and the order of a 2 MiB block; free bytes and free bytes in
# blocks of 2 MiB or more (/proc/buddyinfo, all nodes and zones); buddy, the free blocks per
# order summed over them; every compact_* and thp_* counter of /proc/vmstat; and meminfo's
# MemFree, AnonHugePages, ShmemHugePages, ShmemPmdMapped, FileHugePages and FilePmdMapped (kB).
ht_record() {
  local label=$1 t pg en df pr se j
  mkdir -p "$HT_DIR" || return 1
  t=$(ht__now)
  pg=${HT_PAGE:-$(getconf PAGESIZE 2>/dev/null)}; [[ "$pg" =~ ^[0-9]+$ ]] || pg=4096
  en=$(ht__read enabled); df=$(ht__read defrag); pr=$(ht__read proactiveness)
  se=$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$HT_ROOT/sys/kernel/mm/transparent_hugepage/shmem_enabled" 2>/dev/null)
  {
    echo "== $label $(ht__utc) $t"
    echo "-- thp enabled=$en defrag=$df shmem_enabled=${se:-absent} compaction_proactiveness=$pr page=$pg"
    cat "$HT_ROOT/proc/buddyinfo" 2>/dev/null || echo "-- no buddyinfo"
    grep -E '^(compact_|thp_)' "$HT_ROOT/proc/vmstat" 2>/dev/null || echo "-- no vmstat"
    grep -E '^(MemFree|AnonHugePages|ShmemHugePages|ShmemPmdMapped|FileHugePages|FilePmdMapped):' "$HT_ROOT/proc/meminfo" 2>/dev/null
  } >> "$HT_DIR/hosttune.txt"
  j=""
  [ -r "$HT_ROOT/proc/buddyinfo" ] && [ -r "$HT_ROOT/proc/vmstat" ] && [ -r "$HT_ROOT/proc/meminfo" ] &&
  j=$(awk -v label="$label" -v t="$t" -v pg="$pg" -v en="$en" -v df="$df" -v pr="$pr" '
    FNR == 1 { f++ }
    f == 1 && /zone/ { for (i = 5; i <= NF; i++) { o = i - 5; b[o] += $i; if (o > mo) mo = o } }
    f == 2 && /^(compact_|thp_)/ { vs = vs sprintf("%s\"%s\":%s", (vs == "" ? "" : ","), $1, $2) }
    f == 3 && /^(MemFree|AnonHugePages|ShmemHugePages|ShmemPmdMapped|FileHugePages|FilePmdMapped):/ {
      k = $1; sub(":", "", k); mi = mi sprintf("%s\"%s\":%s", (mi == "" ? "" : ","), k, $2) }
    END {
      ho = 0; while (pg * 2 ^ ho < 2097152) ho++
      fb = 0; fh = 0; bs = ""
      for (o = 0; o <= mo; o++) { n = b[o] + 0; fb += n * 2 ^ o * pg; if (o >= ho) fh += n * 2 ^ o * pg; bs = bs (o ? "," : "") n }
      printf "{\"kind\":\"ht\",\"label\":\"%s\",\"t\":%s,\"enabled\":\"%s\",\"defrag\":\"%s\",\"proactiveness\":\"%s\",", label, t, en, df, pr
      printf "\"page_bytes\":%d,\"huge_order\":%d,\"free_bytes\":%.0f,\"free_huge_bytes\":%.0f,\"free_huge_frac\":%s,", pg, ho, fb, fh, (fb > 0 ? sprintf("%.6f", fh / fb) : "null")
      printf "\"buddy\":[%s],\"vmstat\":{%s},\"meminfo_kb\":{%s}}\n", bs, vs, mi
    }' "$HT_ROOT/proc/buddyinfo" "$HT_ROOT/proc/vmstat" "$HT_ROOT/proc/meminfo" 2>/dev/null)
  [ -n "$j" ] || j="{\"kind\":\"ht\",\"label\":\"$label\",\"t\":$t,\"error\":\"no /proc state\"}"
  HT_LAST_JSON=$j
  printf '%s\n' "$j" >> "$HT_DIR/hosttune.jsonl"
  echo "ht-record $j"
  ht__push "$HT_DIR/hosttune.txt" hosttune.txt && ht__push "$HT_DIR/hosttune.jsonl" hosttune.jsonl
}
