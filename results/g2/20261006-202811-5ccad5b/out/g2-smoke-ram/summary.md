# make g2: g2-smoke-ram-20261006T203216Z

| | |
|---|---|
| commit | `5ccad5b9d8a09b523ba6f6ddfcb86a88826cce24` (dirty: False) |
| upstream pin | `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) |
| madvrandom (diagnostic) | yes: /home/ec2-user/ak2/repo/.oracle/2731b35f7abb26ec926517274f3d87e78d42fd76-madvrandom |
| host | r8gd.xlarge, 4 CPUs, 32248252 KiB, kernel 6.18.51-120.163.amzn2023.aarch64, THP [always [madvise] never] defrag [always defer defer+madvise [madvise] never] |
| storage | instance-store NVMe 1x (220.7G Amazon EC2 NVMe Instance Storage)  xfs noatime at /mnt/nvme; read_ahead_kb: nvme0n1=128KiB; scheduler: nvme0n1=[none]mq-deadlinekyberbfq |
| make run id | 20261006-202811-5ccad5b |
| cold | True (ak2_drop_caches) |
| rungs / skipped / failures | 3 / 0 / 0 |
| note | smoke test, ram regime on a huge=always tmpfs copy of Standard-8 |

## Inputs

| input | pairs | mate-1 bytes | 8 MiB blocks | max busy threads |
|---|---|---|---|---|
| SRR062634_200000-fq | 200000 | 51895574 | 7 | 7 |
| SRR062634_200000-gz | 200000 | 51895574 | 7 | 7 |

## Cells (classify_s = upstream's own `processed in`; median [min-max])

| regime | input | state | T | n | classify_s | pairs/s | load_s | wall_s | blocks/T | quant | output sha256 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ram | SRR062634_200000-fq | warm | 4 | 1 | 0.314 [0.314-0.314] | 636943 | 0.018 [0.018-0.018] | 0.460 | 1.75 | 1.14 | 527068d2bc8e |
| ram | SRR062634_200000-gz | warm | 2 | 1 | 0.785 [0.785-0.785] | 254777 | 0.019 [0.019-0.019] | 0.970 | 3.50 | 1.14 | 527068d2bc8e |
| ram | SRR062634_200000-gz | warm | 4 | 1 | 0.702 [0.702-0.702] | 284900 | 0.065 [0.065-0.065] | 0.921 | 1.75 | 1.14 | 527068d2bc8e |

## Output identity

`--output` must not depend on thread count or regime (all oracle-identical builds; madvrandom changes only page-fault read-around).

| input | distinct --output sha256 over all rungs |
|---|---|
| SRR062634_200000-fq | 1 (identical) |
| SRR062634_200000-gz | 1 (identical) |

## Ladders (speedup and step efficiency)

Step efficiency = (throughput gain - 1) / (thread ratio - 1) between consecutive rungs: 1 = linear, 0 = flat, < 0 = slower. A step is *resolved* when the two rungs' classify_s ranges are separated; rungs with fewer than 2 blocks per thread cannot resolve scaling (8 MiB input blocks).

**ram / SRR062634_200000-gz / warm**

| T | classify_s | pairs/s | speedup vs T=2 | step eff. | resolved | blocks/T >= 2 |
|---|---|---|---|---|---|---|
| 2 | 0.785 [0.785-0.785] | 254777 | 1.00 | - | - | True |
| 4 | 0.702 [0.702-0.702] | 284900 | 1.12 | 0.12 | yes | False |

Knee: first step below 50% efficiency is T=2 -> 4 (efficiency 0.12; resolved; blocks/T >= 2 at 4: False).

## gzip vs plain input (single-stream gzip candidate)

| regime | state | T | input | gz classify_s | fq classify_s | gz/fq | separated |
|---|---|---|---|---|---|---|---|
| ram | warm | 4 | SRR062634_200000 | 0.702 [0.702-0.702] | 0.314 [0.314-0.314] | 2.236 | yes |

## Candidate signatures per cell (medians over reps; classify window only)

| regime | input | state | T | aqu-sz (NVMe) | aqu/T | r/s | KiB/IO | MiB/s | majflt | bytes/majflt (x 4 KiB) | off-CPU | R | D | S futex | S read | gzip R | IPC | dTLB miss | dTLB walk/kinst | futex/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ram | SRR062634_200000-fq | warm | 4 | 0 | 0.00 | 0 | - | 0 | 1 | 0 (-) | 0.24 | 0.75 | 0.04 | 0.21 | 0.00 | - | 3.61 | 0.0004 | 0.06 | 54 |
| ram | SRR062634_200000-gz | warm | 2 | 0 | 0.00 | 0 | - | 0 | 0 | - (-) | 0.02 | 0.59 | 0.00 | 0.12 | 0.22 | 0.38 | 3.07 | 0.0005 | 0.05 | 14 |
| ram | SRR062634_200000-gz | warm | 4 | 0 | 0.00 | 0 | - | 0 | 0 | - (-) | 0.44 | 0.30 | 0.00 | 0.48 | 0.16 | 0.43 | 3.00 | 0.0008 | 0.05 | 30 |

## Candidates per regime (mechanical reading; see docs/g2.md for the rules)

| regime | candidate | evidence | could the probe resolve it? |
|---|---|---|---|
| ram | sync faults cap NVMe QD | no disk reads in the window | no: no I/O to measure |
| ram | read-around amplification | < 1000 major faults | no |
| ram | critical sections | too few sampler samples | no |
| ram | DRAM/TLB limits | T=2 IPC 3.07 dTLB-miss 0.0005 walk/kinst 0.05; T=4 IPC 3.61 dTLB-miss 0.0004 walk/kinst 0.06; T=4 IPC 3.00 dTLB-miss 0.0008 walk/kinst 0.05 | yes (perf counters present) |
| ram | single-stream gzip | warm T=4 gz/fq 2.236 | yes (gz and fq at the same T) |

