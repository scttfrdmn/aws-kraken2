// Ported from DerrickWood/kraken2 src/compact_hash.h at 2731b35f7abb26ec926517274f3d87e78d42fd76.
// Original: Copyright 2013-2023, Derrick Wood <dwood@cs.jhu.edu>. MIT License.
// Go port: Copyright 2026 aws-kraken2 contributors. MIT License.

package chash

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"syscall"
	"unsafe"

	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
)

// Options configure a table load.
type Options struct {
	// Mode is the probe sequence; the zero value is Linear, upstream's default build.
	Mode Mode
	// ReadThreads is the number of concurrent pread streams Load uses (upstream's
	// K2_DB_READ_THREADS; default 8). Ignored by Mmap.
	ReadThreads int
}

// Table is a loaded hash.k2d. It is safe for concurrent lookups.
type Table struct {
	Header Header
	Layout Layout
	Mode   Mode

	cells32 []uint32 // CompactHashCell cells (4-byte layout), aliases region
	cells40 []byte   // CompactHashCell40 cells (5-byte packed layout), aliases region
	region  []byte   // the mapping that backs the cells; released by Close
	mask    uint32
	shiftK  uint // 64 - key_bits
}

// Load reads hash.k2d fully into memory with concurrent pread streams over disjoint chunks, as
// upstream's LoadTable does without memory mapping.
func Load(path string, opt Options) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	threads := opt.ReadThreads
	if threads <= 0 {
		threads = 8
	}
	return LoadFrom(f, st.Size(), path, ParallelPread{File: f, Streams: threads}, opt.Mode)
}

// A Filler copies the bytes of a hash.k2d image into memory: Fill writes len(dst) bytes,
// starting at byte off of the image, into dst. LoadFrom allocates the table (off-heap, 2 MiB
// aligned, huge-page advised) and hands it to a Filler, so every loader (the parallel pread
// here, a later S3 ranged-GET loader) fills the same kind of buffer. Fill may write dst from
// several goroutines; it must not retain dst.
type Filler interface {
	Fill(dst []byte, off int64) error
}

// ParallelPread fills from File with Streams concurrent pread calls over disjoint chunks, like
// upstream's pread_parallel. Streams < 1 means 1.
type ParallelPread struct {
	File    *os.File
	Streams int
}

// Fill implements Filler.
func (p ParallelPread) Fill(dst []byte, off int64) error {
	return preadParallel(p.File, dst, off, max(p.Streams, 1))
}

// LoadFrom loads a hash.k2d image of size bytes: the header through r, the cells through
// fill. name labels errors.
func LoadFrom(r io.ReaderAt, size int64, name string, fill Filler, mode Mode) (*Table, error) {
	h, l, err := readHeader(r, size, name)
	if err != nil {
		return nil, err
	}
	n := int(l.FileSize() - HeaderSize)
	buf, region, err := allocTable(n)
	if err != nil {
		return nil, fmt.Errorf("chash: allocate %d bytes for %s: %w", n, name, err)
	}
	if err := fill.Fill(buf, HeaderSize); err != nil {
		_ = syscall.Munmap(region)
		return nil, fmt.Errorf("chash: read %s: %w", name, err)
	}
	return newTable(h, l, mode, buf, region)
}

// hugePage is the alignment upstream gives the table (posix_memalign to 2 MiB) so that
// MADV_HUGEPAGE can back it with transparent huge pages.
const hugePage = 2 << 20

// allocTable returns n bytes of anonymous memory for the cells, and the mapping that backs
// them (what Close unmaps). Anonymous memory needs no Go-side zeroing pass over a multi-GB
// table, and the GC never scans it. As upstream's LoadTable, the cells start on a 2 MiB
// boundary and, where the OS has transparent huge pages, are advised MADV_HUGEPAGE before the
// reads fault them in (adviseHuge; issue #36). Without the advice, a kernel whose THP mode is
// "madvise" (Amazon Linux 2023's default) backs the table with 4 KiB pages: one fault per
// 4 KiB during the load, and as many page-table entries to tear down at exit.
func allocTable(n int) (cells, region []byte, err error) {
	region, err = syscall.Mmap(-1, 0, n+hugePage, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_ANON|syscall.MAP_PRIVATE)
	if err != nil {
		return nil, nil, err
	}
	// The slack before and after the aligned span is never touched, so it costs no memory.
	off := int(-uintptr(unsafe.Pointer(unsafe.SliceData(region))) & (hugePage - 1))
	cells = region[off : off+n : off+n]
	adviseHuge(cells)
	return cells, region, nil
}

// Mmap maps hash.k2d read-only, as upstream's LoadTable does with memory mapping.
func Mmap(path string, opt Options) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	h, l, err := readHeader(f, st.Size(), path)
	if err != nil {
		return nil, err
	}
	m, err := syscall.Mmap(int(f.Fd()), 0, int(l.FileSize()), syscall.PROT_READ, syscall.MAP_SHARED)
	if err != nil {
		return nil, fmt.Errorf("chash: mmap %s: %w", path, err)
	}
	return newTable(h, l, opt.Mode, m[HeaderSize:], m)
}

