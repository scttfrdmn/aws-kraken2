package kdb

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/scttfrdmn/aws-kraken2/internal/oracletest"
)

func header(capacity, size, kb, vb uint64) []byte {
	b := make([]byte, 32)
	binary.LittleEndian.PutUint64(b[0:], capacity)
	binary.LittleEndian.PutUint64(b[8:], size)
	binary.LittleEndian.PutUint64(b[16:], kb)
	binary.LittleEndian.PutUint64(b[24:], vb)
	return b
}

func TestReadHashHeader(t *testing.T) {
	h, err := ReadHashHeader(bytes.NewReader(header(1000, 700, 17, 15)))
	if err != nil {
		t.Fatal(err)
	}
	want := HashHeader{Capacity: 1000, Size: 700, KeyBits: 17, ValueBits: 15}
	if h != want {
		t.Fatalf("got %+v want %+v", h, want)
	}
	if _, err := ReadHashHeader(bytes.NewReader(make([]byte, 31))); err == nil {
		t.Fatal("short header accepted")
	}
}

func TestCellWidth(t *testing.T) {
	cases := []struct {
		name    string
		h       HashHeader
		size    int64
		want    int
		wantErr string
	}{
		{"32-bit", HashHeader{1000, 10, 17, 15}, 32 + 4000, 32, ""},
		{"40-bit packed", HashHeader{1000, 10, 24, 16}, 32 + 5000, 40, ""},
		{"bits say 32, size says 40", HashHeader{1000, 10, 17, 15}, 32 + 5000, 0, "fits 40-bit"},
		{"bits say 40, size says 32", HashHeader{1000, 10, 24, 16}, 32 + 4000, 0, "fits 32-bit"},
		{"off by one", HashHeader{1000, 10, 17, 15}, 32 + 4001, 0, "!="},
		{"unknown width", HashHeader{1000, 10, 20, 16}, 32 + 4500, 0, "neither 32 nor 40"},
		{"zero value bits", HashHeader{1000, 10, 32, 0}, 32 + 4000, 0, "non-zero"},
		{"size > capacity", HashHeader{1000, 1001, 17, 15}, 32 + 4000, 0, "exceeds capacity"},
		{"header only", HashHeader{1000, 10, 17, 15}, 32, 0, "!="},
		{"overflow", HashHeader{1 << 62, 0, 17, 15}, 1 << 40, 0, "overflows"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := CellWidth(c.h, c.size)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err = %v, want containing %q", err, c.wantErr)
				}
				return
			}
			if err != nil || got != c.want {
				t.Fatalf("got %d, %v; want %d", got, err, c.want)
			}
		})
	}
}

// opts builds a full 64-byte IndexOptions image with garbage in the padding, as upstream's
// uninitialised padding leaves it.
func opts() []byte {
	b := bytes.Repeat([]byte{0xAA}, 64)
	le := binary.LittleEndian
	le.PutUint64(b[0:], 35)
	le.PutUint64(b[8:], 31)
	le.PutUint64(b[16:], 0x3FFFFFFFFFFFFFFF)
	le.PutUint64(b[24:], 0xe37e28c4271b5a2d)
	b[32] = 1
	le.PutUint64(b[40:], 7)
	le.PutUint32(b[48:], 1)
	le.PutUint32(b[52:], 2)
	le.PutUint32(b[56:], 3)
	return b
}

func TestParseOptionsFull(t *testing.T) {
	o, err := ParseOptions(opts())
	if err != nil {
		t.Fatal(err)
	}
	want := Options{K: 35, L: 31, SpacedSeedMask: 0x3FFFFFFFFFFFFFFF, ToggleMask: 0xe37e28c4271b5a2d,
		DNADB: true, DNADBByte: 1, MinimumAcceptableHashValue: 7, RevcomVersion: 1, DBVersion: 2, DBType: 3,
		FileSize: 64, Absent: []string{}, Layout: "v2.1.0+", Padding: []string{}}
	if !reflect.DeepEqual(o, want) {
		t.Fatalf("got %+v\nwant %+v", o, want)
	}
}

