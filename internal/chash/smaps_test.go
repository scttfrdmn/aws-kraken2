package chash

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"testing"
	"unsafe"
)

// smaps is one /proc/self/smaps entry's memory accounting.
type smaps struct {
	flags              string
	mayShare, writable bool // ms; wr or mw
	rssKB, anonKB      int64
}

// smapsOf returns the smaps entry of the mapping that contains b[0]; false where the OS has no
// /proc/self/smaps (macOS).
func smapsOf(t *testing.T, b []byte) (smaps, bool) {
	t.Helper()
	f, err := os.Open("/proc/self/smaps")
	if err != nil {
		return smaps{}, false
	}
	defer f.Close()
	addr := uint64(uintptr(unsafe.Pointer(unsafe.SliceData(b))))
	var s smaps
	in := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		fs := strings.Fields(line)
		if len(fs) == 0 {
			continue
		}
		if r := strings.SplitN(fs[0], "-", 2); len(r) == 2 && !strings.HasSuffix(fs[0], ":") {
			lo, e1 := strconv.ParseUint(r[0], 16, 64)
			hi, e2 := strconv.ParseUint(r[1], 16, 64)
			if e1 == nil && e2 == nil {
				if in {
					break
				}
				in = addr >= lo && addr < hi
				continue
			}
		}
		if !in {
			continue
		}
		kb := func() int64 { v, _ := strconv.ParseInt(fs[1], 10, 64); return v }
		switch fs[0] {
		case "Rss:":
			s.rssKB = kb()
		case "Anonymous:":
			s.anonKB = kb()
		case "VmFlags:":
			s.flags = strings.Join(fs[1:], " ")
			for _, fl := range fs[1:] {
				s.mayShare = s.mayShare || fl == "ms"
				s.writable = s.writable || fl == "wr" || fl == "mw"
			}
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if s.flags == "" {
		t.Fatalf("no smaps entry contains %#x", addr)
	}
	return s, true
}
