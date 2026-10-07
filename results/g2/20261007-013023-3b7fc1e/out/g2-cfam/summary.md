# make g2: g2-cfam

| | |
|---|---|
| commit | `3b7fc1e2c6451bc837a4fb78c6f7628fb1a87c78` (dirty: False) |
| upstream pin | `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) |
| madvrandom (diagnostic) | yes: /home/ec2-user/ak2/repo/.oracle/2731b35f7abb26ec926517274f3d87e78d42fd76-madvrandom |
| host | c8gd.8xlarge, 32 CPUs, 64644672 KiB, kernel 6.18.51-120.163.amzn2023.aarch64, THP [always [madvise] never] defrag [always defer defer+madvise [madvise] never] |
| storage | instance-store NVMe 1x ( 1.7T Amazon EC2 NVMe Instance Storage)  xfs noatime at /mnt/nvme; read_ahead_kb: nvme0n1=128KiB; scheduler: nvme0n1=[none]mq-deadlinekyberbfq |
| make run id | 20261007-013023-3b7fc1e |
| cold | True (ak2_drop_caches) |
| rungs / skipped / failures | 15 / 0 / 0 |
| note | #21 c-family: pristine -M at read_ahead_kb default (128) and 4; madv as the reference |

## Inputs

| input | pairs | mate-1 bytes | 8 MiB blocks | max busy threads |
|---|---|---|---|---|
| ERR478965_200000-gz | 200000 | 47238491 | 6 | 6 |
| ERR598966_200000-gz | 200000 | 51418954 | 7 | 7 |
| SRR062634_200000-gz | 200000 | 51895574 | 7 | 7 |
| SRR062634_2000000-gz | 2000000 | 521103409 | 63 | 63 |
| SRR062634_250000-gz | 250000 | 64902524 | 8 | 8 |
| SRR28305653_200000-gz | 200000 | 72980506 | 9 | 9 |

## Cells (classify_s = upstream's own `processed in`; median [min-max])

`warm!` marks a warm cell with a rung that did not follow a rung on its own input (the cache held another input's pages): not a warm measurement.

| regime | input | state | T | n | classify_s | pairs/s | load_s | wall_s | blocks/T | quant | output sha256 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| madv | SRR062634_250000-gz | cold | 8 | 1 | 123.058 [123.058-123.058] | 2032 | 0.231 [0.231-0.231] | 125.894 | 1.00 | 1.00 | 4bcdea23a77f |
| mmap | SRR062634_2000000-gz | cold | 32 | 0 (+1 censored) | - [---] | - | - [---] | - | 1.97 | 1.02 |  |
| mmap | SRR062634_250000-gz | cold | 8 | 1 | 391.953 [391.953-391.953] | 638 | 0.216 [0.216-0.216] | 394.025 | 1.00 | 1.00 | 4bcdea23a77f |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | cold | 32 | 1 | 113.787 [113.787-113.787] | 1758 | 0.285 [0.285-0.285] | 116.357 | 0.19 | 5.33 | c171d2b7f5a0 |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | warm! | 32 | 1 | 110.163 [110.163-110.163] | 1815 | 0.036 [0.036-0.036] | 112.773 | 0.19 | 5.33 | c171d2b7f5a0 |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | cold | 32 | 1 | 128.798 [128.798-128.798] | 1553 | 0.249 [0.249-0.249] | 131.701 | 0.22 | 4.57 | 2424cc36086d |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | warm! | 32 | 1 | 124.046 [124.046-124.046] | 1612 | 0.019 [0.019-0.019] | 127.086 | 0.22 | 4.57 | 2424cc36086d |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | cold | 32 | 1 | 123.562 [123.562-123.562] | 1619 | 0.259 [0.259-0.259] | 126.300 | 0.22 | 4.57 | 8853f17272d0 |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | warm! | 32 | 1 | 117.401 [117.401-117.401] | 1704 | 0.020 [0.020-0.020] | 120.180 | 0.22 | 4.57 | 8853f17272d0 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 32 | 1 | 268.947 [268.947-268.947] | 7436 | 0.236 [0.236-0.236] | 273.136 | 1.97 | 1.02 | 1d6d1b9291a7 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 64 | 1 | 176.971 [176.971-176.971] | 11301 | 0.278 [0.278-0.278] | 181.219 | 0.98 | 1.02 | 1d6d1b9291a7 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | warm | 32 | 1 | 264.500 [264.500-264.500] | 7561 | 0.109 [0.109-0.109] | 268.497 | 1.97 | 1.02 | 1d6d1b9291a7 |
| mmap[read_ahead_kb=4] | SRR062634_250000-gz | cold | 8 | 1 | 123.168 [123.168-123.168] | 2030 | 0.296 [0.296-0.296] | 126.197 | 1.00 | 1.00 | 4bcdea23a77f |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | cold | 32 | 1 | 94.154 [94.154-94.154] | 2124 | 0.242 [0.242-0.242] | 96.894 | 0.28 | 3.56 | 82e3e37ab5ef |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | warm! | 32 | 1 | 87.621 [87.621-87.621] | 2283 | 0.033 [0.033-0.033] | 90.490 | 0.28 | 3.56 | 82e3e37ab5ef |

## Output identity

`--output` must not depend on thread count or regime (all oracle-identical builds; madvrandom changes only page-fault read-around).

| input | distinct --output sha256 over all rungs |
|---|---|
| ERR478965_200000-gz | 1 (identical) |
| ERR598966_200000-gz | 1 (identical) |
| SRR062634_200000-gz | 1 (identical) |
| SRR062634_2000000-gz | 1 (identical) |
| SRR062634_250000-gz | 1 (identical) |
| SRR28305653_200000-gz | 1 (identical) |

## Ladders (speedup and step efficiency)

Step efficiency = (throughput gain - 1) / (thread ratio - 1) between consecutive rungs: 1 = linear, 0 = flat, < 0 = slower. A step is *resolved* when the two rungs' classify_s ranges are separated; rungs with fewer than 2 blocks per thread cannot resolve scaling (8 MiB input blocks).

**mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold**

| T | classify_s | pairs/s | speedup vs T=32 | step eff. | resolved | blocks/T >= 2 |
|---|---|---|---|---|---|---|
| 32 | 268.947 [268.947-268.947] | 7436 | 1.00 | - | - | False |
| 64 | 176.971 [176.971-176.971] | 11301 | 1.52 | 0.52 | yes | False |

No step below 50% efficiency on this ladder.

## gzip vs plain input (single-stream gzip candidate)

| regime | state | T | input | gz classify_s | fq classify_s | gz/fq | separated |
|---|---|---|---|---|---|---|---|
| (no cell ran both -gz and -fq: the gzip candidate is unresolved here) | | | | | | | |

## Candidate signatures per cell (medians over reps; classify window only)

| regime | input | state | T | aqu-sz (NVMe) | aqu/T | r/s | KiB/IO | MiB/s | majflt | bytes/majflt (x 4 KiB) | off-CPU | R | D | S futex | S read | gzip R | IPC | dTLB miss | dTLB walk/kinst | futex/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| madv | SRR062634_250000-gz | cold | 8 | 5.5 | 0.69 | 78473 | 4.0 | 307 | 9656429 | 4100 (1.0) | 0.74 | 0.26 | 0.69 | 0.05 | 7.00e-04 | 2.60e-03 | 1.79 | 0.0344 | 0.73 | 1.95e-01 |
| mmap | SRR062634_2000000-gz | cold | 32 | 31.4 | 0.98 | 31533 | 120.0 | 3697 | 53995558 | 129326 (31.6) | - | 0.05 | 0.94 | 0.01 | 1.00e-04 | 1.40e-03 | - | - | - | - |
| mmap | SRR062634_250000-gz | cold | 8 | 6.7 | 0.84 | 25778 | 120.3 | 3029 | 9624672 | 129350 (31.6) | 0.85 | 0.14 | 0.81 | 0.05 | 2.00e-04 | 8.00e-04 | 2.18 | 0.0087 | 0.18 | 7.65e-02 |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | cold | 32 | 4.1 | 0.13 | 58043 | 4.0 | 227 | 6604460 | 4100 (1.0) | 0.95 | 0.05 | 0.13 | 0.83 | 1.00e-04 | 2.00e-03 | 1.81 | 0.0339 | 0.72 | 1 |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | warm | 32 | 4.0 | 0.13 | 57704 | 4.0 | 226 | 6356768 | 4100 (1.0) | 0.95 | 0.05 | 0.13 | 0.83 | 1.00e-04 | 2.10e-03 | 1.70 | 0.0343 | 0.72 | 1 |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | cold | 32 | 4.4 | 0.14 | 62717 | 4.0 | 245 | 8077766 | 4099 (1.0) | 0.95 | 0.05 | 0.14 | 0.81 | 1.00e-04 | 2.00e-03 | 1.71 | 0.0355 | 0.80 | 1 |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | warm | 32 | 4.4 | 0.14 | 62679 | 4.0 | 245 | 7774997 | 4100 (1.0) | 0.95 | 0.05 | 0.14 | 0.81 | 1.00e-04 | 1.80e-03 | 1.62 | 0.0345 | 0.81 | 1 |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | cold | 32 | 4.4 | 0.14 | 63025 | 4.0 | 246 | 7787719 | 4100 (1.0) | 0.95 | 0.05 | 0.14 | 0.81 | 1.00e-04 | 2.10e-03 | 1.81 | 0.0331 | 0.71 | 1 |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | warm | 32 | 4.4 | 0.14 | 62310 | 4.0 | 244 | 7315245 | 4100 (1.0) | 0.95 | 0.05 | 0.14 | 0.81 | 1.00e-04 | 2.40e-03 | 1.72 | 0.0333 | 0.77 | 1 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 32 | 21.7 | 0.68 | 267431 | 4.0 | 1046 | 71928927 | 4100 (1.0) | 0.72 | 0.27 | 0.68 | 0.05 | 5.00e-04 | 9.70e-03 | 1.31 | 0.0329 | 0.80 | 7.58e-01 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 64 | 42.4 | 0.66 | 406805 | 4.0 | 1591 | 71997381 | 4100 (1.0) | 0.77 | 0.27 | 0.66 | 0.07 | 4.00e-04 | 0.02 | 1.16 | 0.0342 | 1.10 | 3 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | warm | 32 | 21.8 | 0.68 | 269191 | 4.0 | 1053 | 71206050 | 4100 (1.0) | 0.73 | 0.27 | 0.68 | 0.05 | 5.00e-04 | 9.70e-03 | 1.32 | 0.0340 | 0.83 | 7.37e-01 |
| mmap[read_ahead_kb=4] | SRR062634_250000-gz | cold | 8 | 5.5 | 0.69 | 78403 | 4.0 | 307 | 9656578 | 4100 (1.0) | 0.74 | 0.27 | 0.68 | 0.05 | 5.00e-04 | 2.60e-03 | 1.79 | 0.0332 | 0.70 | 2.03e-01 |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | cold | 32 | 6.3 | 0.20 | 88620 | 4.0 | 346 | 8343865 | 4098 (1.0) | 0.92 | 0.07 | 0.20 | 0.73 | 2.00e-04 | 2.70e-03 | 1.83 | 0.0329 | 0.66 | 2 |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | warm | 32 | 6.2 | 0.19 | 87472 | 4.0 | 342 | 7664398 | 4098 (1.0) | 0.92 | 0.07 | 0.20 | 0.73 | 1.00e-04 | 3.20e-03 | 1.73 | 0.0329 | 0.70 | 2 |

## Candidates per regime (mechanical reading; see docs/g2.md for the rules)

One block of rows per ladder (regime / input / state). Critical sections are read only on rungs with >= 2 input blocks per thread: with fewer, idle threads wait at the OpenMP barrier in futex and would look like lock contention.

| ladder | candidate | evidence | could the probe resolve it? |
|---|---|---|---|
| madv / SRR062634_250000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=8 aqu=5.5 (0.69 per busy-able thread, 8) | yes (>= 1000 read IOs per rung) |
| madv / SRR062634_250000-gz / cold | read-around amplification | not seen: T=8 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| madv / SRR062634_250000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=8 | no |
| madv / SRR062634_250000-gz / cold | DRAM/TLB limits | T=8 IPC 1.79 dTLB-miss 0.0344 walk/kinst 0.73 | yes (perf counters present) |
| madv / SRR062634_250000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap / SRR062634_2000000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | seen: T=32 aqu=31.4 (0.98 per busy-able thread, 32) | yes (>= 1000 read IOs per rung) |
| mmap / SRR062634_2000000-gz / cold | read-around amplification | seen: T=32 31.6 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap / SRR062634_2000000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap / SRR062634_2000000-gz / cold | DRAM/TLB limits | no perf counters | no |
| mmap / SRR062634_2000000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap / SRR062634_250000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | seen: T=8 aqu=6.7 (0.84 per busy-able thread, 8) | yes (>= 1000 read IOs per rung) |
| mmap / SRR062634_250000-gz / cold | read-around amplification | seen: T=8 31.6 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap / SRR062634_250000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=8 | no |
| mmap / SRR062634_250000-gz / cold | DRAM/TLB limits | T=8 IPC 2.18 dTLB-miss 0.0087 walk/kinst 0.18 | yes (perf counters present) |
| mmap / SRR062634_250000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.1 (0.68 per busy-able thread, 6) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.81 dTLB-miss 0.0339 walk/kinst 0.72 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.0 (0.67 per busy-able thread, 6) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.70 dTLB-miss 0.0343 walk/kinst 0.72 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.4 (0.63 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.71 dTLB-miss 0.0355 walk/kinst 0.80 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.4 (0.63 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.62 dTLB-miss 0.0345 walk/kinst 0.81 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.4 (0.63 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.81 dTLB-miss 0.0331 walk/kinst 0.71 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.4 (0.62 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.72 dTLB-miss 0.0333 walk/kinst 0.77 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=21.7 (0.68 per busy-able thread, 32); T=64 aqu=42.4 (0.67 per busy-able thread, 63) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault; T=64 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32,64 | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | DRAM/TLB limits | T=32 IPC 1.31 dTLB-miss 0.0329 walk/kinst 0.80; T=64 IPC 1.16 dTLB-miss 0.0342 walk/kinst 1.10 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=21.8 (0.68 per busy-able thread, 32) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | DRAM/TLB limits | T=32 IPC 1.32 dTLB-miss 0.0340 walk/kinst 0.83 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=8 aqu=5.5 (0.69 per busy-able thread, 8) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | read-around amplification | not seen: T=8 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=8 | no |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | DRAM/TLB limits | T=8 IPC 1.79 dTLB-miss 0.0332 walk/kinst 0.70 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=6.3 (0.70 per busy-able thread, 9) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.83 dTLB-miss 0.0329 walk/kinst 0.66 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=6.2 (0.69 per busy-able thread, 9) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.73 dTLB-miss 0.0329 walk/kinst 0.70 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | single-stream gzip | no gz/fq pair | no |

