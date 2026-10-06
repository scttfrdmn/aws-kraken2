package main

import (
	"fmt"
	"os"

	"github.com/scttfrdmn/aws-kraken2/internal/kdb"
)

func init() {
	commands["opts"] = command{summary: "decode opts.k2d; JSON on stdout", run: opts}
}

type optsOut struct {
	kdb.Options
	SpacedSeedMaskHex string `json:"spaced_seed_mask_hex"`
	ToggleMaskHex     string `json:"toggle_mask_hex"`
}

func opts(args []string) error {
	out := os.Stdout
	if len(args) != 1 {
		return fmt.Errorf("usage: k2probe opts FILE")
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
