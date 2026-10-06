### g0c — run `20261006-095218-b27b55f`

| | |
|---|---|
| commit | `b27b55f0dba89f70fac98af6620bd0b42cbcac52` (tree dirty: false) |
| upstream pin | `2731b35f7abb26ec926517274f3d87e78d42fd76` (describe `2.17.2-20-g2731b35`) |
| spec | `runs/g0c-probes.json` (sha256 `cc0ad56f29c8`) |
| instance | 1 × `c7g.large` (on-demand), AMI `ami-09325776a00699513` |
| region / AZ | us-west-2 / us-west-2c |
| truffle price at launch | $0.0725/h |
| start → stop | 2026-10-06T09:53:10+00:00 → 2026-10-06T09:58:03Z (293 s) |
| cost | $0.005901 — on-demand truffle price x (terminated_at - launch_time), 60 s minimum; compute only, excludes EBS and S3 requests |
| TTL / cost_limit | 40m / $0.5 |
| task | state completed, exit 0, retry_class "" |
| shell flags | inherited `hBc`, after `set +e` `hBc` |
| preflight region | us-west-2, asserted equal to the region of each declared bucket (cookbook-942542972736-us-west-2, kraken2-ncbi-refseq-complete-v205) before the spec body ran |
| bucket allow-list | cookbook-942542972736-us-west-2, kraken2-ncbi-refseq-complete-v205. `aws s3`/`s3api` calls outside it were refused; curl and SDK calls are not covered |
| drop_caches usable | true |
| object tags | ok=true: tag-objects: s3://cookbook-942542972736-us-west-2/aws-kraken2/g0c/20261006-095218-b27b55f/: 17 objects, 16 tagged now, 1 already tagged, 0 failed |
| S3 requests (spec-recorded) | 40083 |
| sample accessions | SRR062634, ERR478965, ERR598966, SRR28305653 |
| tools | spawn 0.123.0, truffle 0.57.1 |

**Bucket Payer**

| bucket | payer (launch host) | payer (instance) |
|---|---|---|
| cookbook-942542972736-us-west-2 | BucketOwner | UNKNOWN |
| kraken2-ncbi-refseq-complete-v205 | BucketOwner | BucketOwner |

**Datasets (head-object at launch)**

| object | size (bytes) | ETag | VersionId | LastModified |
|---|---|---|---|---|
| s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205/hash.k2d | 1189091671800 | `f80959f9556b50d76b3e744afdd3b22a-8860` | null | 2023-08-30T13:49:06+00:00 |
| s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205/opts.k2d | 56 | `24fb1753eb45d74643ef13f16562df6b` | null | 2023-08-30T14:00:49+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/SRR062634_200000.SOURCE | 400 | `6cea87048dd0a0d6dd4c857d83470e55` | null | 2026-10-06T03:55:23+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/SRR062634_200000_1.fq | 51895574 | `cc33d8c08e80154e36cb089e2cc4f611-7` | null | 2026-10-06T03:49:30+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/SRR062634_200000_2.fq | 51895574 | `bdd542dbe602e458d2f3701cc659df03-7` | null | 2026-10-06T03:51:17+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/ERR478965_200000.SOURCE | 400 | `1d93ff1adcb983e2211398184ff3fe57` | null | 2026-10-06T04:01:36+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/ERR478965_200000_1.fq | 47238491 | `a87336ea0a091eb303cbc1c2ba3f38a6-6` | null | 2026-10-06T03:55:28+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/ERR478965_200000_2.fq | 47075003 | `2b5a7c90d0057fdde33af7b3cc3388c0-6` | null | 2026-10-06T03:57:21+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/ERR598966_200000.SOURCE | 400 | `e57bf74f271795b07db3591c5d0b7568` | null | 2026-10-06T08:54:04+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/ERR598966_200000_1.fq | 51418954 | `78b03b7fc1f81d393519f927cf705165-7` | null | 2026-10-06T08:52:23+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/ERR598966_200000_2.fq | 51400840 | `c960ebeaf5cc8218876b207e66ac1bc9-7` | null | 2026-10-06T08:52:58+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/SRR28305653_200000.SOURCE | 422 | `651a82c92ff9de6d410cba64104eff54` | null | 2026-10-06T04:09:54+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/SRR28305653_200000_1.fq | 72980506 | `e773eb80d22a4a009d4e44a9294aaf70-9` | null | 2026-10-06T04:03:02+00:00 |
| s3://cookbook-942542972736-us-west-2/aws-kraken2/data/reads/SRR28305653_200000_2.fq | 72980506 | `9e7f56a3625c7d7d25e36ae118467f00-9` | null | 2026-10-06T04:05:45+00:00 |

