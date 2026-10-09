# make build / make test / make lint

**What:** `build` compiles every `cmd/` binary into `bin/` (`-trimpath`, no cgo in the core path).
`test` runs the Go unit tests and the self-test of `scripts/lib/errexit_check.py`. `lint` runs `go vet` and `staticcheck`.

**Inputs:** the Go toolchain named in `go.mod`; `staticcheck` on `PATH`.

**Outputs:** `bin/<command>`; test and lint output on stdout.

**Failure looks like:** a non-zero exit with the compiler, test or linter message. Unit tests may
use synthetic data (Law 3); anything they need that is large or real (databases, reads) belongs in
`make oracle` instead, and tests that need it must `t.Skip` when it is absent, never fail.

**Decompression (#48):** `make test` unsets `AK2_DECOMPRESS` for the Go tests, so a value
exported in your shell has no effect there. `TestOracleSeqout` and `TestOracleDecompress` read the
shared `.cache/equiv-seqout/latest`, which `make equiv-seqout` moves only for a PASS with the
default decompressor ([equiv-seqout.md](equiv-seqout.md)). The tests fail loudly in three cases:
`latest` records another decompressor, it did not pass, or `AK2_DECOMPRESS` is set in a plain
`go test`. To check pipe mode, run it through `make equiv-seqout`.
