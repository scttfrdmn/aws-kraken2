# make g2: g2-cfam-20261007T015419Z

| | |
|---|---|
| commit | `3b7fc1e2c6451bc837a4fb78c6f7628fb1a87c78` (dirty: False) |
| upstream pin | `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`) |
| madvrandom (diagnostic) | yes: /home/ec2-user/ak2/repo/.oracle/2731b35f7abb26ec926517274f3d87e78d42fd76-madvrandom |
| host | c9gd.8xlarge, 32 CPUs, 64611968 KiB, kernel 6.18.51-120.163.amzn2023.aarch64, THP [always [madvise] never] defrag [always defer defer+madvise [madvise] never] |
| storage | instance-store NVMe 1x ( 1.7T Amazon EC2 NVMe Instance Storage)  xfs noatime at /mnt/nvme; read_ahead_kb: nvme0n1=128KiB; scheduler: nvme0n1=[none]mq-deadlinekyberbfq |
| make run id | 20261007-013043-3b7fc1e |
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

| regime | input | state | T | n | classify_s | pairs/s | load_s | wall_s | blocks/T | quant | output sha256 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| madv | SRR062634_250000-gz | cold | 8 | 1 | 140.700 [140.700-140.700] | 1777 | 0.197 [0.197-0.197] | 143.039 | 1.00 | 1.00 | 4bcdea23a77f |
| mmap | SRR062634_2000000-gz | cold | 32 | 0 (+1 censored) | - [---] | - | - [---] | - | 1.97 | 1.02 |  |
| mmap | SRR062634_250000-gz | cold | 8 | 1 | 259.970 [259.970-259.970] | 962 | 0.270 [0.270-0.270] | 261.923 | 1.00 | 1.00 | 4bcdea23a77f |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | cold | 32 | 1 | 129.516 [129.516-129.516] | 1544 | 0.248 [0.248-0.248] | 131.643 | 0.19 | 5.33 | c171d2b7f5a0 |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | warm | 32 | 1 | 123.501 [123.501-123.501] | 1619 | 0.029 [0.029-0.029] | 125.703 | 0.19 | 5.33 | c171d2b7f5a0 |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | cold | 32 | 1 | 146.634 [146.634-146.634] | 1364 | 0.240 [0.240-0.240] | 149.104 | 0.22 | 4.57 | 2424cc36086d |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | warm | 32 | 1 | 140.851 [140.851-140.851] | 1420 | 0.016 [0.016-0.016] | 143.280 | 0.22 | 4.57 | 2424cc36086d |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | cold | 32 | 1 | 140.492 [140.492-140.492] | 1424 | 0.212 [0.212-0.212] | 142.747 | 0.22 | 4.57 | 8853f17272d0 |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | warm | 32 | 1 | 131.891 [131.891-131.891] | 1516 | 0.016 [0.016-0.016] | 134.271 | 0.22 | 4.57 | 8853f17272d0 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 32 | 1 | 295.854 [295.854-295.854] | 6760 | 0.244 [0.244-0.244] | 299.448 | 1.97 | 1.02 | 1d6d1b9291a7 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 64 | 1 | 201.840 [201.840-201.840] | 9909 | 0.249 [0.249-0.249] | 205.383 | 0.98 | 1.02 | 1d6d1b9291a7 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | warm | 32 | 1 | 292.148 [292.148-292.148] | 6846 | 0.089 [0.089-0.089] | 295.635 | 1.97 | 1.02 | 1d6d1b9291a7 |
| mmap[read_ahead_kb=4] | SRR062634_250000-gz | cold | 8 | 1 | 141.430 [141.430-141.430] | 1768 | 0.209 [0.209-0.209] | 143.944 | 1.00 | 1.00 | 4bcdea23a77f |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | cold | 32 | 1 | 106.453 [106.453-106.453] | 1879 | 0.254 [0.254-0.254] | 108.900 | 0.28 | 3.56 | 82e3e37ab5ef |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | warm | 32 | 1 | 97.343 [97.343-97.343] | 2055 | 0.028 [0.028-0.028] | 99.758 | 0.28 | 3.56 | 82e3e37ab5ef |

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
| 32 | 295.854 [295.854-295.854] | 6760 | 1.00 | - | - | False |
| 64 | 201.840 [201.840-201.840] | 9909 | 1.47 | 0.47 | yes | False |

Knee: first step below 50% efficiency is T=32 -> 64 (efficiency 0.47; resolved; blocks/T >= 2 at 64: False).

## gzip vs plain input (single-stream gzip candidate)

| regime | state | T | input | gz classify_s | fq classify_s | gz/fq | separated |
|---|---|---|---|---|---|---|---|
| (no cell ran both -gz and -fq: the gzip candidate is unresolved here) | | | | | | | |