**decoded/opts.json**

| field | value |
|---|---|
| k | 35 |
| l | 31 |
| spaced_seed_mask | 4611686018212639539 |
| toggle_mask | 16392584516609989165 |
| dna_db | true |
| dna_db_byte | 1 |
| minimum_acceptable_hash_value | 0 |
| revcom_version | 1 |
| db_version | 32720 |
| db_type | 0 |
| file_size | 56 |
| absent_fields | db_type |
| layout | v2.0.8-v2.0.9 |
| padding_fields | db_version |
| spaced_seed_mask_hex | 0x3ffffffff3333333 |
| toggle_mask_hex | 0xe37e28c4271b5a2d |

**decoded/probes.json**

| field | value |
|---|---|
| ERR478965_all_fraction | 1 |
| ERR478965_all_max_probes | 100 |
| ERR478965_all_mean_probes | 2.7961 |
| ERR478965_gets | 10000 |
| ERR478965_hit_fraction | 0.7164 |
| ERR478965_hit_max_probes | 89 |
| ERR478965_hit_mean_probes | 1.5389447236180904 |
| ERR478965_lookup_population | 7634946 |
| ERR478965_miss_fraction | 0.2836 |
| ERR478965_miss_max_probes | 100 |
| ERR478965_miss_mean_probes | 5.97179125528914 |
| ERR478965_reads | 200000 |
| ERR478965_resolve_seconds | 36.957828079 |
| ERR478965_sampled | 10000 |
| ERR598966_all_fraction | 1 |
| ERR598966_all_max_probes | 97 |
| ERR598966_all_mean_probes | 5.4001 |
| ERR598966_gets | 10000 |
| ERR598966_hit_fraction | 0.1333 |
| ERR598966_hit_max_probes | 63 |
| ERR598966_hit_mean_probes | 1.9887471867966993 |
| ERR598966_lookup_population | 9043546 |
| ERR598966_miss_fraction | 0.8667 |
| ERR598966_miss_max_probes | 97 |
| ERR598966_miss_mean_probes | 5.924772124149071 |
| ERR598966_reads | 200000 |
| ERR598966_resolve_seconds | 36.449121332 |
| ERR598966_sampled | 10000 |
| SRR062634_all_fraction | 1 |
| SRR062634_all_max_probes | 69 |
| SRR062634_all_mean_probes | 1.7368 |
| SRR062634_gets | 10000 |
| SRR062634_hit_fraction | 0.8738 |
| SRR062634_hit_max_probes | 25 |
| SRR062634_hit_mean_probes | 1.149233234149691 |
| SRR062634_lookup_population | 9016552 |
| SRR062634_miss_fraction | 0.1262 |
| SRR062634_miss_max_probes | 69 |
| SRR062634_miss_mean_probes | 5.805071315372425 |
| SRR062634_reads | 200000 |
| SRR062634_resolve_seconds | 37.580937660000004 |
| SRR062634_sampled | 10000 |
| SRR28305653_all_fraction | 1 |
| SRR28305653_all_max_probes | 63 |
| SRR28305653_all_mean_probes | 2.2068 |
| SRR28305653_gets | 10000 |
| SRR28305653_hit_fraction | 0.7889 |
| SRR28305653_hit_max_probes | 32 |
| SRR28305653_hit_mean_probes | 1.1777158068196223 |
| SRR28305653_lookup_population | 15357053 |
| SRR28305653_miss_fraction | 0.2111 |
| SRR28305653_miss_max_probes | 63 |
| SRR28305653_miss_mean_probes | 6.052581714827096 |
| SRR28305653_reads | 200000 |
| SRR28305653_resolve_seconds | 35.771564575 |
| SRR28305653_sampled | 10000 |
| capacity | 297272917942 |
| etag | f80959f9556b50d76b3e744afdd3b22a-8860 |
| get_requests | 40001 |
| get_retries | 0 |
| go_version | go1.27.1 |
| header_size | 207831744422 |
| k | 35 |
| key_bits | 10 |
| knuth_hit_probes_uniform_key_null | 2.161834847658426 |
| knuth_miss_probes | 6.023390121783806 |
| l | 31 |
| load_factor | 0.6991277438281459 |
| minimum_acceptable_hash_value | 0 |
| miss_probes_from_runs | 5.994749487612913 |
| miss_probes_from_runs_source | /home/ec2-user/ak2/repo/results/g0c/20261006-091414-1b5fe49/out/pass/summary.json |
| n_per_sample | 10000 |
| object | https://kraken2-ncbi-refseq-complete-v205.s3.us-west-2.amazonaws.com/Kraken2_RefSeqCompleteV205/hash.k2d |
| seed | 1 |
| wall_seconds | 151.763715333 |
| window_bytes | 65536 |
| workers | 32 |

