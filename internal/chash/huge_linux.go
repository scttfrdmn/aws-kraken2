package chash

import "syscall"

// adviseHuge is upstream's madvise(table_, table_bytes, MADV_HUGEPAGE). Like upstream, it
// ignores the result: without THP the table still loads, on base pages.
func adviseHuge(b []byte) {
	if len(b) > 0 {
		_ = syscall.Madvise(b, syscall.MADV_HUGEPAGE)
	}
}
