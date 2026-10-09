# Every repeatable process is a target here, backed by a script in scripts/ and a runbook in docs/.
include scripts/pin.env
export UPSTREAM_REPO UPSTREAM_PIN

GO      ?= go
BIN     := bin
PKGS    := ./...

.PHONY: dryrun-userdata util-stream-test util util-backfill instance-types g2 build test lint oracle oracle-engine oracle-cohort rehearse g3-spec g3-tables g3-frontier g3-law1-u2 bash-jobs-test hitorder-golden hitorderfuzz stage-cohort stage-db stage-reads ami run orphans report harness g0b g0c equiv-seqout oracle-classify bracken-check tag-objects sortfuzz loadbench

build:
	$(GO) build -trimpath -ldflags "-X main.upstreamPin=$(UPSTREAM_PIN)" -o $(BIN)/ ./cmd/...

test:
	$(GO) test $(PKGS)
	python3 scripts/lib/errexit_check.py --self-test
	python3 scripts/lib/util_test.py
	bash scripts/lib/harness_poll_test.sh
	bash scripts/lib/run_multi_test.sh
	bash scripts/lib/quota_check_test.sh
	bash scripts/lib/run_sh_test.sh

lint:
	$(GO) vet $(PKGS)
	staticcheck $(PKGS)

# Law 1 end to end (docs/oracle.md): DB=viral|standard8|all.
DB ?= viral
oracle:
	scripts/oracle.sh $(DB)

# Law 1 through the sharded engine (docs/oracle.md, "Engine mode", #24): every oracle case, ours
# at each shard count in NS (default 1 2 3 4 8), TRANSPORT=local|tcp|procs (procs: N processes
# over loopback, the multi-node engine), TAIL=<cells> (default 302).
oracle-engine:
	ORACLE_ENGINE="$(or $(NS),1 2 3 4 8)" ORACLE_ENGINE_TRANSPORT=$(or $(TRANSPORT),local) \
		ORACLE_ENGINE_TAIL=$(TAIL) scripts/oracle.sh $(DB)

# Oracle harnesses (docs/harness.md): NAME="a b" builds those (default all); VARIANTS=lp|dh|lp,dh.
VARIANTS ?= lp
harness:
	scripts/harness-build.sh -v $(VARIANTS) $(NAME)

# G0b equivalence (docs/g0b.md). G0B (or PART) = hash|scan|all; G0B_DBS, G0B_SCAN_READS and
# G0B_RUN_ID pass through the env.
G0B ?= $(or $(PART),all)
g0b:
	scripts/g0b.sh $(G0B)

# Load-path and whole-process wall, upstream vs ours, cold and warm (docs/loadbench.md, #36).
# DB=viral|standard8|<dir> (default standard8), THREADS (8), REPS (3); LB_* pass through the env.
loadbench:
	LB_DB=$(if $(filter command line environment,$(origin DB)),$(DB),$(or $(LB_DB),standard8)) \
		LB_THREADS=$(or $(THREADS),$(LB_THREADS),8) LB_REPS=$(or $(REPS),$(LB_REPS),3) \
		scripts/loadbench.sh

# G2 baselines and H-knee sweep (docs/g2.md, #21-#23). PART=local (smoke test on the viral DB) or
# PART=summary DIR=results/g2/<run>/out/g2 (rebuild summary.md). The measurements are AWS runs:
# make run GATE=g2 SPEC=runs/g2-nvme.json | runs/g2-ram.json | runs/g2-c8gd.json | runs/g2-c9gd.json.
g2:
	scripts/g2.sh $(or $(PART),local) $(DIR)

# G0c run lengths and probe lengths (docs/g0c.md). PART = local|probes|runs; DRY_RUN passes through.
g0c:
	scripts/g0c.sh "$(PART)"

# In-region copy of a pinned database for runs in us-west-2 (docs/oracle.md, "Canonical run").
stage-db:
	scripts/stage-db.sh $(DB)

# Law 1 for the engine's cohort mode (docs/oracle.md, "Cohort mode", #25): upstream per sample vs
# the engine's cohort at N=1, N=3 sample-parallel, N=3 block-striped and N=3 through the SDK path.
oracle-cohort:
	scripts/oracle-cohort.sh $(DB)

# G3 campaign specs (docs/cohort.md, "The G3 campaign"): EXP TYPE N COHORT [ARGS="KEY=VALUE ..."],
# and the campaign's generated tables (results/g3/campaign/).
g3-spec:
	scripts/g3/mkspec.sh $(EXP) $(TYPE) $(N) $(COHORT) $(ARGS)

g3-tables:
	python3 scripts/lib/g3_memory.py
	python3 scripts/lib/g3_campaign.py

# The H-main frontier: ours vs upstream at its best per cohort size, regime and axis, with the
# registered references and the kill condition (results/g3/campaign/frontier.{tsv,md}).
g3-frontier: g3-tables
	python3 scripts/lib/g3_frontier.py

# Real-S3 check of ak2etag.py (multipart and single-part) and Law 1 of the engine's sample 1
# against U2's upstream sha256s (scripts/lib/law1_u2.sh; downloads about 1 GB).
g3-law1-u2:
	scripts/lib/law1_u2.sh $(E) $(U)

