#!/usr/bin/env bash
# Local post-processing for runs/g0a.json, run by scripts/run.sh as: scripts/post/g0a.sh <run-dir>.
# Re-runnable by hand on an existing run dir; it records the commit it decoded at.
# Decodes the raw bytes the instance fetched with cmd/k2probe and derives the tables that
# `make report` renders. Reads only files in <run-dir>; writes decoded/ and tables/ there.
# Object identities come from manifest.json (the declared datasets), never from this script.
set -uo pipefail
D=${1:?run dir}
O="$D/out"
M="$D/manifest.json"
fail() { echo "g0a.post: $*" >&2; exit 1; }
for f in hash.k2d.head32 hash.k2d.head32.get.json opts.k2d opts.k2d.get.json list-objects-v2.json \
         head-hash.k2d.json head-opts.k2d.json head-taxo.k2d.json request-payment.json; do
  [ -s "$O/$f" ] || fail "missing $O/$f"
done
[ -s "$M" ] || fail "missing $M"
ds() { jq -r --arg f "$1" "[.datasets[] | select(.uri|endswith(\"/\" + \$f))][0].$2 // empty" "$M"; }
HURI=$(ds hash.k2d uri); [ -n "$HURI" ] || fail "manifest declares no hash.k2d dataset"
U=${HURI#s3://}; BUCKET=${U%%/*}; HKEY=${U#*/}
make -s build || fail "make build failed"
mkdir -p "$D/decoded" "$D/tables"
# Decoding is local and may be re-run at a later commit than the launch; record which.
jq -n --arg c "$(git rev-parse HEAD)" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{decoded_at_commit:$c, decoded_at:$t, decoder:"cmd/k2probe + internal/kdb"}' > "$D/decoded/provenance.json"

# ---- the bytes we decoded are the objects the manifest pinned at launch ----
etag() { jq -r '.ETag // empty | gsub("\"";"")' "$1"; }
{
  printf 'object\tlaunch_head_etag\tinstance_get_etag\tinstance_head_etag\tmatch\n'
  for f in hash.k2d opts.k2d taxo.k2d; do
    L=$(ds "$f" etag); H=$(etag "$O/head-$f.json"); G="-"
    case $f in hash.k2d) G=$(etag "$O/hash.k2d.head32.get.json") ;; opts.k2d) G=$(etag "$O/opts.k2d.get.json") ;; esac
    ok=yes; [ -n "$L" ] && [ "$L" = "$H" ] || ok=NO; [ "$G" = "-" ] || [ "$G" = "$L" ] || ok=NO
    printf '%s\t%s\t%s\t%s\t%s\n' "$f" "${L:-missing}" "$G" "$H" "$ok"
  done
} > "$D/tables/etag-check.tsv"
if grep -q 'NO$' "$D/tables/etag-check.tsv"; then cat "$D/tables/etag-check.tsv" >&2; fail "ETag mismatch: the object changed between launch and fetch"; fi

HSIZE=$(ds hash.k2d size)
LSIZE=$(jq -r --arg k "$HKEY" '.Contents[] | select(.Key==$k) | .Size' "$O/list-objects-v2.json")
ISIZE=$(jq -r .ContentLength "$O/head-hash.k2d.json")
[ "$HSIZE" = "$LSIZE" ] && [ "$HSIZE" = "$ISIZE" ] || fail "hash.k2d size: launch $HSIZE, listing $LSIZE, instance head $ISIZE"
[ "$(wc -c < "$O/hash.k2d.head32" | tr -d ' ')" = 32 ] || fail "hash.k2d.head32 is not 32 bytes"
bin/k2probe header -size "$HSIZE" "$O/hash.k2d.head32" > "$D/decoded/header.json" || fail "header decode failed"
bin/k2probe opts "$O/opts.k2d" > "$D/decoded/opts.json" || fail "opts decode failed"
OSIZE=$(ds opts.k2d size)
[ "$(jq -r .file_size "$D/decoded/opts.json")" = "$OSIZE" ] || fail "opts.k2d bytes fetched != launch ContentLength $OSIZE"

{
  printf 'key\tsize_bytes\tetag\tlast_modified\tstorage_class\n'
  jq -r '.Contents[] | [.Key, .Size, (.ETag|gsub("\"";"")), .LastModified, .StorageClass] | @tsv' "$O/list-objects-v2.json"
} > "$D/tables/listing.tsv"
{
  printf 'bucket\tobjects\ttotal_bytes\ttotal_gib\n'
  jq -r --arg b "$BUCKET" '[.Contents | length, (map(.Size) | add)] | "\($b)\t\(.[0])\t\(.[1])\t\(.[1] / 1073741824 * 100 | round / 100)"' "$O/list-objects-v2.json"
} > "$D/tables/listing-summary.tsv"
{
  printf 'file\tsize_bytes\tetag\tversion_id\tlast_modified\n'
  for f in hash.k2d opts.k2d taxo.k2d; do
    jq -r --arg f "$f" '[$f, .ContentLength, (.ETag|gsub("\"";"")), (.VersionId // "null"), .LastModified] | @tsv' "$O/head-$f.json"
  done
} > "$D/tables/runtime-files.tsv"
{
  printf 'bucket\tpayer\n'
  printf '%s\t%s\n' "$BUCKET" "$(jq -r .Payer "$O/request-payment.json")"
} > "$D/tables/payer.tsv"
echo "g0a.post: decoded $(jq -c '{capacity,size,key_bits,value_bits,cell_bits}' "$D/decoded/header.json")"
echo "g0a.post: opts $(jq -c '{k,l,dna_db,revcom_version,db_version,db_type,file_size,layout,padding_fields}' "$D/decoded/opts.json")"
