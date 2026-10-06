package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
)

func init() {
	commands["header"] = command{
		summary: "decode a hash.k2d header (FILE may be just its first 32 bytes); JSON on stdout",
		run:     header,
	}
}

type headerOut struct {
	kdb.HashHeader
	ObjectSize int64   `json:"object_size"`
	CellBits   int     `json:"cell_bits"`
	CellBytes  int     `json:"cell_bytes"`
	LoadFactor float64 `json:"load_factor"`
}

func header(args []string) error {
	out := os.Stdout
	fs := flag.NewFlagSet("header", flag.ContinueOnError)
	size := fs.Int64("size", -1, "size in bytes of the whole hash.k2d object (default: FILE's size)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("usage: k2probe header [-size N] FILE")
	}
	f, err := os.Open(fs.Arg(0))
	if err != nil {
		return err
	}
	defer f.Close()
	if *size < 0 {
		st, err := f.Stat()
		if err != nil {
			return err
		}
		*size = st.Size()
	}
	h, err := kdb.ReadHashHeader(f)
	if err != nil {
		return err
	}
	bits, err := kdb.CellWidth(h, *size)
	if err != nil {
		return err
	}
	return emit(out, headerOut{
		HashHeader: h, ObjectSize: *size, CellBits: bits, CellBytes: bits / 8,
		LoadFactor: float64(h.Size) / float64(h.Capacity),
	})
}

func emit(out io.Writer, v any) error {
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
