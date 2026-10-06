#!/usr/bin/env bash
# Local post-processing for runs/g0a.json, run by scripts/run.sh as: g0a.post.sh <run-dir>.
# Decodes the raw bytes the instance fetched with cmd/k2probe and derives the tables that
# `make report` renders. Reads only files in <run-dir>; writes decoded/ and tables/ there.
set -uo pipefail
D=${1:?run dir}
O="$D/out"
fail() { echo "g0a.post: $*" >&2; exit 1; }
for f in hash.k2d.head32 opts.k2d list-objects-v2.json head-hash.k2d.json head-opts.k2d.json head-taxo.k2d.json request-payment.json; do
  [ -s "$O/$f" ] || fail "missing $O/$f"
done
make -s build || fail "make build failed"
mkdir -p "$D/decoded" "$D/tables"

HSIZE=$(jq -r .ContentLength "$O/head-hash.k2d.json")
LSIZE=$(jq -r '.Contents[] | select(.Key|endswith("/hash.k2d")) | .Size' "$O/list-objects-v2.json")
[ "$HSIZE" = "$LSIZE" ] || fail "hash.k2d size: head-object $HSIZE != listing $LSIZE"
[ "$(wc -c < "$O/hash.k2d.head32" | tr -d ' ')" = 32 ] || fail "hash.k2d.head32 is not 32 bytes"
bin/k2probe header -size "$HSIZE" "$O/hash.k2d.head32" > "$D/decoded/header.json" || fail "header decode failed"
bin/k2probe opts "$O/opts.k2d" > "$D/decoded/opts.json" || fail "opts decode failed"
OSIZE=$(jq -r .ContentLength "$O/head-opts.k2d.json")
[ "$(jq -r .file_size "$D/decoded/opts.json")" = "$OSIZE" ] || fail "opts.k2d bytes fetched != head-object ContentLength $OSIZE"

{
  printf 'key\tsize_bytes\tetag\tlast_modified\tstorage_class\n'
  jq -r '.Contents[] | [.Key, .Size, (.ETag|gsub("\"";"")), .LastModified, .StorageClass] | @tsv' "$O/list-objects-v2.json"
} > "$D/tables/listing.tsv"
{
  printf 'objects\ttotal_bytes\ttotal_gib\n'
  jq -r '[.Contents | length, (map(.Size) | add)] | "\(.[0])\t\(.[1])\t\(.[1] / 1073741824 * 100 | round / 100)"' "$O/list-objects-v2.json"
} > "$D/tables/listing-summary.tsv"
{
  printf 'file\tsize_bytes\tetag\tversion_id\tlast_modified\n'
  for f in hash.k2d opts.k2d taxo.k2d; do
    jq -r --arg f "$f" '[$f, .ContentLength, (.ETag|gsub("\"";"")), (.VersionId // "null"), .LastModified] | @tsv' "$O/head-$f.json"
  done
} > "$D/tables/runtime-files.tsv"
{
  printf 'bucket\tpayer\n'
  printf 'kraken2-ncbi-refseq-complete-v205\t%s\n' "$(jq -r .Payer "$O/request-payment.json")"
} > "$D/tables/payer.tsv"
echo "g0a.post: decoded $(jq -c '{capacity,size,key_bits,value_bits,cell_bits}' "$D/decoded/header.json")"
echo "g0a.post: opts $(jq -c '{k,l,dna_db,revcom_version,db_version,db_type,file_size,absent_fields}' "$D/decoded/opts.json")"
