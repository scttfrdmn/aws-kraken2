#!/usr/bin/env bash
# make tools [WITH_GO=1] (docs/run.md, "Pinned tools"): spawn and truffle at the versions of
# scripts/conductor.tools.tsv, from their release artefacts, each checked by sha256, into the repo's
# bin/ (AK2_TOOLS_BIN overrides). run.sh and run-multi.sh use only these (scripts/lib/tools_pin.sh),
# so a Homebrew upgrade of the tools on PATH never changes a run. WITH_GO=1 (the conductor) also installs
# Go into .cache/tools/go. Idempotent: an installed tool whose artefact sha256 and version match is
# kept. Exit 0: installed and verified; 2: refused (no row for this OS/arch, a download or sha256
# mismatch, a version that does not read back).
#
# Deliberately not `set -e`: every status is checked by hand.
set +e
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TSV="$ROOT/scripts/conductor.tools.tsv"
BIN=${AK2_TOOLS_BIN:-$ROOT/bin}
WITH_GO=0; [ "${1:-}" = --go ] && WITH_GO=1
die() { echo "make tools: $*" >&2; exit 2; }
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in aarch64|arm64) ARCH=arm64 ;; x86_64|amd64) ARCH=amd64 ;; *) die "unknown machine $(uname -m)" ;; esac
command -v curl > /dev/null || die "curl not on PATH"
sha() { if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
mkdir -p "$BIN" || die "cannot create $BIN"
TMP=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT
TOOLS="spawn truffle"; [ "$WITH_GO" = 1 ] && TOOLS="$TOOLS go"
for tool in $TOOLS; do
  ROW=$(awk -F'\t' -v t="$tool" -v o="$OS" -v a="$ARCH" '$1==t && $3==o && $4==a' "$TSV")
  [ -n "$ROW" ] || die "no $tool row for $OS/$ARCH in $TSV"
  IFS=$'\t' read -r _ ver _ _ url sum member <<< "$ROW"
  if [ "$tool" = go ]; then DEST="$ROOT/.cache/tools/go-$ver"; MARK="$DEST/.artefact.sha256"; EXE="$DEST/go/bin/go"
  else DEST="$BIN"; MARK="$BIN/.$tool.artefact.sha256"; EXE="$BIN/$tool"; fi
  readver() { if [ "$tool" = go ]; then "$EXE" version 2>/dev/null | awk '{print $3}' | sed 's/^go//'
              else "$EXE" version 2>/dev/null | awk '/Version:/{print $2; exit}'; fi; }
  if [ -x "$EXE" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$sum" ] && [ "$(readver)" = "$ver" ]; then
    echo "make tools: $tool $ver already installed ($EXE, artefact sha256 ${sum:0:12})"; continue
  fi
  curl -fsSL --retry 5 --retry-delay 5 -o "$TMP/$tool.tgz" "$url" || die "download of $url failed"
  got=$(sha "$TMP/$tool.tgz")
  [ "$got" = "$sum" ] || die "$tool $ver: artefact sha256 $got, $TSV says $sum; not installed"
  if [ "$tool" = go ]; then
    rm -rf "$DEST" && mkdir -p "$DEST" && tar -xzf "$TMP/$tool.tgz" -C "$DEST" || die "untar go"
  else
    mkdir -p "$TMP/x" && tar -xzf "$TMP/$tool.tgz" -C "$TMP/x" "$member" || die "untar $tool"
    mv -f "$TMP/x/$member" "$EXE" && chmod 0755 "$EXE" || die "install $EXE"
  fi
  echo "$sum" > "$MARK" || die "cannot write $MARK"
  [ "$(readver)" = "$ver" ] || die "$EXE reports version '$(readver)', want $ver"
  echo "make tools: $tool $ver installed: $EXE (artefact sha256 ${sum:0:12} ok; binary sha256 $(sha "$EXE" | cut -c1-12))"
done
exit 0
