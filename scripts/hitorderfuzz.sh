#!/usr/bin/env bash
# make hitorderfuzz [HITORDERFUZZ=quick|full|selftest] (docs/hitorderfuzz.md, #44): differential
# fuzz of internal/classify's HitCounts (newHitCounts()) against std::unordered_map<unsigned long,
# unsigned long> as Amazon Linux 2023's g++ 11.5.0 compiles it (upstream/umap_order.cc, built
# against upstream's src at the pin).
# On Amazon Linux 2023 with g++ 11.5.0 the harness is built and run natively (the CI job);
# anywhere else it is built and run in podman (public.ecr.aws/amazonlinux/amazonlinux:2023).
# Runs TestHitOrderFuzz and writes results/g1/hitorderfuzz-<UTC ts>-<short sha>/
# {manifest.json,summary.json,summary.md,probe.tsv,run.log} (plus mismatch.txt and
# mismatch-ops.txt on a mismatch). HITORDERFUZZ_SEED overrides the seed (default 44).
# Exit 0 only if no mismatch and every coverage target was met.
set -uo pipefail
set +e
echo "hitorderfuzz: shell flags $-"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
MODE=${1:-quick}
case "$MODE" in quick|full|selftest) ;; *) echo "usage: $0 [quick|full|selftest]" >&2; exit 2 ;; esac
SEED=${HITORDERFUZZ_SEED:-44}
IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023
CXXFLAGS="-std=c++11 -O3"
. scripts/pin.env
. scripts/paths.sh
for c in jq git go shasum; do command -v "$c" >/dev/null || { echo "hitorderfuzz: need $c" >&2; exit 1; }; done
[ -d "$ORACLE_SRC/src" ] || { echo "hitorderfuzz: no upstream source at $ORACLE_SRC (scripts/oracle-build.sh)" >&2; exit 1; }
[ "$(git -C "$ORACLE_SRC" rev-parse HEAD)" = "$UPSTREAM_PIN" ] || { echo "hitorderfuzz: $ORACLE_SRC is not at the pin" >&2; exit 1; }

