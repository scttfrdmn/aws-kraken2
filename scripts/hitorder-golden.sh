#!/usr/bin/env bash
# make hitorder-golden (docs/hitorder.md, #44): regenerate internal/classify/testdata/umap/ by
# building upstream/umap_order.cc with Amazon Linux 2023's system g++ (the toolchain upstream is
# built with on the instances) against upstream's src at the pin, in podman, and running it on
# the op histories of scripts/tests/umap_cmds.py. Writes ops-<k>.txt.gz, ops-<k>.out.gz and
# gxx.txt (the compiler's version line). Needs podman and the upstream checkout
# (scripts/oracle-build.sh).
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1
. scripts/pin.env
. scripts/paths.sh
command -v podman >/dev/null || { echo "hitorder-golden: need podman" >&2; exit 1; }
[ -d "$ORACLE_SRC/src" ] || { echo "hitorder-golden: no upstream source at $ORACLE_SRC (scripts/oracle-build.sh)" >&2; exit 1; }
[ "$(git -C "$ORACLE_SRC" rev-parse HEAD)" = "$UPSTREAM_PIN" ] || { echo "hitorder-golden: $ORACLE_SRC is not at the pin" >&2; exit 1; }
W=$(mktemp -d "$HOME/.ak2-hitorder.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/ops" "$W/out"
python3 scripts/tests/umap_cmds.py "$W/ops" || exit 1
cat > "$W/run.sh" <<'EOF'
#!/bin/bash
set -e
dnf install -y -q gcc-c++ > /dev/null 2>&1
g++ --version | head -1 > /out/gxx.txt
g++ -O2 -std=c++11 -I /src /repo/upstream/umap_order.cc -o /tmp/umap_order
for f in /ops/ops-*.txt; do /tmp/umap_order < "$f" > "/out/$(basename "$f" .txt).out"; done
EOF
chmod +x "$W/run.sh"
podman run --rm -v "$W:/w:ro" -v "$W/ops:/ops:ro" -v "$W/out:/out" -v "$ORACLE_SRC/src:/src:ro" -v "$ROOT:/repo:ro" \
  public.ecr.aws/amazonlinux/amazonlinux:2023 /w/run.sh || { echo "hitorder-golden: container run failed" >&2; exit 1; }
D=internal/classify/testdata/umap
rm -rf "$D"; mkdir -p "$D"
cp "$W"/ops/ops-*.txt "$W"/out/ops-*.out "$D/" && gzip -9 -n "$D"/ops-*.txt "$D"/ops-*.out && cp "$W/out/gxx.txt" "$D/" || exit 1
echo "hitorder-golden: $(ls "$D" | wc -l | tr -d ' ') files in $D; $(cat "$D/gxx.txt")"
