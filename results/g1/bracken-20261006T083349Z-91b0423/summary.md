# make bracken-check: 20261006T083349Z

Bracken v3.1 (`cfeac04b6445c44c3825866683a6fdd18746cb58`, Python 3.14.8) on the
`--report` of upstream `kraken2` at `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35) and of
`bin/aws-kraken2` at `91b0423b87c7a3e50a391aaaf9e8e6070590091f` (dirty: false), same arguments,
DB k2_standard_08_GB_20260626 (ETag 815577bbfd245c6e337f1bea41fae968-709), `-r 100 -t 10`,
levels S G. Host: juno, Darwin arm64 (Mac16,6); local development host (not Linux aarch64); acceptable for this spot-check (#19).

**Result: PASS** — 22 of 22 byte comparisons identical (22 expected).

| sample | level | file | bytes (upstream) | identical |
|---|---|---|---|---|
| ERR478965 | - | kraken.report | 83635 | yes |
| ERR478965 | - | kraken.out | 11775412 | yes |
| ERR478965 | - | kraken.exit | 2 | yes |
| ERR478965 | S | bracken -o | 7368 | yes |
| ERR478965 | S | bracken --out-report | 17673 | yes |
| ERR478965 | S | bracken stdout (time lines removed) | 553 | yes |
| ERR478965 | S | bracken stderr | 39 | yes |
| ERR478965 | G | bracken -o | 3357 | yes |
| ERR478965 | G | bracken --out-report | 8376 | yes |
| ERR478965 | G | bracken stdout (time lines removed) | 551 | yes |
| ERR478965 | G | bracken stderr | 39 | yes |
| SRR062634 | - | kraken.report | 7963 | yes |
| SRR062634 | - | kraken.out | 15511495 | yes |
| SRR062634 | - | kraken.exit | 2 | yes |
| SRR062634 | S | bracken -o | 201 | yes |
| SRR062634 | S | bracken --out-report | 2584 | yes |
| SRR062634 | S | bracken stdout (time lines removed) | 546 | yes |
| SRR062634 | S | bracken stderr | 39 | yes |
| SRR062634 | G | bracken -o | 179 | yes |
| SRR062634 | G | bracken --out-report | 2411 | yes |
| SRR062634 | G | bracken stdout (time lines removed) | 546 | yes |
| SRR062634 | G | bracken stderr | 39 | yes |

What Bracken did on the upstream side (from its stdout), showing the comparison could resolve a difference:

| sample | level | rows in -o table | taxa at level | above threshold | reads distributed |
|---|---|---|---|---|---|
| ERR478965 | S | 143 | 579 | 143 | 24479 |
| ERR478965 | G | 82 | 319 | 82 | 10451 |
| SRR062634 | S | 2 | 18 | 2 | 478 |
| SRR062634 | G | 2 | 23 | 2 | 478 |

Low resolution (fewer than 10 taxa above threshold, so few redistributions to disagree on): SRR062634 S (2), SRR062634 G (2).
