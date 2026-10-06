package main

import (
	"fmt"
	"io"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// The kraken2 wrapper parses its command line with Perl's Getopt::Long in its default
// configuration, and ignores GetOptions' return value: a bad option is a warning and the run
// goes on. This is the subset of that behaviour the wrapper's option table needs:
//
//   - options may appear anywhere ("permute"); "--" ends them; a lone "-" is an argument;
//   - one or two leading dashes; names are case-insensitive and may be abbreviated to any
//     unique prefix (an exact match wins over prefixes);
//   - "--name=value" or "--name value"; a string option takes the next argument even if it
//     begins with "-"; an integer (=i) or real (=f) option consumes the next argument and
//     warns if it is not a number;
//   - unknown and ambiguous names, and an argument given to a flag, are warnings.

type optKind int

const (
	optFlag optKind = iota
	optString
	optInt
	optFloat
)

type optSpec struct {
	name string
	kind optKind
	// set receives the value (ignored for flags). It is called in command-line order, so a
	// handler such as --help that exits does so at the point Getopt::Long would call it.
	set func(v string)
}

var (
	perlInt   = regexp.MustCompile(`^[-+]?[0-9]+$`)
	perlFloat = regexp.MustCompile(`^[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?$`)
)

// getOptions parses args against specs, writing Getopt::Long's warnings to warn, and returns
// the non-option arguments in order.
func getOptions(args []string, specs []optSpec, warn io.Writer) []string {
	var rest []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "--" {
			rest = append(rest, args[i+1:]...)
			break
		}
		if len(a) < 2 || a[0] != '-' {
			rest = append(rest, a)
			continue
		}
		body := strings.TrimPrefix(strings.TrimPrefix(a, "-"), "-")
		name, val, hasVal := strings.Cut(body, "=")
		spec, err := lookupOpt(specs, name)
		if err != nil {
			fmt.Fprintln(warn, err)
			continue
		}
		if spec.kind == optFlag {
			if hasVal {
				fmt.Fprintf(warn, "Option %s does not take an argument\n", spec.name)
				continue
			}
			spec.set("1")
			continue
		}
		if !hasVal {
			if i+1 >= len(args) {
				fmt.Fprintf(warn, "Option %s requires an argument\n", spec.name)
				continue
			}
			i++
			val = args[i]
		}
		switch spec.kind {
		case optInt:
			if !perlInt.MatchString(val) {
				fmt.Fprintf(warn, "Value \"%s\" invalid for option %s (number expected)\n", val, spec.name)
				continue
			}
		case optFloat:
			if !perlFloat.MatchString(val) {
				fmt.Fprintf(warn, "Value \"%s\" invalid for option %s (real number expected)\n", val, spec.name)
				continue
			}
		}
		spec.set(val)
	}
	return rest
}

func lookupOpt(specs []optSpec, name string) (*optSpec, error) {
	lname := strings.ToLower(name)
	var matches []*optSpec
	for i := range specs {
		if specs[i].name == lname {
			return &specs[i], nil
		}
		if strings.HasPrefix(specs[i].name, lname) {
			matches = append(matches, &specs[i])
		}
	}
	switch len(matches) {
	case 0:
		//lint:ignore ST1005 Getopt::Long's message, verbatim
		return nil, fmt.Errorf("Unknown option: %s", lname)
	case 1:
		return matches[0], nil
	}
	names := make([]string, len(matches))
	for i, m := range matches {
		names[i] = m.name
	}
	sort.Strings(names)
	//lint:ignore ST1005 Getopt::Long's message, verbatim
	return nil, fmt.Errorf("Option %s is ambiguous (%s)", name, strings.Join(names, ", "))
}

// perlAtoi is the integer value of a string Getopt::Long accepted as =i.
func perlAtoi(s string) int64 {
	n, err := strconv.ParseInt(strings.TrimPrefix(s, "+"), 10, 64)
	if err != nil {
		return 0
	}
	return n
}

// perlAtof is the value of a string Getopt::Long accepted as =f.
func perlAtof(s string) float64 {
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0
	}
	return f
}