# The bash job-control check in AL2023's bash (podman): the body's old wait patterns must fail
# there and the current fetch and lanes must pass (scripts/tests/bash_jobs.sh).
bash-jobs-test:
	scripts/bash-jobs-test.sh

# #44: regenerate the HitCounts golden data (upstream/umap_order.cc under AL2023's g++, podman;
# docs/hitorder.md).
hitorder-golden:
	scripts/hitorder-golden.sh

# #44: HitCounts vs std::unordered_map under AL2023's g++ 11.5.0, differential fuzz
# (docs/hitorderfuzz.md): HITORDERFUZZ=quick|full|selftest.
HITORDERFUZZ ?= quick
hitorderfuzz:
	scripts/hitorderfuzz.sh $(HITORDERFUZZ)

# Rehearse a cohort spec locally before any launch (docs/cohort.md, "Rehearsal"): the spec's own
# body as N nodes (default 3) under the harness's env, every output against upstream. First, the
# utilisation sampler must stream on every one of N nodes (make util-stream-test; docs/util.md).
rehearse: util-stream-test
	case "$(or $(SPEC),runs/g3-e1.json)" in runs/g3-e1.json) scripts/lib/e1_rehearse.sh runs/g3-e1.json $(or $(N),3) ;; \
	  runs/g3-u1-*) scripts/lib/u_rehearse.sh $(SPEC) ;; \
	  runs/g3-u2-*) scripts/lib/u2_rehearse.sh $(SPEC) ;; \
	  runs/g3-diag44-*) scripts/lib/diag44_rehearse.sh $(SPEC) ;; \
	  runs/g3-probe-*) scripts/lib/probe_rehearse.sh $(SPEC) ;; \
	  *) scripts/lib/cohort_rehearse.sh $(SPEC) $(or $(N),3) ;; esac

# Utilisation (docs/util.md): the sampler streams log/util.tsv on N AL2023 nodes (podman) running
# run.sh's stub and preamble, checked on the uploads; BREAK=nopush|nostub are negative controls.
util-stream-test:
	scripts/lib/util_stream_test.sh $(or $(N),3)

# tables/util.tsv for one run or cohort dir (DIR=results/<gate>/<run>); run.sh, run-multi.sh and
# make report do this themselves.
util:
	python3 scripts/lib/util.py $(DIR)

# Lower-bound utilisation of the results/g2 and results/g3 runs that predate the sampler, from what
# their logs recorded (results/util-backfill/util-backfill.tsv; docs/util.md). $0: reads results/ only.
util-backfill:
	python3 scripts/lib/util_backfill.py

# describe-instance-types for every instance type in results/ (results/instance-types/<region>.json).
instance-types:
	scripts/instance-types.sh

# The G3 sweep's real cohort (docs/cohort.md, #25): PART=record (once, before use) or stage
# (default), PROJECT (default PRJNA398089), COUNT (record: 1000; stage: 10).
stage-cohort:
	scripts/stage-cohort.sh $(or $(PART),stage) $(or $(PROJECT),PRJNA398089) $(COUNT)

# In-region copy of the oracle's read subsets (docs/oracle.md, "Canonical run").
stage-reads:
	scripts/stage-reads.sh

# seqio/seqout oracle (docs/equiv-seqout.md).
equiv-seqout:
	scripts/equiv-seqout.sh

# Byte-identity of internal/classify's --output against upstream (issues #13, #14).
CLASSIFY_ORACLE ?= .cache/classify
oracle-classify:
	scripts/classify-oracle.sh "$(CLASSIFY_ORACLE)"
	K2_CLASSIFY_ORACLE="$(abspath $(CLASSIFY_ORACLE))" $(GO) test -count=1 -v -run Equiv \
		./internal/classify/ > "$(CLASSIFY_ORACLE)/equiv.log" 2>&1; s=$$?; \
		cat "$(CLASSIFY_ORACLE)/equiv.log"; exit $$s

# Object tags on everything under the project's S3 prefix (docs/tag-objects.md).
tag-objects:
	scripts/tag-objects.sh $(PREFIX)

# stdSort vs libstdc++ std::sort, differential fuzz (docs/sortfuzz.md, #35): SORTFUZZ=quick|full.
SORTFUZZ ?= quick
sortfuzz:
	scripts/sortfuzz.sh $(SORTFUZZ)

ami:
	scripts/ami.sh

# NODES=<n>: a cohort of n coordinated instances, one run.sh run each (scripts/run-multi.sh;
# docs/run.md, "Multi-node runs").
run:
	$(if $(NODES),scripts/run-multi.sh "$(GATE)" "$(SPEC)" "$(NODES)",scripts/run.sh "$(GATE)" "$(SPEC)")

# DRY_RUN=1 of every runs/*.json plus GEN="EXP TYPE N COHORT; ..." generated campaign specs, with
# user-data size and vCPU quota per spec (results/rehearse/dryrun-userdata-<ts>-<sha>.tsv; docs/run.md).
dryrun-userdata:
	GEN="$(GEN)" scripts/dryrun-userdata.sh

orphans:
	scripts/orphans.sh

report:
	scripts/report.sh "$(GATE)" "$(RUN)"

# Bracken spot-check (issue #19, docs/bracken-check.md): Bracken on upstream's vs our --report.
bracken-check:
	scripts/bracken-check.sh
