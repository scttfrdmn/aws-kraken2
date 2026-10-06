// Package oracletest locates the shared oracle artifacts (upstream build, harnesses, pinned
// databases, real reads) for tests that compare against upstream. Those live in the main
// checkout's .oracle/ and .cache/, which git worktrees under .claude/worktrees/ do not have, so
// the lookup walks up from the working directory. Set AWS_KRAKEN2_ROOT to override.
// Tests that need an artifact must t.Skip when it is absent (docs/build.md).
package oracletest

import (
	"os"
	"path/filepath"
	"testing"
)

// Pin is the upstream commit the oracle is built at (scripts/pin.env).
const Pin = "2731b35f7abb26ec926517274f3d87e78d42fd76"

// Database directory names under .cache/db/ (scripts/fetch-db.sh).
const (
	Viral     = "k2_viral_20260626"
	Standard8 = "k2_standard_08_GB_20260626"
)

// Root returns the directory holding .oracle/ or .cache/, or "" if none is found.
func Root() string {
	if r := os.Getenv("AWS_KRAKEN2_ROOT"); r != "" {
		return r
	}
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for {
		for _, d := range []string{".oracle", ".cache"} {
			if fi, err := os.Stat(filepath.Join(dir, d)); err == nil && fi.IsDir() {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// Need returns Root()/rel, skipping the test if that path does not exist.
func Need(t testing.TB, rel string) string {
	t.Helper()
	root := Root()
	if root == "" {
		t.Skipf("oracle root not found (no .oracle/ or .cache/ above the working directory)")
	}
	p := filepath.Join(root, rel)
	if _, err := os.Stat(p); err != nil {
		t.Skipf("oracle artifact absent: %s", p)
	}
	return p
}

// Upstream returns the path of a binary in the pinned upstream install (scripts/oracle-build.sh).
func Upstream(t testing.TB, name string) string {
	t.Helper()
	return Need(t, filepath.Join(".oracle", Pin, name))
}

// Harness returns the path of a built oracle harness (scripts/harness-build.sh <name>).
func Harness(t testing.TB, name string) string {
	t.Helper()
	return Need(t, filepath.Join(".oracle", "harness", name))
}

// DB returns a database directory with a complete taxo.k2d, hash.k2d and opts.k2d (a database
// still being fetched lacks SOURCE, which fetch-db.sh writes last), skipping if absent.
func DB(t testing.TB, name string) string {
	t.Helper()
	dir := Need(t, filepath.Join(".cache", "db", name))
	for _, f := range []string{"SOURCE", "taxo.k2d", "hash.k2d", "opts.k2d"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Skipf("database %s incomplete: no %s", name, f)
		}
	}
	return dir
}