## Candidate signatures per cell (medians over reps; classify window only)

| regime | input | state | T | aqu-sz (NVMe) | aqu/T | r/s | KiB/IO | MiB/s | majflt | bytes/majflt (x 4 KiB) | off-CPU | R | D | S futex | S read | gzip R | IPC | dTLB miss | dTLB walk/kinst | futex/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| madv | SRR062634_250000-gz | cold | 8 | 5.5 | 0.69 | 68633 | 4.0 | 268 | 9656472 | 4100 (1.0) | 0.73 | 0.27 | 0.68 | 0.05 | 3.00e-04 | 2.00e-03 | 1.79 | 0.0219 | 0.65 | 2.49e-01 |
| mmap | SRR062634_2000000-gz | cold | 32 | 30.5 | 0.95 | 40034 | 120.0 | 4693 | 68546535 | 129323 (31.6) | - | 0.07 | 0.91 | 0.02 | 1.00e-04 | 1.30e-03 | - | - | - | - |
| mmap | SRR062634_250000-gz | cold | 8 | 5.9 | 0.74 | 38900 | 120.4 | 4572 | 9636708 | 129342 (31.6) | 0.75 | 0.25 | 0.70 | 0.05 | 2.00e-04 | 1.20e-03 | 1.76 | 0.0050 | 0.16 | 1.35e-01 |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | cold | 32 | 4.0 | 0.13 | 50994 | 4.0 | 199 | 6604518 | 4100 (1.0) | 0.95 | 0.05 | 0.13 | 0.83 | 0.00 | 1.40e-03 | 1.78 | 0.0217 | 0.58 | 1 |
| mmap[read_ahead_kb=4] | ERR478965_200000-gz | warm | 32 | 4.0 | 0.13 | 51346 | 4.0 | 201 | 6341191 | 4100 (1.0) | 0.95 | 0.05 | 0.13 | 0.83 | 1.00e-04 | 1.40e-03 | 1.66 | 0.0207 | 0.57 | 1 |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | cold | 32 | 4.4 | 0.14 | 55088 | 4.0 | 215 | 8077800 | 4099 (1.0) | 0.95 | 0.06 | 0.13 | 0.81 | 0.00 | 1.40e-03 | 1.71 | 0.0216 | 0.64 | 9.89e-01 |
| mmap[read_ahead_kb=4] | ERR598966_200000-gz | warm | 32 | 4.3 | 0.14 | 55212 | 4.0 | 216 | 7776708 | 4100 (1.0) | 0.95 | 0.05 | 0.13 | 0.81 | 0.00 | 1.40e-03 | 1.58 | 0.0214 | 0.62 | 1 |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | cold | 32 | 4.4 | 0.14 | 55430 | 4.0 | 217 | 7787796 | 4100 (1.0) | 0.95 | 0.05 | 0.14 | 0.81 | 1.00e-04 | 1.40e-03 | 1.78 | 0.0216 | 0.63 | 1 |
| mmap[read_ahead_kb=4] | SRR062634_200000-gz | warm | 32 | 4.4 | 0.14 | 55464 | 4.0 | 217 | 7315160 | 4100 (1.0) | 0.95 | 0.05 | 0.14 | 0.81 | 0.00 | 1.70e-03 | 1.71 | 0.0207 | 0.63 | 1 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 32 | 20.6 | 0.64 | 243092 | 4.0 | 951 | 71923088 | 4100 (1.0) | 0.69 | 0.31 | 0.64 | 0.05 | 4.00e-04 | 7.90e-03 | 1.09 | 0.0206 | 0.72 | 6.62e-01 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | cold | 64 | 37.1 | 0.58 | 356735 | 4.0 | 1395 | 72007071 | 4100 (1.0) | 0.71 | 0.35 | 0.58 | 0.06 | 2.00e-04 | 0.01 | 0.90 | 0.0219 | 0.99 | 2 |
| mmap[read_ahead_kb=4] | SRR062634_2000000-gz | warm | 32 | 20.6 | 0.64 | 243657 | 4.0 | 953 | 71188379 | 4100 (1.0) | 0.69 | 0.31 | 0.65 | 0.05 | 3.00e-04 | 7.90e-03 | 1.14 | 0.0208 | 0.76 | 6.71e-01 |
| mmap[read_ahead_kb=4] | SRR062634_250000-gz | cold | 8 | 5.4 | 0.68 | 68279 | 4.0 | 267 | 9656741 | 4100 (1.0) | 0.73 | 0.27 | 0.68 | 0.05 | 5.00e-04 | 2.10e-03 | 1.78 | 0.0210 | 0.65 | 1.70e-01 |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | cold | 32 | 6.1 | 0.19 | 78381 | 4.0 | 306 | 8343896 | 4098 (1.0) | 0.92 | 0.07 | 0.20 | 0.73 | 1.00e-04 | 2.10e-03 | 1.80 | 0.0203 | 0.63 | 1 |
| mmap[read_ahead_kb=4] | SRR28305653_200000-gz | warm | 32 | 6.1 | 0.19 | 78316 | 4.0 | 306 | 7623487 | 4098 (1.0) | 0.92 | 0.08 | 0.19 | 0.73 | 1.00e-04 | 2.30e-03 | 1.70 | 0.0195 | 0.69 | 1 |