func TestParseOptionsLegacy(t *testing.T) {
	// 56 bytes: no db_type. 52: no db_version either. 48: no revcom_version (pre-2.0.8).
	for _, c := range []struct {
		n       int
		absent  []string
		layout  string
		padding []string
	}{
		{56, []string{"db_type"}, "v2.0.8-v2.0.9", []string{"db_version"}},
		{52, []string{"db_version", "db_type"}, "unrecognised", []string{}},
		{48, []string{"revcom_version", "db_version", "db_type"}, "pre-v2.0.8", []string{}},
	} {
		o, err := ParseOptions(opts()[:c.n])
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(o.Absent, c.absent) || o.FileSize != c.n || o.Layout != c.layout ||
			!reflect.DeepEqual(o.Padding, c.padding) {
			t.Fatalf("n=%d: absent %v size %d layout %q padding %v", c.n, o.Absent, o.FileSize, o.Layout, o.Padding)
		}
		if c.n <= 56 && o.DBType != 0 {
			t.Fatalf("n=%d: db_type %d, want zero as upstream", c.n, o.DBType)
		}
		if c.n <= 48 && (o.RevcomVersion != 0 || o.DBVersion != 0) {
			t.Fatalf("n=%d: trailing fields not zero: %+v", c.n, o)
		}
		if o.K != 35 || o.L != 31 || !o.DNADB {
			t.Fatalf("n=%d: leading fields wrong: %+v", c.n, o)
		}
	}
}

// A 56-byte file from a v2.0.8-v2.0.9 build: the 4 tail-padding bytes after revcom_version
// are uninitialised and the pin reads them as db_version, exactly as here.
func TestParseOptionsLegacyPadding(t *testing.T) {
	b := opts()[:56]
	copy(b[52:], []byte{0xd0, 0x7f, 0, 0})
	o, err := ParseOptions(b)
	if err != nil {
		t.Fatal(err)
	}
	if o.DBVersion != 0x7fd0 || o.DBType != 0 || o.RevcomVersion != 1 {
		t.Fatalf("got db_version %d db_type %d revcom %d", o.DBVersion, o.DBType, o.RevcomVersion)
	}
}

func TestReadOptionsTooLong(t *testing.T) {
	if _, err := ReadOptions(bytes.NewReader(make([]byte, 65))); err == nil {
		t.Fatal("65-byte opts accepted")
	}
	if _, err := ReadOptions(bytes.NewReader(nil)); err == nil {
		t.Fatal("empty opts accepted")
	}
}

// findViral is the shared Viral DB (internal/oracletest); a missing DB fails the test when the
// oracle is required.
func findViral(t *testing.T) string {
	t.Helper()
	return oracletest.DB(t, oracletest.Viral)
}

func TestViralDB(t *testing.T) {
	db := findViral(t)
	f, err := os.Open(filepath.Join(db, "opts.k2d"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	o, err := ReadOptions(f)
	if err != nil {
		t.Fatal(err)
	}
	// Expected values are from upstream's own inspect.txt shipped with the DB: k = 35, l = 31,
	// nucleotide, table size 113651066, capacity 162183314, min clear hash value 0.
	if o.K != 35 || o.L != 31 || !o.DNADB || o.RevcomVersion != 1 || o.FileSize != 64 || len(o.Absent) != 0 {
		t.Fatalf("viral opts: %+v", o)
	}
	if o.SpacedSeedMask != 0x3FFFFFFFF3333333 || o.ToggleMask != 0xe37e28c4271b5a2d {
		t.Fatalf("viral masks: %#x %#x", o.SpacedSeedMask, o.ToggleMask)
	}
	hf, err := os.Open(filepath.Join(db, "hash.k2d"))
	if err != nil {
		t.Fatal(err)
	}
	defer hf.Close()
	st, err := hf.Stat()
	if err != nil {
		t.Fatal(err)
	}
	h, err := ReadHashHeader(hf)
	if err != nil {
		t.Fatal(err)
	}
	w, err := CellWidth(h, st.Size())
	if err != nil {
		t.Fatal(err)
	}
	if w != 32 || h.Capacity != 162183314 || h.Size != 113651066 || o.MinimumAcceptableHashValue != 0 {
		t.Fatalf("viral hash: width %d header %+v", w, h)
	}
}
