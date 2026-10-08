# Every repeatable process is a target here, backed by a script in scripts/ and a runbook in docs/.
include scripts/pin.env
export UPSTREAM_REPO UPSTREAM_PIN

GO      ?= go
BIN     := bin
PKGS    := ./...

.PHONY: g2 build test lint oracle oracle-engine oracle-cohort rehearse g3-spec g3-tables stage-cohort stage-db stage-reads ami run orphans report harness g0b g0c equiv-seqout oracle-classify bracken-check tag-objects sortfuzz loadbench

build:
	$(GO) build -trimpath -ldflags "-X main.upstreamPin=$(UPSTREAM_PIN)" -o $(BIN)/ ./cmd/...

test:
	$(GO) test $(PKGS)
	python3 scripts/lib/errexit_check.py --self-test
	bash scripts/lib/harness_poll_test.sh
	bash scripts/lib/run_multi_test.sh

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
	python3 scripts/lib/g3_campaign.py

# Rehearse a cohort spec locally before any launch (docs/cohort.md, "Rehearsal"): the spec's own
# body as N nodes (default 3) under the harness's env, every output against upstream.
rehearse:
	case "$(or $(SPEC),runs/g3-e1.json)" in runs/g3-e1.json) scripts/lib/e1_rehearse.sh runs/g3-e1.json $(or $(N),3) ;; \
	  runs/g3-u1-*) scripts/lib/u_rehearse.sh $(SPEC) ;; \
	  runs/g3-u2-*) scripts/lib/u2_rehearse.sh $(SPEC) ;; \
	  *) scripts/lib/cohort_rehearse.sh $(SPEC) $(or $(N),3) ;; esac

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

orphans:
	scripts/orphans.sh

report:
	scripts/report.sh "$(GATE)" "$(RUN)"

# Bracken spot-check (issue #19, docs/bracken-check.md): Bracken on upstream's vs our --report.
bracken-check:
	scripts/bracken-check.sh
