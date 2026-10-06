# Every repeatable process is a target here, backed by a script in scripts/ and a runbook in docs/.
include scripts/pin.env
export UPSTREAM_REPO UPSTREAM_PIN

GO      ?= go
BIN     := bin
PKGS    := ./...

.PHONY: build test lint oracle ami run orphans report harness g0b equiv-seqout

build:
	$(GO) build -trimpath -o $(BIN)/ ./cmd/...

test:
	$(GO) test $(PKGS)

lint:
	$(GO) vet $(PKGS)
	staticcheck $(PKGS)

oracle:
	scripts/oracle.sh

# Oracle harnesses (docs/g0b.md): NAME="a b" builds those (default all), DH=1 adds .dh variants.
harness:
	scripts/harness-build.sh $(if $(DH),--dh) $(NAME)

# G0b equivalence (docs/g0b.md). G0B (or PART) = hash|scan|all; G0B_DBS, G0B_SCAN_READS and
# G0B_RUN_ID pass through the env.
G0B ?= $(or $(PART),all)
g0b:
	scripts/g0b.sh $(G0B)

# seqio/seqout oracle (docs/equiv-seqout.md).
equiv-seqout:
	scripts/equiv-seqout.sh

ami:
	scripts/ami.sh

run:
	scripts/run.sh "$(GATE)" "$(SPEC)"

orphans:
	scripts/orphans.sh

report:
	scripts/report.sh "$(GATE)" "$(RUN)"
