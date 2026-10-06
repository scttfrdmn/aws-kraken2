# make g2: g2-smoke

| | |
|---|---|
| commit | `5ccad5b9d8a09b523ba6f6ddfcb86a88826cce24` (dirty: False) |
| upstream pin | `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) |
| madvrandom (diagnostic) | yes: /home/ec2-user/ak2/repo/.oracle/2731b35f7abb26ec926517274f3d87e78d42fd76-madvrandom |
| host | r8gd.xlarge, 4 CPUs, 32248252 KiB, kernel 6.18.51-120.163.amzn2023.aarch64, THP [always [madvise] never] defrag [always defer defer+madvise [madvise] never] |
| storage | instance-store NVMe 1x (220.7G Amazon EC2 NVMe Instance Storage)  xfs noatime at /mnt/nvme; read_ahead_kb: nvme0n1=128KiB; scheduler: nvme0n1=[none]mq-deadlinekyberbfq |
| make run id | 20261006-202811-5ccad5b |
| cold | True (ak2_drop_caches) |
| rungs / skipped / failures | 8 / 0 / 0 |
| note | smoke test of the g2 driver on AWS: Standard-8, SRR062634; checks instruments, not a result |

## Inputs

| input | pairs | mate-1 bytes | 8 MiB blocks | max busy threads |
|---|---|---|---|---|
| SRR062634_200000-gz | 200000 | 51895574 | 7 | 7 |
| SRR062634_50000-fq | 50000 | 12916748 | 2 | 2 |
| SRR062634_50000-gz | 50000 | 12916748 | 2 | 2 |

## Cells (classify_s = upstream's own `processed in`; median [min-max])

| regime | input | state | T | n | classify_s | pairs/s | load_s | wall_s | blocks/T | quant | output sha256 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| load | SRR062634_200000-gz | warm | 4 | 1 | 0.699 [0.699-0.699] | 286123 | 0.362 [0.362-0.362] | 1.296 | 1.75 | 1.14 | 527068d2bc8e |
| load | empty | cold | 4 | 1 | 0.001 [0.001-0.001] | - | 15.269 [15.269-15.269] | 15.420 | - | - | - |
| madv | SRR062634_50000-gz | cold | 2 | 1 | 9.051 [9.051-9.051] | 5524 | 0.144 [0.144-0.144] | 9.387 | 1.00 | 1.00 | c2990f1cf011 |
| madv | SRR062634_50000-gz | cold | 4 | 1 | 9.052 [9.052-9.052] | 5524 | 0.178 [0.178-0.178] | 9.369 | 0.50 | 2.00 | c2990f1cf011 |
| mmap | SRR062634_50000-fq | warm | 4 | 1 | 0.286 [0.286-0.286] | 174825 | 0.017 [0.017-0.017] | 0.593 | 0.50 | 2.00 | c2990f1cf011 |
| mmap | SRR062634_50000-gz | cold | 2 | 1 | 13.710 [13.710-13.710] | 3647 | 0.175 [0.175-0.175] | 14.167 | 1.00 | 1.00 | c2990f1cf011 |
| mmap | SRR062634_50000-gz | cold | 4 | 1 | 13.524 [13.524-13.524] | 3697 | 0.148 [0.148-0.148] | 13.952 | 0.50 | 2.00 | c2990f1cf011 |
| mmap | SRR062634_50000-gz | warm | 4 | 1 | 0.359 [0.359-0.359] | 139276 | 0.018 [0.018-0.018] | 0.654 | 0.50 | 2.00 | c2990f1cf011 |

## Output identity

`--output` must not depend on thread count or regime (all oracle-identical builds; madvrandom changes only page-fault read-around).

| input | distinct --output sha256 over all rungs |
|---|---|
| SRR062634_200000-gz | 1 (identical) |
| SRR062634_50000-fq | 1 (identical) |
| SRR062634_50000-gz | 1 (identical) |

## Ladders (speedup and step efficiency)

Step efficiency = (throughput gain - 1) / (thread ratio - 1) between consecutive rungs: 1 = linear, 0 = flat, < 0 = slower. A step is *resolved* when the two rungs' classify_s ranges are separated; rungs with fewer than 2 blocks per thread cannot resolve scaling (8 MiB input blocks).

**madv / SRR062634_50000-gz / cold**

| T | classify_s | pairs/s | speedup vs T=2 | step eff. | resolved | blocks/T >= 2 |
|---|---|---|---|---|---|---|
| 2 | 9.051 [9.051-9.051] | 5524 | 1.00 | - | - | False |
| 4 | 9.052 [9.052-9.052] | 5524 | 1.00 | -1.10e-04 | yes | False |

Knee: first step below 50% efficiency is T=2 -> 4 (efficiency -0.00; resolved; blocks/T >= 2 at 4: False).

**mmap / SRR062634_50000-gz / cold**

| T | classify_s | pairs/s | speedup vs T=2 | step eff. | resolved | blocks/T >= 2 |
|---|---|---|---|---|---|---|
| 2 | 13.710 [13.710-13.710] | 3647 | 1.00 | - | - | False |
| 4 | 13.524 [13.524-13.524] | 3697 | 1.01 | 0.01 | yes | False |

Knee: first step below 50% efficiency is T=2 -> 4 (efficiency 0.01; resolved; blocks/T >= 2 at 4: False).

## gzip vs plain input (single-stream gzip candidate)

| regime | state | T | input | gz classify_s | fq classify_s | gz/fq | separated |
|---|---|---|---|---|---|---|---|
| mmap | warm | 4 | SRR062634_50000 | 0.359 [0.359-0.359] | 0.286 [0.286-0.286] | 1.255 | yes |

## Candidate signatures per cell (medians over reps; classify window only)

| regime | input | state | T | aqu-sz (NVMe) | aqu/T | r/s | KiB/IO | MiB/s | majflt | bytes/majflt (x 4 KiB) | off-CPU | R | D | S futex | S read | gzip R | IPC | dTLB miss | dTLB walk/kinst | futex/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| load | SRR062634_200000-gz | warm | 4 | 9.20e-02 | 0.02 | 342 | 126.9 | 42 | 3 | 10356053 (2528.3) | 0.45 | 0.46 | 0.02 | 0.40 | 0.12 | 0.43 | 2.94 | 0.0007 | 0.05 | 34 |
| load | empty | cold | 4 | 0 | 0.00 | 2473 | 2.8 | 7 | 0 | - (-) | 0.79 | 0.25 | 0.00 | 0.75 | 0.00 | - | 4.07 | - | - | 3298 |
| madv | SRR062634_50000-gz | cold | 2 | 1.1 | 0.54 | 15716 | 4.1 | 62 | 142289 | 4147 (1.0) | 0.77 | 0.20 | 0.56 | 0.23 | 2.80e-03 | 8.30e-03 | 2.34 | 0.0147 | 0.28 | 6.63e-01 |
| madv | SRR062634_50000-gz | cold | 4 | 1.1 | 0.27 | 15714 | 4.1 | 62 | 142277 | 4148 (1.0) | 0.89 | 0.10 | 0.28 | 0.62 | 1.40e-03 | 8.30e-03 | 2.38 | 0.0148 | 0.30 | 2 |
| mmap | SRR062634_50000-fq | warm | 4 | 0.2 | 0.05 | 692 | 127.4 | 86 | 0 | - (-) | 0.62 | 0.43 | 0.00 | 0.57 | 0.00 | - | 2.85 | 0.0043 | 0.13 | 56 |
| mmap | SRR062634_50000-gz | cold | 2 | 1.7 | 0.86 | 4712 | 103.1 | 474 | 61526 | 110799 (27.1) | 0.90 | 0.09 | 0.84 | 0.07 | 1.80e-03 | 5.50e-03 | 2.76 | 0.0054 | 0.09 | 3.65e-01 |
| mmap | SRR062634_50000-gz | cold | 4 | 1.7 | 0.43 | 4777 | 103.1 | 481 | 61579 | 110704 (27.0) | 0.95 | 0.06 | 0.40 | 0.54 | 1.90e-03 | 3.70e-03 | 2.78 | 0.0052 | 0.09 | 1 |
| mmap | SRR062634_50000-gz | warm | 4 | 0 | 0.00 | 0 | - | 0 | 0 | - (-) | 0.60 | 0.31 | 0.00 | 0.62 | 0.06 | 0.19 | 2.61 | 0.0039 | 0.12 | 31 |

## Candidates per regime (mechanical reading; see docs/g2.md for the rules)

One block of rows per ladder (regime / input / state). Critical sections are read only on rungs with >= 2 input blocks per thread: with fewer, idle threads wait at the OpenMP barrier in futex and would look like lock contention.

| ladder | candidate | evidence | could the probe resolve it? |
|---|---|---|---|
| load / SRR062634_200000-gz / warm | sync faults cap NVMe QD | no disk reads in the window | no: no I/O to measure |
| load / SRR062634_200000-gz / warm | read-around amplification | < 1000 major faults | no |
| load / SRR062634_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=4 | no |
| load / SRR062634_200000-gz / warm | DRAM/TLB limits | T=4 IPC 2.94 dTLB-miss 0.0007 walk/kinst 0.05 | yes (perf counters present) |
| load / SRR062634_200000-gz / warm | single-stream gzip | no gz/fq pair | no |
| load / empty / cold | sync faults cap NVMe QD | no disk reads in the window | no: no I/O to measure |
| load / empty / cold | read-around amplification | < 1000 major faults | no |
| load / empty / cold | critical sections | too few sampler samples | no |
| load / empty / cold | DRAM/TLB limits | T=4 IPC 4.07 dTLB-miss - walk/kinst - | yes (perf counters present) |
| madv / SRR062634_50000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=2 aqu=1.1 (0.54 per busy-able thread, 2); T=4 aqu=1.1 (0.55 per busy-able thread, 2) | yes (>= 1000 read IOs per rung) |
| madv / SRR062634_50000-gz / cold | read-around amplification | not seen: T=2 1.0 x 4 KiB per major fault; T=4 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| madv / SRR062634_50000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=2,4 | no |
| madv / SRR062634_50000-gz / cold | DRAM/TLB limits | T=2 IPC 2.34 dTLB-miss 0.0147 walk/kinst 0.28; T=4 IPC 2.38 dTLB-miss 0.0148 walk/kinst 0.30 | yes (perf counters present) |
| madv / SRR062634_50000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap / SRR062634_50000-fq / warm | sync faults cap NVMe QD | no disk reads in the window | no: no I/O to measure |
| mmap / SRR062634_50000-fq / warm | read-around amplification | < 1000 major faults | no |
| mmap / SRR062634_50000-fq / warm | critical sections | confounded: fewer than 2 blocks per thread at T=4 | no |
| mmap / SRR062634_50000-fq / warm | DRAM/TLB limits | T=4 IPC 2.85 dTLB-miss 0.0043 walk/kinst 0.13 | yes (perf counters present) |
| mmap / SRR062634_50000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | seen: T=2 aqu=1.7 (0.86 per busy-able thread, 2); T=4 aqu=1.7 (0.86 per busy-able thread, 2) | yes (>= 1000 read IOs per rung) |
| mmap / SRR062634_50000-gz / cold | read-around amplification | seen: T=2 27.1 x 4 KiB per major fault; T=4 27.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap / SRR062634_50000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=2,4 | no |
| mmap / SRR062634_50000-gz / cold | DRAM/TLB limits | T=2 IPC 2.76 dTLB-miss 0.0054 walk/kinst 0.09; T=4 IPC 2.78 dTLB-miss 0.0052 walk/kinst 0.09 | yes (perf counters present) |
| mmap / SRR062634_50000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap / SRR062634_50000-gz / warm | sync faults cap NVMe QD | no disk reads in the window | no: no I/O to measure |
| mmap / SRR062634_50000-gz / warm | read-around amplification | < 1000 major faults | no |
| mmap / SRR062634_50000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=4 | no |
| mmap / SRR062634_50000-gz / warm | DRAM/TLB limits | T=4 IPC 2.61 dTLB-miss 0.0039 walk/kinst 0.12 | yes (perf counters present) |
| mmap / SRR062634_50000-gz / warm | single-stream gzip | warm T=4 gz/fq 1.255 | yes (gz and fq at the same T) |

