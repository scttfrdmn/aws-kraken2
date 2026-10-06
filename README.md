# aws-kraken2

An experiment, not a product.

**Question:** how much performance and $/result does stock
[kraken2](https://github.com/DerrickWood/kraken2) leave unused on AWS on real science workloads,
and which levers account for it?

The engine is a Go port of kraken2's classification path. Its outputs are byte-identical to
upstream at a pinned commit (`2731b35`), and it runs over a sharded, resident hash table. Results
are reported as time-vs-$ Pareto frontiers per cohort size, for this engine and for upstream at its
best, with the gain attributed to individual levers.

Planning, gates and results discussion live in the
[GitHub project](https://github.com/scttfrdmn/aws-kraken2/issues). Raw results are under
[`results/`](results/). Process runbooks are under [`docs/`](docs/).

## Build

```bash
make build    # Go binaries into bin/
make test     # unit tests
make lint     # go vet + staticcheck
make oracle   # build upstream at the pin, run the byte-identity matrix (see docs/oracle.md)
```

## License

MIT, matching upstream. Ported files keep Derrick Wood's copyright notice and name their upstream
source file and commit.