**decoded/provenance.json**

| field | value |
|---|---|
| decoded_at_commit | b27b55f0dba89f70fac98af6620bd0b42cbcac52 |
| decoded_at | 2026-10-06T10:00:03Z |
| decoder | scripts/post/g0c-probes.sh (k2probe probes output) |

**decoded/rules.json**

| field | value |
|---|---|
| knuth_formulas | hit 1/2(1+1/(1-a)): the uniform-key null (a stored key chosen uniformly); real lookups are content-weighted, so it is not an expectation for them. miss 1/2(1+1/(1-a)^2) (Knuth TAOCP vol. 3, 6.4, Algorithm L); misses are also compared with miss_probes_from_runs, the mean miss length the measured runs imply |
| miss_probes_from_runs_source | /home/ec2-user/ak2/repo/results/g0c/20261006-091414-1b5fe49/out/pass/summary.json |
| hit | value != 0: chash.Probe found a cell whose compacted key matches (with key_bits bits, some are false positives) |
| probes | cells chash.Probe examined, the empty cell that ends a miss included |

**tables/checks.tsv**

| check | observed | expected | ok |
|---|---|---|---|
| ETag: instance head-object | f80959f9556b50d76b3e744afdd3b22a-8860 | f80959f9556b50d76b3e744afdd3b22a-8860 | yes |
| ETag: k2probe -etag, enforced in internal/rangeread as If-Match on every GET plus a check of each response's ETag and Content-Range | f80959f9556b50d76b3e744afdd3b22a-8860 | f80959f9556b50d76b3e744afdd3b22a-8860 | yes |
| miss_probes_from_runs taken from a G0c-a pass (same ETag, checked by k2probe) | true | true | yes |
| get_requests == 1 header GET + the per-sample GETs + retries | 40001 | 40001 | yes |
| opts.k2d bytes == launch size | 56 | 56 | yes |
| k, l from opts.k2d == used | 35,31 | 35,31 | yes |
| minimum_acceptable_hash_value | 0 | 0 | yes |
| SRR062634 lookups sampled | 10000 | 10000 | yes |
| SRR062634 lookup rows | 10000 | 10000 | yes |
| ERR478965 lookups sampled | 10000 | 10000 | yes |
| ERR478965 lookup rows | 10000 | 10000 | yes |
| ERR598966 lookups sampled | 10000 | 10000 | yes |
| ERR598966 lookup rows | 10000 | 10000 | yes |
| SRR28305653 lookups sampled | 10000 | 10000 | yes |
| SRR28305653 lookup rows | 10000 | 10000 | yes |

**tables/phases.tsv**

