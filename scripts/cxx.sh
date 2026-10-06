# Compiler choice shared by scripts/oracle-build.sh and scripts/harness-build.sh (sourced).
# Upstream's Makefile needs -fopenmp. Linux uses the system g++ (GCC ships libgomp); Apple clang
# has no -fopenmp, so macOS uses the newest Homebrew GCC. $CXX, if set, wins.
if [ -z "${CXX:-}" ] && [ "$(uname -s)" = Darwin ]; then
  CXX=$(ls /opt/homebrew/bin/g++-[0-9]* 2>/dev/null | sort -V | tail -1)
  [ -n "$CXX" ] || { echo "need Homebrew gcc on macOS (brew install gcc)" >&2; exit 1; }
fi
CXX=${CXX:-g++}
export CXX
