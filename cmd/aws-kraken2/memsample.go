package main

// Memory samples (G3, #25): with AK2_TIMINGS=1, every AK2_MEM_EVERY seconds (default 15) one line
// on stderr, so a run killed for memory still leaves its trajectory in the streamed log:
//
//	ak2-engine mem t_s <s> rss_kib <n> hwm_kib <n> heap_inuse <bytes> sys <bytes> avail_kib <n>
//
// rss_kib and hwm_kib are /proc/self/status's VmRSS and VmHWM, avail_kib /proc/meminfo's
// MemAvailable (Linux; -1 elsewhere); heap_inuse and sys are the Go runtime's.

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

func procKiB(path, key string) int64 {
	f, err := os.Open(path)
	if err != nil {
		return -1
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		t := sc.Text()
		if strings.HasPrefix(t, key+":") {
			fs := strings.Fields(t[len(key)+1:])
			if len(fs) > 0 {
				if v, err := strconv.ParseInt(fs[0], 10, 64); err == nil {
					return v
				}
			}
		}
	}
	return -1
}

func memLine() string {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	return fmt.Sprintf("ak2-engine\tmem\tt_s\t%.1f\trss_kib\t%d\thwm_kib\t%d\theap_inuse\t%d\tsys\t%d\tavail_kib\t%d\n",
		time.Since(processT0).Seconds(), procKiB("/proc/self/status", "VmRSS"), procKiB("/proc/self/status", "VmHWM"),
		ms.HeapInuse, ms.Sys, procKiB("/proc/meminfo", "MemAvailable"))
}

// startMemSampler starts the sampler once (timings on only).
var memSamplerStarted bool

func startMemSampler() {
	if !timingsOn || memSamplerStarted {
		return
	}
	memSamplerStarted = true
	every := 15 * time.Second
	if v, err := strconv.ParseFloat(os.Getenv("AK2_MEM_EVERY"), 64); err == nil && v > 0 {
		every = time.Duration(v * float64(time.Second))
	}
	go func() {
		for {
			time.Sleep(every)
			fmt.Fprint(os.Stderr, memLine())
		}
	}()
}
