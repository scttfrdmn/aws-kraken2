#!/usr/bin/env bash
# Decompressor shims for the Law 1 runs of AK2_DECOMPRESS=pipe (#48; docs/oracle.md,
# "Decompressor shims"). Writes DIR/gzip, a shim that runs TOOL for the wrapper's exact call,
# `gzip -dc FILE`, and GNU gzip for everything else (the oracle scripts compress their variants
# with the gzip on PATH, so those bytes do not depend on the shim). `gzip --version` names both.
# Put DIR first on PATH with DECOMP_BIN=DIR: upstream's wrapper and ours then both run TOOL.
# This is the oracle side of upstream's ladder lever S5 (rapidgzip placed on PATH as gzip).
#
# Usage: scripts/decomp-shim.sh gnu|pigz|rapidgzip DIR
# Env:   GNU_GZIP   the GNU gzip (default /tmp/gnugzip/inst/bin/gzip if present, else gzip on PATH)
#        PIGZ_BIN   the pigz binary (default pigz on PATH; not PIGZ, which is pigz's own options)
#        RAPIDGZIP_PYTHON  a python whose environment holds rapidgzip (pinned: rapidgzip==0.14.5,
#                   pip in a venv under a fresh empty directory); it is run with -I
# Prints the shim's --version line. Exits non-zero if a tool is missing or the shim cannot
# decompress a test stream.
set +e
set -uo pipefail
echo "decomp-shim: shell flags $-" >&2
TOOL=${1:-}; DIR=${2:-}
[ -n "$TOOL" ] && [ -n "$DIR" ] || { echo "usage: $0 gnu|pigz|rapidgzip DIR" >&2; exit 2; }
GNU=${GNU_GZIP:-}
if [ -z "$GNU" ]; then
  if [ -x /tmp/gnugzip/inst/bin/gzip ]; then GNU=/tmp/gnugzip/inst/bin/gzip; else GNU=$(command -v gzip); fi
fi
[ -x "$GNU" ] || { echo "decomp-shim: no GNU gzip ($GNU)" >&2; exit 1; }
"$GNU" --version 2>&1 | head -1 | grep -q '^gzip ' || { echo "decomp-shim: $GNU is not GNU gzip" >&2; exit 1; }
case "$TOOL" in
  gnu) RUN="exec '$GNU' -dc \"\$2\""; VER=$("$GNU" --version | head -1) ;;
  pigz)
    P=${PIGZ_BIN:-$(command -v pigz)}
    [ -x "$P" ] || { echo "decomp-shim: no pigz (set PIGZ_BIN)" >&2; exit 1; }
    RUN="exec '$P' -dc \"\$2\""; VER=$("$P" --version 2>&1 | head -1) ;;
  rapidgzip)
    PY=${RAPIDGZIP_PYTHON:-}
    [ -x "$PY" ] || { echo "decomp-shim: set RAPIDGZIP_PYTHON to a venv python holding rapidgzip" >&2; exit 1; }
    CLI="import sys; from rapidgzip import cli; sys.argv[0] = 'rapidgzip'; sys.exit(cli())"
    RUN="exec '$PY' -I -c \"$CLI\" -d -c \"\$2\""
    VER=$("$PY" -I -c "$CLI" --version 2>&1 | grep -o 'version [0-9.]*' | head -1)
    [ -n "$VER" ] || { echo "decomp-shim: rapidgzip does not run under $PY" >&2; exit 1; }
    VER="rapidgzip $VER" ;;
  *) echo "decomp-shim: unknown tool $TOOL" >&2; exit 2 ;;
esac
mkdir -p "$DIR" || exit 1
cat > "$DIR/gzip" <<EOF
#!/bin/sh
# scripts/decomp-shim.sh $TOOL: \`gzip -dc FILE\` runs $TOOL; anything else runs GNU gzip.
if [ "\$#" = 2 ] && [ "\$1" = -dc ]; then $RUN; fi
if [ "\$#" = 1 ] && [ "\$1" = --version ]; then echo "shim gzip -dc: $VER; otherwise: $("$GNU" --version | head -1)"; exit 0; fi
exec '$GNU' "\$@"
EOF
chmod 755 "$DIR/gzip" || exit 1
# The shim must reproduce a known stream.
T=$(mktemp -d) || exit 1
printf '@r1\nACGT\n+\nIIII\n' > "$T/x"
"$GNU" -nc "$T/x" > "$T/x.gz"
"$DIR/gzip" -dc "$T/x.gz" > "$T/y"
cmp -s "$T/x" "$T/y"; ok=$?
rm -rf "$T"
[ "$ok" = 0 ] || { echo "decomp-shim: $DIR/gzip -dc does not round-trip" >&2; exit 1; }
"$DIR/gzip" --version