| phase | start | seconds | cold |
|---|---|---|---|
| preamble | 2026-10-06T09:53:24Z | 3 | no |
| body | 2026-10-06T09:53:27Z | 0 | no |
| setup | 2026-10-06T09:53:27Z | 52 | no |
| head | 2026-10-06T09:54:19Z | 1 | no |
| fetch | 2026-10-06T09:54:20Z | 17 | no |
| probes | 2026-10-06T09:54:37Z | 152 | no |
| push | 2026-10-06T09:57:09Z | 3 | no |

**tables/probe-bands.tsv**

| sample | class | 1 | 2 | 3 | 4 | 5 | 6-10 | 11-20 | 21-50 | 51-100 | 101+ |
|---|---|---|---|---|---|---|---|---|---|---|---|
| SRR062634 | hit | 8153 | 323 | 132 | 54 | 25 | 37 | 11 | 3 | 0 | 0 |
| SRR062634 | miss | 389 | 170 | 135 | 101 | 75 | 180 | 153 | 54 | 5 | 0 |
| ERR478965 | hit | 6018 | 563 | 213 | 108 | 58 | 124 | 57 | 21 | 2 | 0 |
| ERR478965 | miss | 836 | 481 | 280 | 207 | 157 | 423 | 290 | 146 | 16 | 0 |
| ERR598966 | hit | 992 | 142 | 64 | 47 | 16 | 42 | 22 | 7 | 1 | 0 |
| ERR598966 | miss | 2606 | 1306 | 861 | 654 | 473 | 1370 | 927 | 444 | 26 | 0 |
| SRR28305653 | hit | 7298 | 323 | 123 | 55 | 22 | 48 | 16 | 4 | 0 | 0 |
| SRR28305653 | miss | 622 | 342 | 217 | 140 | 117 | 311 | 219 | 137 | 6 | 0 |

**tables/probe-summary.tsv**

| sample | class | lookups | fraction | mean_probes | knuth | mean_minus_knuth | measured_runs | mean_minus_measured_runs | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| SRR062634 | hit | 8738 | 0.8738 | 1.1492332 | 2.1618348 | -1.0126016 | NaN | NaN | 1 | 1 | 4 | 25 |
| SRR062634 | miss | 1262 | 0.1262 | 5.8050713 | 6.0233901 | -0.21831881 | 5.9947495 | -0.18967817 | 3 | 14 | 34 | 69 |
| SRR062634 | all | 10000 | 1 | 1.7368 | NaN | NaN | NaN | NaN | 1 | 2 | 17 | 69 |
| ERR478965 | hit | 7164 | 0.7164 | 1.5389447 | 2.1618348 | -0.62289012 | NaN | NaN | 1 | 2 | 11 | 89 |
| ERR478965 | miss | 2836 | 0.2836 | 5.9717913 | 6.0233901 | -0.051598866 | 5.9947495 | -0.022958232 | 3 | 15 | 42 | 100 |
| ERR478965 | all | 10000 | 1 | 2.7961 | NaN | NaN | NaN | NaN | 1 | 6 | 28 | 100 |
| ERR598966 | hit | 1333 | 0.1333 | 1.9887472 | 2.1618348 | -0.17308766 | NaN | NaN | 1 | 4 | 16 | 63 |
| ERR598966 | miss | 8667 | 0.8667 | 5.9247721 | 6.0233901 | -0.098617998 | 5.9947495 | -0.069977363 | 3 | 15 | 39 | 97 |
| ERR598966 | all | 10000 | 1 | 5.4001 | NaN | NaN | NaN | NaN | 2 | 13 | 38 | 97 |
| SRR28305653 | hit | 7889 | 0.7889 | 1.1777158 | 2.1618348 | -0.98411904 | NaN | NaN | 1 | 1 | 5 | 32 |
| SRR28305653 | miss | 2111 | 0.2111 | 6.0525817 | 6.0233901 | 0.029191593 | 5.9947495 | 0.057832227 | 3 | 15 | 39 | 63 |
| SRR28305653 | all | 10000 | 1 | 2.2068 | NaN | NaN | NaN | NaN | 1 | 4 | 25 | 63 |

**tables/requests.tsv**

