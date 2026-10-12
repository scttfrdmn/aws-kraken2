package chash

import (
	"os"
	"path/filepath"
	"runtime/debug"
	"testing"
	"unsafe"
)

// The --memory-mapping regression (ladder O0 at c1, 843e958: 1466 GiB peak against upstream's
// 1125 GiB on a 1.1 TB tmpfs table): Mmap's cells must be the file's own pages, mapped shared
// and read-only, never a copy in process memory. The probes: the cells alias the mapping; a
// write to them faults; and on Linux, after every cell has been read, /proc/self/smaps shows the
// mapping shared (ms: MAP_SHARED; Linux drops sh for a file opened read-only), not writable or
// may-write (no wr, mw), resident, with no anonymous memory: a copy (or a copy-on-write fault)
// is anonymous. Private_Dirty is not a criterion: page-cache and tmpfs pages mapped by one
// process count there while dirty, which is not a copy. Load's table is the negative control each
// probe must tell apart (writable; anonymous once filled).

// mmapFixture writes a synthetic 32-bit table of about 4 MiB (two 2 MiB huge pages' worth, so
// smaps' sizes are well above a page) and returns its path.
func mmapFixture(t *testing.T) string {
	t.Helper()
	img, _ := synth(t, 1<<20, 16, 16, 4, Linear, 600000, 7)
	path := filepath.Join(t.TempDir(), "hash.k2d")
	if err := os.WriteFile(path, img, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// touchAll reads every cell, faulting the whole table in.
func touchAll(t *testing.T, tab *Table) {
	t.Helper()
	var sum uint64
	for i := uint64(0); i < tab.Layout.Capacity; i++ {
		c, err := tab.Cell(i)
		if err != nil {
			t.Fatal(err)
		}
		sum += c
	}
	if sum == 0 {
		t.Fatal("table is empty")
	}
}

// writeFaults reports whether a store to b[0] faults (and leaves b unchanged if it does not).
func writeFaults(b []byte) (faulted bool) {
	old := debug.SetPanicOnFault(true)
	defer debug.SetPanicOnFault(old)
	defer func() {
		if recover() != nil {
			faulted = true
		}
	}()
	p := (*byte)(unsafe.Pointer(unsafe.SliceData(b)))
	v := *p
	*(*byte)(unsafe.Pointer(p)) = v ^ 0xff
	*(*byte)(unsafe.Pointer(p)) = v
	return false
}

func TestMmapSharedReadOnly(t *testing.T) {
	path := mmapFixture(t)
	m, err := Mmap(path, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	if !m.Mapped() {
		t.Fatal("Mmap's table does not report Mapped")
	}
	touchAll(t, m)
	st, _ := os.Stat(path)
	if int64(len(m.region)) != st.Size() {
		t.Fatalf("mapping is %d bytes, the file %d", len(m.region), st.Size())
	}
	if unsafe.Pointer(unsafe.SliceData(m.cells32)) != unsafe.Pointer(&m.region[HeaderSize]) {
		t.Fatal("Mmap's cells do not alias the file mapping (a copy?)")
	}
	if !writeFaults(m.region[HeaderSize:]) {
		t.Fatal("a write to Mmap's cells did not fault: the mapping is writable")
	}

	l, err := Load(path, Options{ReadThreads: 2})
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if l.Mapped() {
		t.Fatal("Load's table reports Mapped")
	}
	touchAll(t, l)
	if writeFaults(l.region) {
		t.Fatal("negative control: a write to Load's (anonymous) table faulted, so the write probe cannot tell the two apart")
	}

	sm, ok := smapsOf(t, m.region)
	if !ok {
		t.Log("no /proc/self/smaps here: the alias and write-fault probes stand alone")
		return
	}
	t.Logf("Mmap smaps: %+v", sm)
	if !sm.mayShare || sm.writable {
		t.Errorf("Mmap's mapping VmFlags %q: want MAP_SHARED (ms), neither wr nor mw", sm.flags)
	}
	if sm.anonKB != 0 {
		t.Errorf("Mmap's mapping holds %d kB anonymous after a full scan; want 0 (no copy)", sm.anonKB)
	}
	if sm.rssKB < int64(len(m.region)/1024)/2 {
		t.Errorf("Mmap's mapping is only %d kB resident after a full scan of %d kB: the probe did not fault it in", sm.rssKB, len(m.region)/1024)
	}
	lm, _ := smapsOf(t, l.region)
	t.Logf("Load smaps: %+v", lm)
	if lm.mayShare || lm.anonKB < int64(len(l.cells32)*4/1024)/2 {
		t.Errorf("negative control: Load's filled table shows %d kB anonymous; the smaps probe cannot resolve a copy", lm.anonKB)
	}
}
