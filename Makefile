# Every repeatable process is a target here, backed by a script in scripts/ and a runbook in docs/.
include scripts/pin.env
export UPSTREAM_REPO UPSTREAM_PIN

GO      ?= go
BIN     := bin
PKGS    := ./...

.PHONY: build test lint oracle ami run orphans report

build:
	$(GO) build -trimpath -o $(BIN)/ ./cmd/...

test:
	$(GO) test $(PKGS)

lint:
	$(GO) vet $(PKGS)
	staticcheck $(PKGS)

oracle:
	scripts/oracle.sh

ami:
	scripts/ami.sh

run:
	scripts/run.sh "$(GATE)" "$(SPEC)"

orphans:
	scripts/orphans.sh

report:
	scripts/report.sh "$(GATE)" "$(RUN)"
