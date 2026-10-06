# Every repeatable process is a target here, backed by a script in scripts/ and a runbook in docs/.
include scripts/pin.env
export UPSTREAM_REPO UPSTREAM_PIN

GO      ?= go
BIN     := bin
PKGS    := ./...

.PHONY: build test lint oracle stage-db stage-reads ami run orphans report harness g0b equiv-seqout oracle-classify bracken-check

build:
	$(GO) build -trimpath -ldflags "-X main.upstreamPin=$(UPSTREAM_PIN)" -o $(BIN)/ ./cmd/...

test:
	$(GO) test $(PKGS)
	python3 scripts/lib/errexit_check.py --self-test

lint:
	$(GO) vet $(PKGS)
	staticcheck $(PKGS)

# Law 1 end to end (docs/oracle.md): DB=viral|standard8|all.
DB ?= viral
oracle:
	scripts/oracle.sh $(DB)

# Oracle harnesses (docs/harness.md): NAME="a b" builds those (default all); VARIANTS=lp|dh|lp,dh.
VARIANTS ?= lp
harness:
	scripts/harness-build.sh -v $(VARIANTS) $(NAME)

# G0b equivalence (docs/g0b.md). G0B (or PART) = hash|scan|all; G0B_DBS, G0B_SCAN_READS and
# G0B_RUN_ID pass through the env.
G0B ?= $(or $(PART),all)
g0b:
	scripts/g0b.sh $(G0B)

# In-region copy of a pinned database for runs in us-west-2 (docs/oracle.md, "Canonical run").
stage-db:
	scripts/stage-db.sh $(DB)

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

ami:
	scripts/ami.sh

run:
	scripts/run.sh "$(GATE)" "$(SPEC)"

orphans:
	scripts/orphans.sh

report:
	scripts/report.sh "$(GATE)" "$(RUN)"

# Bracken spot-check (issue #19, docs/bracken-check.md): Bracken on upstream's vs our --report.
bracken-check:
	scripts/bracken-check.sh
