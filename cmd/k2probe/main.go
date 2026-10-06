// Command k2probe decodes kraken2 database metadata for the G0 probes.
//
//	k2probe header [-size N] FILE   decode a hash.k2d header (FILE may be just its first 32 bytes)
//	k2probe opts FILE               decode opts.k2d
//
// Output is JSON on stdout. Any inconsistency is a non-zero exit with the reason on stderr.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
)

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "k2probe:", err)
		os.Exit(1)
	}
}

const usage = "usage: k2probe header [-size N] FILE | k2probe opts FILE"

func run(args []string, out io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("%s", usage)
	}
	switch args[0] {
	case "header":
		return header(args[1:], out)
	case "opts":
		return opts(args[1:], out)
	default:
		return fmt.Errorf("unknown subcommand %q; %s", args[0], usage)
	}
}

type headerOut struct {
	kdb.HashHeader
	ObjectSize int64   `json:"object_size"`
	CellBits   int     `json:"cell_bits"`
	CellBytes  int     `json:"cell_bytes"`
	LoadFactor float64 `json:"load_factor"`
}

func header(args []string, out io.Writer) error {
	fs := flag.NewFlagSet("header", flag.ContinueOnError)
	size := fs.Int64("size", -1, "size in bytes of the whole hash.k2d object (default: FILE's size)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("%s", usage)
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

type optsOut struct {
	kdb.Options
	SpacedSeedMaskHex string `json:"spaced_seed_mask_hex"`
	ToggleMaskHex     string `json:"toggle_mask_hex"`
}

func opts(args []string, out io.Writer) error {
	if len(args) != 1 {
		return fmt.Errorf("%s", usage)
	}
	f, err := os.Open(args[0])
	if err != nil {
		return err
	}
	defer f.Close()
	o, err := kdb.ReadOptions(f)
	if err != nil {
		return err
	}
	return emit(out, optsOut{
		Options:           o,
		SpacedSeedMaskHex: fmt.Sprintf("%#016x", o.SpacedSeedMask),
		ToggleMaskHex:     fmt.Sprintf("%#016x", o.ToggleMask),
	})
}

func emit(out io.Writer, v any) error {
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
