// Package oracletest locates the oracle artifacts for tests that compare against upstream, with
// the same rules as scripts/paths.sh:
//
//   - shared artifacts (the upstream checkout and build in .oracle/, pinned databases and real
//     reads in .cache/) live once in the main checkout, which git worktrees reach through git's
//     common dir. AWS_KRAKEN2_ROOT (or K2_SHARED_ROOT, as the scripts use) overrides.
//   - harness binaries (scripts/harness-build.sh) are per checkout, in <module root>/.oracle/harness,
//     because harness sources differ per branch.
//
// Tests that need an artifact t.Skip when it is absent (docs/build.md), unless
// AWS_KRAKEN2_REQUIRE_ORACLE=1, which turns every skip here into a failure.
package oracletest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Pin is the upstream commit the oracle is built at (scripts/pin.env).
const Pin = "2731b35f7abb26ec926517274f3d87e78d42fd76"

// Database directory names under .cache/db/ (scripts/fetch-db.sh).
const (
	Viral     = "k2_viral_20260626"
	Standard8 = "k2_standard_08_GB_20260626"
)

// ModuleRoot returns the directory holding go.mod above the working directory, or "".
func ModuleRoot() string {
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// Root returns the shared root holding .oracle/ and .cache/, or "" if none is found.
func Root() string {
	for _, v := range []string{"AWS_KRAKEN2_ROOT", "K2_SHARED_ROOT"} {
		if r := os.Getenv(v); r != "" {
			return r
		}
	}
	mod := ModuleRoot()
	if mod == "" {
		return ""
	}
	out, err := exec.Command("git", "-C", mod, "rev-parse", "--path-format=absolute", "--git-common-dir").Output()
	if err != nil {
		return mod
	}
	return filepath.Dir(strings.TrimSpace(string(out)))
}

func skip(t testing.TB, format string, args ...any) {
	t.Helper()
	if os.Getenv("AWS_KRAKEN2_REQUIRE_ORACLE") == "1" {
		t.Fatalf(format, args...)
	}
	t.Skipf(format, args...)
}

func need(t testing.TB, p string) string {
	t.Helper()
	if _, err := os.Stat(p); err != nil {
		skip(t, "oracle artifact absent: %s", p)
	}
	return p
}

// Need returns Root()/rel, skipping the test if that path does not exist.
func Need(t testing.TB, rel string) string {
	t.Helper()
	root := Root()
	if root == "" {
		skip(t, "oracle root not found")
	}
	return need(t, filepath.Join(root, rel))
}

// Upstream returns the path of a binary in the pinned upstream install (scripts/oracle-build.sh).
func Upstream(t testing.TB, name string) string {
	t.Helper()
	return Need(t, filepath.Join(".oracle", Pin, name))
}

// Harness returns the path of a built oracle harness in this checkout
// (scripts/harness-build.sh <name>).
func Harness(t testing.TB, name string) string {
	t.Helper()
	mod := ModuleRoot()
	if mod == "" {
		skip(t, "module root not found")
	}
	return need(t, filepath.Join(mod, ".oracle", "harness", name))
}

// Reads returns the path of a cached read file, e.g. Reads(t, "SRR062634_200000_1.fq").
func Reads(t testing.TB, name string) string {
	t.Helper()
	return Need(t, filepath.Join(".cache", "reads", name))
}

// DB returns a database directory with a complete taxo.k2d, hash.k2d and opts.k2d (a database
// still being fetched lacks SOURCE, which fetch-db.sh writes last), skipping if absent.
func DB(t testing.TB, name string) string {
	t.Helper()
	dir := Need(t, filepath.Join(".cache", "db", name))
	for _, f := range []string{"SOURCE", "taxo.k2d", "hash.k2d", "opts.k2d"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			skip(t, "database %s incomplete: no %s", name, f)
		}
	}
	return dir
}