| phase | op | count | bucket |
|---|---|---|---|
| preamble | HeadBucket-anon | 1 | cookbook-942542972736-us-west-2 |
| preamble | GetBucketRequestPayment | 1 | cookbook-942542972736-us-west-2 |
| preamble | GetBucketRequestPayment | 1 | cookbook-942542972736-us-west-2 |
| preamble | HeadBucket-anon | 1 | kraken2-ncbi-refseq-complete-v205 |
| preamble | GetBucketRequestPayment | 1 | kraken2-ncbi-refseq-complete-v205 |
| preamble | GetBucketRequestPayment | 1 | kraken2-ncbi-refseq-complete-v205 |
| head | HeadObject | 1 | kraken2-ncbi-refseq-complete-v205 |
| fetch | GetObject | 1 | kraken2-ncbi-refseq-complete-v205 |
| fetch | GetObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 7 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 7 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 6 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 6 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 7 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 7 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 9 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| fetch | GetObject | 9 | cookbook-942542972736-us-west-2 |
| fetch | HeadObject | 1 | cookbook-942542972736-us-west-2 |
| probes | GetObject-range | 40001 | kraken2-ncbi-refseq-complete-v205 |

<details><summary>Files in results/g0c/20261006-095218-b27b55f</summary>

| file | bytes | sha256 |
|---|---|---|
| completion.json | 386 | `712f2357e12ab7f5` |
| decoded/opts.json | 468 | `38488ef9b875f04f` |
| decoded/probes.json | 2918 | `1c273ca87cfbb127` |
| decoded/provenance.json | 177 | `200447276b2d3b3f` |
| decoded/rules.json | 660 | `b8b1fb6c6ef978a5` |
| launch.err | 96 | `777664d583d52ca0` |
| launch.json | 162 | `9ea4d074e320cd2c` |
| log/run.log | 8991 | `766df7ae8d63eb33` |
| manifest.json | 13672 | `781e2de0174ac26a` |
| out/head-hash.k2d.json | 317 | `00588412d0516cf8` |
| out/opts.k2d | 56 | `719d8210ab7fa1ac` |
| out/opts.k2d.get.json | 258 | `3c50fb8bbe97259c` |
| out/probes/lookups-ERR478965.tsv | 768397 | `c5c6be0209d1e39c` |
| out/probes/lookups-ERR598966.tsv | 752130 | `72adc7215aca77d4` |
| out/probes/lookups-SRR062634.tsv | 770336 | `63e6137929f20bef` |
| out/probes/lookups-SRR28305653.tsv | 770260 | `689fd76546a4bc84` |
| out/probes/probe-hist.tsv | 6716 | `1e06152dfddbafe8` |
| out/probes/probe-summary.tsv | 1022 | `3f09a3b7456a811d` |
| out/probes/summary.json | 3248 | `f0bf6d57be6c2c89` |
| out/requests.tsv | 1793 | `b8d174f1eba50758` |
| payload.sh | 19394 | `09269f0d5606c250` |
| preflight.json | 578 | `a7907d0a7ad84c28` |
| report.md | 15805 | `52ccb2a7226d4968` |
| spawn-plan.txt | 2798 | `1bcb6aca61a69775` |
| spawn/ak2-g0c-20261006-095218-b27b55f/command.log | 9497 | `bcb3e5ed0fffecd9` |
| spawn/ak2-g0c-20261006-095218-b27b55f/completion.json | 386 | `712f2357e12ab7f5` |
| spec.json | 7243 | `cc0ad56f29c897a4` |
| spec.resolved.json | 4851 | `36cac7b404eb7980` |
| tables/checks.tsv | 960 | `6e94e8a885bb0141` |
| tables/phases.tsv | 254 | `fcfd3639071408a1` |
| tables/probe-bands.tsv | 444 | `91fbf30dc1621307` |
| tables/probe-summary.tsv | 1022 | `3f09a3b7456a811d` |
| tables/requests.tsv | 1793 | `b8d174f1eba50758` |

</details>

_Rendered by `make report GATE=g0c RUN=20261006-095218-b27b55f` from `results/g0c/20261006-095218-b27b55f/` only._