// FromBytes builds a table over an in-memory hash.k2d image (header plus cells). The image is
// aliased, not copied. Intended for tests and small tables.
func FromBytes(image []byte, mode Mode) (*Table, error) {
	h, err := ParseHeader(image)
	if err != nil {
		return nil, err
	}
	l, _ := h.Layout()
	if uint64(len(image)) != l.FileSize() {
		return nil, fmt.Errorf("chash: image is %d bytes, header implies %d", len(image), l.FileSize())
	}
	cells := image[HeaderSize:]
	if l.CellBytes == 4 && len(cells) > 0 && uintptr(unsafe.Pointer(&cells[0]))%4 != 0 {
		cells = append([]byte(nil), cells...) // realign (Go allocations are 8-byte aligned)
	}
	return newTable(h, l, mode, cells, nil)
}

func readHeader(r io.ReaderAt, size int64, path string) (Header, Layout, error) {
	var hb [HeaderSize]byte
	if _, err := r.ReadAt(hb[:], 0); err != nil {
		return Header{}, Layout{}, fmt.Errorf("chash: read header of %s: %w", path, err)
	}
	h, err := ParseHeader(hb[:])
	if err != nil {
		return Header{}, Layout{}, fmt.Errorf("%s: %w", path, err)
	}
	l, _ := h.Layout()
	// The size cross-check is kdb's (checked arithmetic), as upstream's "Capacity mismatch".
	if _, err := kdb.CellWidth(kdb.HashHeader(h), size); err != nil {
		return Header{}, Layout{}, fmt.Errorf("chash: capacity mismatch in %s: %w", path, err)
	}
	return h, l, nil
}

var littleEndianHost = binary.NativeEndian.Uint16([]byte{1, 0}) == 1

func newTable(h Header, l Layout, mode Mode, cells, region []byte) (*Table, error) {
	if !littleEndianHost {
		if region != nil {
			_ = syscall.Munmap(region)
		}
		return nil, errors.New("chash: big-endian hosts are not supported")
	}
	if mode != Linear && mode != Double {
		return nil, fmt.Errorf("chash: invalid mode %d", int(mode))
	}
	t := &Table{Header: h, Layout: l, Mode: mode, region: region, mask: l.valueMask(), shiftK: 64 - l.KeyBits}
	if l.CellBytes == 4 {
		t.cells32 = unsafe.Slice((*uint32)(unsafe.Pointer(unsafe.SliceData(cells))), l.Capacity)
	} else {
		t.cells40 = cells[:l.Capacity*5]
	}
	return t, nil
}

// preadParallel fills buf from f at base using `threads` concurrent ReadAt (pread) calls over
// disjoint chunks, like upstream's pread_parallel.
func preadParallel(f *os.File, buf []byte, base int64, threads int) error {
	n := len(buf)
	chunk := (n + threads - 1) / threads
	var wg sync.WaitGroup
	errs := make([]error, threads)
	for t := 0; t < threads; t++ {
		start := t * chunk
		if start >= n {
			break
		}
		end := min(start+chunk, n)
		wg.Add(1)
		go func(t, start, end int) {
			defer wg.Done()
			_, err := f.ReadAt(buf[start:end], base+int64(start))
			if err == io.EOF {
				err = io.ErrUnexpectedEOF
			}
			errs[t] = err
		}(t, start, end)
	}
	wg.Wait()
	return errors.Join(errs...)
}

// Close releases the table's memory. The table must not be used afterwards.
func (t *Table) Close() error {
	r := t.region
	t.region, t.cells32, t.cells40 = nil, nil, nil
	if r == nil {
		return nil
	}
	return syscall.Munmap(r)
}

// Cell implements CellSource over the loaded cells.
func (t *Table) Cell(idx uint64) (uint64, error) {
	if idx >= t.Layout.Capacity {
		return 0, fmt.Errorf("chash: cell %d out of range (capacity %d)", idx, t.Layout.Capacity)
	}
	if t.cells32 != nil {
		return uint64(t.cells32[idx]), nil
	}
	c := t.cells40[idx*5 : idx*5+5]
	return uint64(binary.LittleEndian.Uint32(c)) | uint64(c[4])<<32, nil
}

// Get is upstream's Get: the stored value (0 on a miss) and the number of cells examined, which
// is at least 1 on a hit or a miss.
func (t *Table) Get(key uint64) (value uint32, probes int) {
	value, probes, _ = t.Find(key)
	return value, probes
}

// Find is Get that also returns the final index (FindIndex's *idx; see Probe).
func (t *Table) Find(key uint64) (value uint32, probes int, idx uint64) {
	hc := MurmurHash3(key)
	if t.cells32 == nil {
		v, p, i, _ := Probe(t.Layout, t.Mode, hc, t) // in-memory cells cannot fail
		return v, p, i
	}
	cells := t.cells32
	capacity := t.Layout.Capacity
	vb := t.Layout.ValueBits
	mask := t.mask
	compacted := hc >> t.shiftK
	idx = hc % capacity
	first := idx
	if t.Mode == Linear {
		// Same sequence as (idx + 1) % capacity, without a divide per step.
		for {
			d := cells[idx]
			probes++
			v := d & mask
			if v == 0 {
				return 0, probes, idx
			}
			if uint64(d>>vb) == compacted {
				return v, probes, idx
			}
			if idx++; idx == capacity {
				idx = 0
			}
			if idx == first {
				return 0, probes, idx
			}
		}
	}
	var step uint64
	for {
		d := cells[idx]
		probes++
		v := d & mask
		if v == 0 {
			return 0, probes, idx
		}
		if uint64(d>>vb) == compacted {
			return v, probes, idx
		}
		if step == 0 {
			step = t.Mode.step(hc)
		}
		idx = (idx + step) % capacity
		if idx == first {
			return 0, probes, idx
		}
	}
}
