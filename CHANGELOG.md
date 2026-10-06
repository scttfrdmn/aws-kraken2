# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Repository bootstrap: license, changelog, CLAUDE.md with the experiment's laws, make targets.
- Run harness: `make run` (`scripts/run.sh`, on-instance hygiene preamble `scripts/preamble.sh`,
  settings `scripts/ak2.env`), `make orphans`, `make report`, with runbooks `docs/run.md`,
  `docs/orphans.md`, `docs/report.md` and the spore.host brief `docs/spore-host.md` (#1).
- `internal/kdb`: `opts.k2d` (IndexOptions, legacy 48/56-byte layouts), `hash.k2d` header, and
  32/40-bit cell-width detection cross-checked against object size; `cmd/k2probe header|opts` (#3).
- G0a spec `runs/g0a.json`, post-processing `scripts/post/g0a.sh`, and its runs under
  `results/g0a/` (#3).
- Harness hardening from the law review:
  - a bucket allow-list (`AK2_DATASETS`), checked statically and on the instance by an `aws`
    PATH shim;
  - `inputs[]` refused in favour of `ak2_stage`;
  - the wrong-region launch is terminated;
  - disowned log tee and pusher;
  - Payer, TTL and cost ceilings, env-key and dirty-tree refusals;
  - a `drop_caches` probe;
  - `ak2_phase` timings and `ak2_req` request counts;
  - an all-region orphan sweep;
  - an ETag check in `scripts/post/g0a.sh`.
- Re-review fixes:
  - a finish handler that survives a process-group SIGTERM and logs the real exit status;
  - a checked log-tee start;
  - `set -e` refused in specs;
  - `ak2_req` validation;
  - `cold` markers in `phases.tsv`, with `ak2_drop_caches` fatal (exit 95) when caches can't be
    dropped;
  - placement/spot refused, an env-key allow-list, and a wider dirty-tree check;
  - in-flight phases recorded on a kill;
  - `readonly -f` on the helpers.
- Follow-ups:
  - a shell-aware errexit check (`scripts/lib/errexit_check.py`, self-tested in `make test`),
    backed by runtime `$-` checks;
  - a PIPE trap;
  - `ak2_req` bucket validation;
  - helper errors and state kept in files, so subshell errors count;
  - KILL for a hung tee;
  - shim content and self-test verification.
