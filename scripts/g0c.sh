#!/usr/bin/env bash
# make g0c PART=local|probes|runs (docs/g0c.md).
#   local   prove `k2probe runs` on the pinned Viral and Standard-8 hash.k2d: the streaming pass
#           must equal the brute-force reference (-brute), its SHA-256 must equal `shasum -a 256`
#           (or sha256sum), and occupied/cells must equal the header's size/capacity. Writes
#           results/g0c/local-<UTC time>-<short sha>/<db>/.
#   probes  make run GATE=g0c SPEC=runs/g0c-probes.json  (G0c-b, #8; the cheap rung, run first)
#   runs    make run GATE=g0c SPEC=runs/g0c-runs.json    (G0c-a, #7; the 1.2 TB pass)
# DRY_RUN=1 passes through to run.sh.
set +e
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. scripts/pin.env
. scripts/paths.sh
echo "g0c: shell flags $-"
PART=${1:-}
case "$PART" in
  probes|runs) exec scripts/run.sh g0c "runs/g0c-$PART.json" ;;
  local) ;;
  *) echo "usage: make g0c PART=local|probes|runs" >&2; exit 2 ;;
esac

if command -v sha256sum >/dev/null; then sha() { sha256sum "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 "$1" | cut -d' ' -f1; }; fi
make -s build || { echo "g0c: make build failed" >&2; exit 1; }
RUN_ID=$(date -u +%Y%m%d-%H%M%S)-$(git rev-parse --short HEAD)
OUT="results/g0c/local-$RUN_ID"
[ -e "$OUT" ] && { echo "g0c: $OUT exists" >&2; exit 1; }
mkdir -p "$OUT"
FAILED=0
ROWS=()
for db in k2_viral_20260626 k2_standard_08_GB_20260626; do
  H="$K2_DB_ROOT/$db/hash.k2d"
  [ -s "$H" ] || { echo "g0c: missing $H (make oracle fetches it)" >&2; FAILED=1; continue; }
  D="$OUT/$db"; mkdir -p "$D"
  echo "g0c: $db: k2probe runs -brute"
  bin/k2probe runs -file "$H" -brute -workers 8 -chunk-mib 16 -out "$D" 2> "$D/k2probe.log"
  rc=$?
  cat "$D/k2probe.log"
  [ "$rc" = 0 ] || { echo "g0c: $db: k2probe runs failed (rc $rc)" >&2; FAILED=1; continue; }
  want=$(sha "$H")
  got=$(jq -r .sha256 "$D/summary.json")
  ok=yes
  [ "$got" = "$want" ] || ok=NO
  [ "$(jq -r '.occupied_equals_header_size and .cells_equal_capacity and .complete' "$D/summary.json")" = true ] || ok=NO
  grep -q 'brute: identical' "$D/k2probe.log" || ok=NO
  [ "$ok" = yes ] || FAILED=1
  ROWS+=("$(jq -nc --arg db "$db" --arg w "$want" --arg ok "$ok" --slurpfile s "$D/summary.json" \
    --arg src "$(tr '\n' ' ' < "$K2_DB_ROOT/$db/SOURCE" 2>/dev/null)" \
    '{db:$db, source:$src, sha256_streamed:$s[0].sha256, sha256_local_tool:$w, brute_identical:true,
      cells:$s[0].cells, capacity:$s[0].capacity, occupied:$s[0].occupied, header_size:$s[0].header_size,
      runs:$s[0].runs, longest_run:$s[0].longest_run, ok:$ok}')")
  echo "g0c: $db: sha256 streamed $got, local $want; ok=$ok"
done
printf '%s\n' "${ROWS[@]}" | jq -s --arg c "$(git rev-parse HEAD)" --arg dirty "$([ -n "$(git status --porcelain -- cmd internal scripts)" ] && echo true || echo false)" \
  --arg pin "$UPSTREAM_PIN" --arg t "$(date -u +%FT%TZ)" --arg host "$(uname -sm)" \
  --arg go "$(go version)" --arg shatool "$(command -v sha256sum || echo 'shasum -a 256')" \
  '{gate:"g0c", part:"local", commit:$c, tree_dirty:($dirty=="true"), upstream_pin:$pin, finished:$t,
    host:$host, go:$go, sha256_tool:$shatool, invocation:"make g0c PART=local", databases:.}' > "$OUT/manifest.json"
echo "results: $OUT"
[ "$FAILED" = 0 ] || { echo "g0c: FAILED" >&2; exit 1; }
echo "g0c: local proof passed"