## Candidates per regime (mechanical reading; see docs/g2.md for the rules)

One block of rows per ladder (regime / input / state). Critical sections are read only on rungs with >= 2 input blocks per thread: with fewer, idle threads wait at the OpenMP barrier in futex and would look like lock contention.

| ladder | candidate | evidence | could the probe resolve it? |
|---|---|---|---|
| madv / SRR062634_250000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=8 aqu=5.5 (0.69 per busy-able thread, 8) | yes (>= 1000 read IOs per rung) |
| madv / SRR062634_250000-gz / cold | read-around amplification | not seen: T=8 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| madv / SRR062634_250000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=8 | no |
| madv / SRR062634_250000-gz / cold | DRAM/TLB limits | T=8 IPC 1.79 dTLB-miss 0.0219 walk/kinst 0.65 | yes (perf counters present) |
| madv / SRR062634_250000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap / SRR062634_2000000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | seen: T=32 aqu=30.5 (0.95 per busy-able thread, 32) | yes (>= 1000 read IOs per rung) |
| mmap / SRR062634_2000000-gz / cold | read-around amplification | seen: T=32 31.6 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap / SRR062634_2000000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap / SRR062634_2000000-gz / cold | DRAM/TLB limits | no perf counters | no |
| mmap / SRR062634_2000000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap / SRR062634_250000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | seen: T=8 aqu=5.9 (0.74 per busy-able thread, 8) | yes (>= 1000 read IOs per rung) |
| mmap / SRR062634_250000-gz / cold | read-around amplification | seen: T=8 31.6 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap / SRR062634_250000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=8 | no |
| mmap / SRR062634_250000-gz / cold | DRAM/TLB limits | T=8 IPC 1.76 dTLB-miss 0.0050 walk/kinst 0.16 | yes (perf counters present) |
| mmap / SRR062634_250000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.0 (0.67 per busy-able thread, 6) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.78 dTLB-miss 0.0217 walk/kinst 0.58 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.0 (0.67 per busy-able thread, 6) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.66 dTLB-miss 0.0207 walk/kinst 0.57 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR478965_200000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.4 (0.62 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.71 dTLB-miss 0.0216 walk/kinst 0.64 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.3 (0.62 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.58 dTLB-miss 0.0214 walk/kinst 0.62 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / ERR598966_200000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.4 (0.63 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.78 dTLB-miss 0.0216 walk/kinst 0.63 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=4.4 (0.62 per busy-able thread, 7) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.71 dTLB-miss 0.0207 walk/kinst 0.63 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_200000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=20.6 (0.64 per busy-able thread, 32); T=64 aqu=37.1 (0.59 per busy-able thread, 63) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault; T=64 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32,64 | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | DRAM/TLB limits | T=32 IPC 1.09 dTLB-miss 0.0206 walk/kinst 0.72; T=64 IPC 0.90 dTLB-miss 0.0219 walk/kinst 0.99 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=20.6 (0.64 per busy-able thread, 32) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | DRAM/TLB limits | T=32 IPC 1.14 dTLB-miss 0.0208 walk/kinst 0.76 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_2000000-gz / warm | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=8 aqu=5.4 (0.68 per busy-able thread, 8) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | read-around amplification | not seen: T=8 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=8 | no |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | DRAM/TLB limits | T=8 IPC 1.78 dTLB-miss 0.0210 walk/kinst 0.65 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR062634_250000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=6.1 (0.68 per busy-able thread, 9) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | DRAM/TLB limits | T=32 IPC 1.80 dTLB-miss 0.0203 walk/kinst 0.63 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / cold | single-stream gzip | no gz/fq pair | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | sync faults cap NVMe QD (aqu-sz ~ T) | not seen at every T: T=32 aqu=6.1 (0.67 per busy-able thread, 9) | yes (>= 1000 read IOs per rung) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | read-around amplification | not seen: T=32 1.0 x 4 KiB per major fault | yes (>= 1000 major faults) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | critical sections | confounded: fewer than 2 blocks per thread at T=32 | no |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | DRAM/TLB limits | T=32 IPC 1.70 dTLB-miss 0.0195 walk/kinst 0.69 | yes (perf counters present) |
| mmap[read_ahead_kb=4] / SRR28305653_200000-gz / warm | single-stream gzip | no gz/fq pair | no |

