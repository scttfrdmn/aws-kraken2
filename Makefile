# Every repeatable process is a target here, backed by a script in scripts/ and a runbook in docs/.
include scripts/pin.env
export UPSTREAM_REPO UPSTREAM_PIN

GO      ?= go
BIN     := bin
PKGS    := ./...

.PHONY: build test lint oracle harness oracle-classify ami run orphans report

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
	scripts/harness-build.sh "$(NAME)"

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
