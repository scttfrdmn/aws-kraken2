package main

// Phase timings (issue #36). Off by default, so the default stderr stays upstream's. With
// AK2_TIMINGS=1 each phase boundary writes one tab-separated line to stderr:
//
//	ak2-timing <phase> <start_s> <seconds> <minflt> <majflt> <user_s> <sys_s>
//
// start_s is the phase's start relative to the first timestamp the process takes (package
// initialisation); minflt/majflt/user_s/sys_s are the process's getrusage deltas over the
// phase. scripts/loadbench.sh parses these lines. AK2_CPUPROFILE=<file> writes a pprof CPU
// profile of the whole run.

import (
	"fmt"
	"os"
	"runtime/pprof"
	"syscall"
	"time"
)

var (
	timingsOn   = os.Getenv("AK2_TIMINGS") == "1"
	processT0   = time.Now()
	cpuProfile  *os.File
	cpuProfPath = os.Getenv("AK2_CPUPROFILE")
)

type phaseMark struct {
	name string
	t    time.Time
	ru   syscall.Rusage
}

// phase starts timing a phase; call end on the result. It costs nothing when timings are off.
func phase(name string) *phaseMark {
	if !timingsOn {
		return nil
	}
	p := &phaseMark{name: name, t: time.Now()}
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &p.ru)
	return p
}

func (p *phaseMark) end() {
	if p == nil {
		return
	}
	now := time.Now()
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	tv := func(a, b syscall.Timeval) float64 {
		return float64(b.Sec-a.Sec) + float64(b.Usec-a.Usec)/1e6
	}
	fmt.Fprintf(os.Stderr, "ak2-timing\t%s\t%.6f\t%.6f\t%d\t%d\t%.6f\t%.6f\n", p.name,
		p.t.Sub(processT0).Seconds(), now.Sub(p.t).Seconds(),
		ru.Minflt-p.ru.Minflt, ru.Majflt-p.ru.Majflt, tv(p.ru.Utime, ru.Utime), tv(p.ru.Stime, ru.Stime))
}

// startProfile starts the CPU profile if AK2_CPUPROFILE names a file; stopProfile ends it.
func startProfile() {
	if cpuProfPath == "" {
		return
	}
	f, err := os.Create(cpuProfPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: AK2_CPUPROFILE: %v\n", prog, err)
		return
	}
	if err := pprof.StartCPUProfile(f); err != nil {
		fmt.Fprintf(os.Stderr, "%s: AK2_CPUPROFILE: %v\n", prog, err)
		f.Close()
		return
	}
	cpuProfile = f
}

func stopProfile() {
	if cpuProfile == nil {
		return
	}
	pprof.StopCPUProfile()
	cpuProfile.Close()
	cpuProfile = nil
}