# Podman on macOS shares only the home directory with its VM.
W=$(mktemp -d "$HOME/.ak2-hitorderfuzz.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
cp upstream/umap_order.cc "$W/" || exit 1

NATIVE=false
OSID=$( (. /etc/os-release 2>/dev/null && echo "$ID $VERSION_ID") )
if [ "$(uname -s)" = Linux ] && [ "$OSID" = "amzn 2023" ] && command -v g++ >/dev/null \
   && [ "$(g++ -dumpfullversion)" = 11.5.0 ]; then
  NATIVE=true
fi

cat > "$W/build.sh" <<EOF
#!/bin/bash
set +e
if ! command -v g++ >/dev/null; then dnf install -y -q gcc-c++ > /dev/null 2>&1 || exit 1; fi
g++ --version | head -1 > "\$1/gxx.txt"
g++ -dumpfullversion > "\$1/gxx-version.txt"
{ rpm -q gcc-c++ libstdc++-devel libstdc++ glibc; . /etc/os-release; echo "\$PRETTY_NAME"; uname -m; } > "\$1/toolchain.txt" 2>&1
g++ $CXXFLAGS -I "\$2" "\$1/umap_order.cc" -o "\$1/umap_order" || exit 1
EOF
chmod +x "$W/build.sh"
if [ "$NATIVE" = true ]; then
  "$W/build.sh" "$W" "$ORACLE_SRC/src" || { echo "hitorderfuzz: native build failed" >&2; exit 1; }
  CMD="$W/umap_order"
  MIRROR="stdbuf -oL $W/umap_order"
  RUNTIME=$(rpm -q libstdc++ 2>&1)
  IMGDIGEST=""
else
  command -v podman >/dev/null || { echo "hitorderfuzz: not on AL2023 with g++ 11.5.0, and no podman" >&2; exit 1; }
  podman run --rm -v "$W:/w" -v "$ORACLE_SRC/src:/src:ro" "$IMAGE" /w/build.sh /w /src \
    || { echo "hitorderfuzz: container build failed" >&2; exit 1; }
  CMD="podman run -i --rm -v $W:/w:ro $IMAGE /w/umap_order"
  MIRROR="podman run -i --rm -v $W:/w:ro $IMAGE stdbuf -oL /w/umap_order"
  RUNTIME=$(podman run --rm "$IMAGE" rpm -q libstdc++ 2>&1)
  IMGDIGEST=$(podman image inspect "$IMAGE" --format '{{.Digest}}' 2>/dev/null)
fi
GXXV=$(cat "$W/gxx-version.txt")
echo "hitorderfuzz: $(cat "$W/gxx.txt"); runtime $RUNTIME; native=$NATIVE"
[ "$GXXV" = 11.5.0 ] || { echo "hitorderfuzz: g++ is $GXXV, not 11.5.0" >&2; exit 1; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
SHA=$(git rev-parse HEAD)
RES="results/g1/hitorderfuzz-$TS-${SHA:0:7}"
mkdir -p "$RES" || exit 1
start=$(date -u +%FT%TZ)
HITORDERFUZZ_CMD="$CMD" HITORDERFUZZ_MIRROR_CMD="$MIRROR" HITORDERFUZZ="$MODE" HITORDERFUZZ_SEED="$SEED" \
  HITORDERFUZZ_OUT="$ROOT/$RES" \
  go test -count=1 -v -timeout 0 -run '^TestHitOrderFuzz$' ./internal/classify/ > "$RES/run.log" 2>&1
st=$?
stop=$(date -u +%FT%TZ)
tail -30 "$RES/run.log"

SUMMARY="$RES/summary.json"; [ -s "$SUMMARY" ] || SUMMARY=/dev/null
DIRTY=false; [ -n "$(git status --porcelain --untracked-files=no)" ] && DIRTY=true
jq -n \
  --arg what "make hitorderfuzz: internal/classify HitCounts vs std::unordered_map under AL2023 g++ 11.5.0, order and counts at every print (#44)" \
  --arg inv "scripts/hitorderfuzz.sh $MODE" --arg mode "$MODE" --argjson seed "$SEED" --arg only "${HITORDERFUZZ_ONLY:-}" \
  --arg commit "$SHA" --argjson dirty "$DIRTY" --arg pin "$UPSTREAM_PIN" \
  --arg describe "$(git -C "$ORACLE_SRC" describe --tags 2>/dev/null)" \
  --arg gxx "$(cat "$W/gxx.txt")" --arg gxxv "$GXXV" --arg toolchain "$(cat "$W/toolchain.txt")" \
  --arg runtime "$RUNTIME" --arg flags "$CXXFLAGS" --argjson native "$NATIVE" --arg image "$IMAGE" \
  --arg digest "$IMGDIGEST" \
  --arg bin_sha "$(shasum -a 256 "$W/umap_order" | cut -d' ' -f1)" \
  --arg src_sha "$(shasum -a 256 upstream/umap_order.cc | cut -d' ' -f1)" \
  --arg go "$(go version)" --arg host "$(uname -n)" --arg os "$(uname -s)" --arg arch "$(uname -m)" \
  --arg start "$start" --arg stop "$stop" --argjson status "$st" \
  --slurpfile s "$SUMMARY" \
  '($s[0] // null) as $sum |
   {gate:"g1", what:$what, invocation:$inv, commit:$commit, dirty:$dirty, upstream_pin:$pin,
    upstream_describe:$describe,
    compiler:{gxx:$gxx, version:$gxxv, cxxflags:$flags, toolchain:($toolchain | split("\n")),
              runtime_libstdcxx:$runtime, native:$native,
              container_image:(if $native then null else $image end),
              container_digest:(if $native then null else $digest end),
              umap_order_sha256:$bin_sha, umap_order_cc_sha256:$src_sha},
    go:$go, host:{name:$host, os:$os, arch:$arch},
    corpus:{mode:$mode, seed:$seed, only:(if $only == "" then null else $only end), sizes:($sum.sizes // null),
            probe_bucket_counts:($sum.probe_bucket_counts // null),
            probe_boundaries:($sum.probe_boundaries // null)},
    results:(if $sum == null then null else
      {pass:$sum.pass, failures:$sum.failures, stats:$sum.stats, mismatch:($sum.mismatch // null),
       seconds:$sum.seconds} end),
    start:$start, stop:$stop, go_test_status:$status,
    failed:($status != 0 or $sum == null or ($sum.pass | not))}' > "$RES/manifest.json" || st=1
if [ "$st" = 0 ] && jq -e '.failed == false' "$RES/manifest.json" >/dev/null; then
  echo "hitorderfuzz: ok ($RES)"
  exit 0
fi
echo "hitorderfuzz: FAILED (see $RES/summary.md and $RES/run.log)" >&2
exit 1
