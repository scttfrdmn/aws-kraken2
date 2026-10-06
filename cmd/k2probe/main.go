// Command k2probe holds the G0 probes. Each subcommand lives in its own file and registers itself
// in commands from an init function.
package main

import (
	"fmt"
	"os"
	"sort"
)

type command struct {
	summary string
	run     func(args []string) error
}

var commands = map[string]command{}

func main() {
	if len(os.Args) < 2 || commands[os.Args[1]].run == nil {
		usage()
		os.Exit(2)
	}
	if err := commands[os.Args[1]].run(os.Args[2:]); err != nil {
		fmt.Fprintf(os.Stderr, "k2probe %s: %v\n", os.Args[1], err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: k2probe <command> [flags]")
	names := make([]string, 0, len(commands))
	for n := range commands {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Fprintf(os.Stderr, "  %-12s %s\n", n, commands[n].summary)
	}
}
