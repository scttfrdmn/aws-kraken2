package main

// Cohort mode (G3, #25; docs/engine.md "Cohort mode"): one engine process per node runs a whole
// sample list, with the table (or the node's shard) loaded once.
//
//	AK2_COHORT=<manifest> aws-kraken2 [common arguments]
//
// The manifest is tab-separated, one sample per line ('#' comments and blank lines skipped):
//
//	batch  inflight  mode  s3client  name  argument…
//
//   - batch: batches run in order; within a multi-node run every node finishes a batch before
//     any starts the next (a rendezvous barrier), so batches can be timed apart;
//   - inflight: samples a node runs at once (sample-parallel batches);
//   - mode: parallel (the default design: sample j of a batch has home node j mod N, which reads,
//     classifies and writes it alone, its lookups routed to every shard) or striped (every node
//     takes every N-th block of the sample and rank 0 emits it, as a single multi-node
//     invocation does: one control session per sample, the shards kept);
//   - s3client: sdk | cli | - (AK2_S3_CLIENT) for the sample's s3:// outputs;
//   - argument…: the sample's own kraken2 arguments (outputs, inputs, options), appended to the
//     common arguments. Each sample is parsed and run exactly as a separate invocation with
//     those arguments would be, so its outputs are byte-identical to upstream's for them
//     (make oracle-cohort). Every sample must name its --output (standard output is shared).
//
// All samples must use the same database. Each sample ends with one line on stderr:
//
//	ak2-sample batch <k> name <s> mode <m> s3client <c> rank <r> role <home|emitter|peer>
//	  inflight <i> threads <t> start_s <s> wall_s <s> setup_s <s> classify_s <s> close_s <s>
//	  report_s <s> status <exit> sequences <n> bases <n> classified <n>
//
// The process exits 0 if every sample on every node exited 0, else 1 (after the batch in which
// a sample failed: fail fast at batch granularity).

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/scttfrdmn/aws-kraken2/internal/engine"
)

// sampleRec is one sample's phase times and counts (classifyArgs.rec).
type sampleRec struct {
	mu     sync.Mutex
	phases map[string]time.Duration
	st     stats
}

func (r *sampleRec) add(name string, d time.Duration) {
	r.mu.Lock()
	if r.phases == nil {
		r.phases = map[string]time.Duration{}
	}
	r.phases[name] += d
	r.mu.Unlock()
}

func (r *sampleRec) sec(name string) float64 {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.phases[name].Seconds()
}

type cohortLine struct {
	line            int
	batch, inflight int
	mode, s3client  string
	name            string
	args            []string
	c               *classifyArgs
}

func parseCohort(path string) ([]*cohortLine, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []*cohortLine
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	n, lastBatch := 0, -1
	seen := map[string]bool{}
	for sc.Scan() {
		n++
		t := sc.Text()
		if strings.TrimSpace(t) == "" || strings.HasPrefix(t, "#") {
			continue
		}
		fs := strings.Split(t, "\t")
		if len(fs) < 6 {
			return nil, fmt.Errorf("%s:%d: want batch, inflight, mode, s3client, name and arguments", path, n)
		}
		b, err1 := strconv.Atoi(fs[0])
		inf, err2 := strconv.Atoi(fs[1])
		if err1 != nil || err2 != nil || b < 0 || inf < 1 {
			return nil, fmt.Errorf("%s:%d: batch %q, inflight %q", path, n, fs[0], fs[1])
		}
		if b < lastBatch {
			return nil, fmt.Errorf("%s:%d: batch %d after batch %d (batches must be in order)", path, n, b, lastBatch)
		}
		lastBatch = b
		l := &cohortLine{line: n, batch: b, inflight: inf, mode: fs[2], s3client: fs[3], name: fs[4], args: fs[5:]}
		switch l.mode {
		case "parallel", "striped":
		default:
			return nil, fmt.Errorf("%s:%d: mode %q: want parallel or striped", path, n, l.mode)
		}
		switch l.s3client {
		case "sdk", "cli":
		case "-":
			l.s3client = ""
		default:
			return nil, fmt.Errorf("%s:%d: s3client %q: want sdk, cli or -", path, n, l.s3client)
		}
		if l.name == "" || strings.ContainsAny(l.name, " /") || seen[l.name] {
			return nil, fmt.Errorf("%s:%d: sample name %q (empty, with a space or /, or repeated)", path, n, l.name)
		}
		seen[l.name] = true
		out = append(out, l)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: no samples", path)
	}
	// One mode, inflight and client per batch.
	for i := 1; i < len(out); i++ {
		a, b := out[i-1], out[i]
		if a.batch == b.batch && (a.mode != b.mode || a.inflight != b.inflight || a.s3client != b.s3client) {
			return nil, fmt.Errorf("%s:%d: batch %d mixes modes, inflight or clients", path, b.line, b.batch)
		}
	}
	return out, nil
}

