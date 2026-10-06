//go:build !linux

package chash

// adviseHuge is a no-op where there is no MADV_HUGEPAGE (upstream compiles the madvise out).
func adviseHuge([]byte) {}
