#!/usr/bin/env bash
# Fetch a pinned public kraken2 database into .cache/db/<name>/ and record its ETag.
# Usage: scripts/fetch-db.sh viral|standard8
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  viral)     NAME=k2_viral_20260626 ;;
  standard8) NAME=k2_standard_08_GB_20260626 ;;
  *) echo "usage: $0 viral|standard8" >&2; exit 2 ;;
esac
SRC="s3://genome-idx/kraken/$NAME.tar.gz"
. scripts/pin.env
. scripts/paths.sh
DST="$K2_DB_ROOT/$NAME"
if [ -s "$DST/hash.k2d" ] && [ -s "$DST/SOURCE" ]; then echo "$DST"; exit 0; fi
mkdir -p "$DST"
if command -v aws >/dev/null; then
  AWS="aws --no-sign-request --region us-east-1"
  ETAG=$($AWS s3api head-object --bucket genome-idx --key "kraken/$NAME.tar.gz" --query ETag --output text)
  $AWS s3 cp --only-show-errors "$SRC" - | tar -xzf - -C "$DST"
else
  # No AWS CLI (e.g. a CI runner): the same public object over HTTPS; the ETag is the object's.
  URL="https://genome-idx.s3.amazonaws.com/kraken/$NAME.tar.gz"
  ETAG=$(curl -fsSI "$URL" | tr -d '\r' | awk 'tolower($1)=="etag:"{print $2}')
  [ -n "$ETAG" ] || { echo "fetch-db: no ETag for $URL" >&2; exit 1; }
  curl -fsS "$URL" | tar -xzf - -C "$DST"
fi
test -s "$DST/hash.k2d" -a -s "$DST/taxo.k2d" -a -s "$DST/opts.k2d"
printf 'source %s\netag %s\nfetched %s\n' "$SRC" "$ETAG" "$(date -u +%FT%TZ)" > "$DST/SOURCE"
echo "$DST"