// runCohort runs a cohort manifest (see the file comment).
func runCohort(path string, common []string, env func(string) (string, bool)) int {
	if env == nil {
		env = os.LookupEnv
	}
	lines, err := parseCohort(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: AK2_COHORT: %v\n", prog, err)
		return exUsage
	}
	// Every sample's arguments are checked before anything is loaded.
	var db *classifyArgs
	for _, l := range lines {
		argv := append(append([]string{}, common...), l.args...)
		c, st := buildArgs(argv, env)
		if c == nil {
			fmt.Fprintf(os.Stderr, "%s: AK2_COHORT: sample %s (line %d): its arguments end the run with %d\n", prog, l.name, l.line, st)
			return st
		}
		if c.kraken2Output == nil || *c.kraken2Output == "" {
			fmt.Fprintf(os.Stderr, "%s: AK2_COHORT: sample %s (line %d) has no --output (standard output is shared)\n", prog, l.name, l.line)
			return exUsage
		}
		if db == nil {
			db = c
		}
		if c.hashFile != db.hashFile || c.taxoFile != db.taxoFile || c.optsFile != db.optsFile {
			fmt.Fprintf(os.Stderr, "%s: AK2_COHORT: sample %s (line %d) uses another database\n", prog, l.name, l.line)
			return exUsage
		}
		c.env = env
		c.s3client = l.s3client
		l.c = c
	}
	ec, err := engineFromEnv(env)
	if err != nil || ec == nil {
		fmt.Fprintf(os.Stderr, "%s: AK2_COHORT needs the engine (AK2_ENGINE_N): %v\n", prog, err)
		return exUsage
	}
	first := lines[0].c
	idx, st := loadIndex(first)
	if idx == nil {
		return st
	}
	defer idx.close()
	rank, n := 0, 1
	cc := ec.cluster
	if cc != nil {
		rank, n = cc.rank, ec.n
	}
	failed := 0
	for i := 0; i < len(lines); {
		j := i
		for j < len(lines) && lines[j].batch == lines[i].batch {
			j++
		}
		batch := lines[i:j]
		failed += runBatch(idx, cc, rank, n, batch)
		if cc != nil {
			// The batch barrier: every node finishes the batch first; failures anywhere end
			// the cohort here.
			p := phase("batch-barrier-" + strconv.Itoa(batch[0].batch))
			total, err := cohortBarrier(cc, n, fmt.Sprintf("b%d-done", batch[0].batch), failed)
			p.end()
			if err != nil {
				fmt.Fprintf(os.Stderr, "%s: cohort: %v\n", prog, err)
				return exitFailure
			}
			failed = total
		}
		if failed > 0 {
			fmt.Fprintf(os.Stderr, "%s: cohort: %d sample(s) failed by batch %d; stopping\n", prog, failed, batch[0].batch)
			idx.eng.report()
			return exitFailure
		}
		i = j
	}
	idx.eng.report()
	return 0
}

// runBatch runs one batch's samples that fall to this node, and returns how many failed.
func runBatch(idx *index, cc *clusterConf, rank, n int, batch []*cohortLine) int {
	mode := batch[0].mode
	if cc == nil {
		mode = "parallel" // one process holds every shard: nothing to stripe across
	}
	var mu sync.Mutex
	failed := 0
	if mode == "parallel" {
		sem := make(chan struct{}, batch[0].inflight)
		var wg sync.WaitGroup
		for j, l := range batch {
			if j%n != rank {
				continue
			}
			wg.Add(1)
			sem <- struct{}{}
			go func() {
				defer wg.Done()
				defer func() { <-sem }()
				if st := runSample(idx, l, nil, rank, "home"); st != 0 {
					mu.Lock()
					failed++
					mu.Unlock()
				}
			}()
		}
		wg.Wait()
		return failed
	}
	for j, l := range batch {
		inputs := len(l.c.files)
		if l.c.paired {
			inputs /= 2
		}
		nd, err := startSession(context.Background(), cc, n, inputs, fmt.Sprintf("%s/b%d-s%d", cc.rendezvous, l.batch, j))
		if err != nil {
			fmt.Fprintf(os.Stderr, "%s: cohort: sample %s: %v\n", prog, l.name, err)
			failed++
			continue
		}
		role := "peer"
		if nd.emitter {
			role = "emitter"
		}
		if st := runSample(idx, l, nd, rank, role); st != 0 {
			failed++
		}
		nd.closeControl()
	}
	return failed
}

// runSample runs one sample and prints its ak2-sample line.
func runSample(idx *index, l *cohortLine, nd *node, rank int, role string) int {
	c := *l.c // each run gets its own copy of the arguments
	c.pre, c.node, c.rec = idx, nd, &sampleRec{}
	t0 := time.Now()
	st := classifyRun(&c)
	wall := time.Since(t0)
	r := c.rec
	fmt.Fprintf(os.Stderr, "ak2-sample\tbatch\t%d\tname\t%s\tmode\t%s\ts3client\t%s\trank\t%d\trole\t%s\tinflight\t%d\tthreads\t%d"+
		"\tstart_s\t%.6f\twall_s\t%.6f\tsetup_s\t%.6f\tclassify_s\t%.6f\tclose_s\t%.6f\treport_s\t%.6f"+
		"\tstatus\t%d\tsequences\t%d\tbases\t%d\tclassified\t%d\n",
		l.batch, l.name, l.mode, orDash(l.s3client), rank, role, l.inflight, c.threads,
		t0.Sub(processT0).Seconds(), wall.Seconds(), r.sec("setup"), r.sec("classify"), r.sec("close"), r.sec("report"),
		st, r.st.sequences, r.st.bases, r.st.classified)
	return st
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// cohortBarrier is a rendezvous every node publishes its failure count to, and returns the sum.
func cohortBarrier(cc *clusterConf, n int, name string, failed int) (int, error) {
	rv, err := engine.NewRendezvous(cc.rendezvous + "/" + name)
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), cc.timeout)
	defer cancel()
	if err := rv.Publish(ctx, engine.Peer{Rank: cc.rank, N: n, PID: os.Getpid(), Status: failed}); err != nil {
		return 0, err
	}
	peers, err := rv.Wait(ctx, n)
	if err != nil {
		return 0, err
	}
	total := 0
	for _, p := range peers {
		total += p.Status
	}
	return total, nil
}
