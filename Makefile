# Every repeatable process is a target here, backed by a script in scripts/ and a runbook in docs/.
include scripts/pin.env
export UPSTREAM_REPO UPSTREAM_PIN

GO      ?= go
BIN     := bin
PKGS    := ./...

.PHONY: build test lint oracle ami run orphans report harness g0b

build:
	$(GO) build -trimpath -o $(BIN)/ ./cmd/...

test:
	$(GO) test $(PKGS)

lint:
	$(GO) vet $(PKGS)
	staticcheck $(PKGS)

oracle:
	scripts/oracle.sh

harness:
	scripts/harness-build.sh

# G0b equivalence (docs/g0b.md). G0B=hash|all; G0B_DBS and G0B_RUN_ID pass through the env.
G0B ?= all
g0b:
	scripts/g0b.sh $(G0B)

ami:
	scripts/ami.sh

run:
	scripts/run.sh "$(GATE)" "$(SPEC)"

orphans:
	scripts/orphans.sh

report:
	scripts/report.sh "$(GATE)" "$(RUN)"
