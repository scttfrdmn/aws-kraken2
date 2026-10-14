# Pinned spawn and truffle (docs/run.md, "Pinned tools"). Sourced by scripts/run.sh,
# scripts/run-multi.sh and scripts/mkspec-conductor.sh.
#
# ak2_pin_tools ROOT: puts AK2_TOOLS_BIN (default ROOT/bin, filled by make tools) first on PATH, so
# these scripts and everything they call (spawn task run, cost_check.sh's truffle, ...) use the
# pinned binaries, and never what Homebrew put on PATH. Returns non-zero, saying why, when a tool
# is missing or reads back a version other than scripts/conductor.tools.tsv's. Sets AK2_TOOLS_JSON:
# {spawn, truffle (versions), spawn_path, spawn_sha256, truffle_path, truffle_sha256}, for the manifest.
ak2_pin_tools() {
  local root=$1 bin t want got p s json='{}'
  bin=${AK2_TOOLS_BIN:-$root/bin}
  for t in spawn truffle; do
    want=$(awk -F'\t' -v t="$t" '$1 == t {print $2; exit}' "$root/scripts/conductor.tools.tsv")
    [ -n "$want" ] || { echo "tools: no $t version in scripts/conductor.tools.tsv" >&2; return 1; }
    p="$bin/$t"
    [ -x "$p" ] || { echo "tools: $p is missing; run make tools (it installs $t $want, sha256-checked)" >&2; return 1; }
    got=$("$p" version 2> /dev/null | awk '/Version:/{print $2; exit}')
    [ "$got" = "$want" ] || { echo "tools: $p reports version '${got:-none}', want $want (scripts/conductor.tools.tsv); run make tools" >&2; return 1; }
    if command -v sha256sum > /dev/null; then s=$(sha256sum "$p" | cut -d' ' -f1); else s=$(shasum -a 256 "$p" | cut -d' ' -f1); fi
    json=$(jq -c --arg t "$t" --arg v "$got" --arg p "$p" --arg s "$s" '. + {($t): $v, ($t + "_path"): $p, ($t + "_sha256"): $s}' <<< "$json") || return 1
  done
  export PATH="$bin:$PATH"
  hash -r
  for t in spawn truffle; do
    [ "$(command -v "$t")" = "$bin/$t" ] || { echo "tools: $t on PATH is $(command -v "$t"), not $bin/$t" >&2; return 1; }
  done
  AK2_TOOLS_JSON=$json
  export AK2_TOOLS_BIN=$bin
}
