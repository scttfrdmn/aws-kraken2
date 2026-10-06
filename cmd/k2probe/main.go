// Command k2probe holds the G0 probes. Subcommands:
//
//	equiv-scan   compare internal/mmscan with upstream's MinimizerScanner (issue #5)
package main

import (
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	var err error
	switch os.Args[1] {
	case "equiv-scan":
		err = equivScan(os.Args[2:])
	default:
		usage()
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "k2probe:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: k2probe equiv-scan [flags] opts.k2d FILE...")
	os.Exit(2)
}
