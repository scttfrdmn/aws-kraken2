# make build / make test / make lint

**What:** `build` compiles every `cmd/` binary into `bin/` (`-trimpath`, no cgo in the core path).
`test` runs the Go unit tests and the self-test of `scripts/lib/errexit_check.py`. `lint` runs `go vet` and `staticcheck`.

**Inputs:** the Go toolchain named in `go.mod`; `staticcheck` on `PATH`.

**Outputs:** `bin/<command>`; test and lint output on stdout.

**Failure looks like:** a non-zero exit with the compiler, test or linter message. Unit tests may
use synthetic data (Law 3); anything they need that is large or real (databases, reads) belongs in
`make oracle` instead, and tests that need it must `t.Skip` when it is absent, never fail.
