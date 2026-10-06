# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `5d20b9420a2de0699c05b4fc9005a51320a53e41`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.18.51-120.163.amzn2023.aarch64, m7g.2xlarge, 8 CPUs, 31 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. Linux aarch64 on EC2 (make run).
Repetitions: 3; states run: cold warm (requested: cold warm; cold available: True, via ak2_drop_caches); 2026-10-06T09:16:32Z to 2026-10-06T09:57:34Z.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 60.468 [60.406–61.258] | 60.451 [60.389–61.240] | 0.001 [0.001–0.001] | 0.017 [0.016–0.018] | 6473 [6470–6474] | 0.992 [0.963–1.020] |
| base | 3 | 60.700 [60.637–60.794] | 60.326 [60.256–60.419] | 0.000 [0.000–0.000] | 0.374 [0.373–0.380] | 1956201 [1956196–1956202] | 2.761 [2.753–2.769] |
| thp | 3 | 60.340 [60.262–60.488] | 60.325 [60.246–60.472] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7234 [7232–7279] | 0.989 [0.988–0.990] |
| fill | 3 | 60.347 [60.337–60.389] | 60.330 [60.321–60.373] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7250 [7228–7257] | 0.974 [0.941–0.988] |
| fill-streams16 | 3 | 60.341 [60.336–60.387] | 60.326 [60.320–60.370] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7298 [7295–7331] | 0.962 [0.953–0.977] |

- base − upstream, median wall: +0.232 s (60.700 s vs 60.468 s)
- thp − upstream, median wall: -0.127 s (60.340 s vs 60.468 s)
- fill − upstream, median wall: -0.121 s (60.347 s vs 60.468 s)
- fill-streams16 − upstream, median wall: -0.126 s (60.341 s vs 60.468 s)

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.211 [0.210–0.213] | 0.196 [0.195–0.198] | 0.001 [0.001–0.001] | 0.014 [0.014–0.014] | 6502 [6499–6504] | 1.372 [1.371–1.378] |
| base | 3 | 0.839 [0.826–0.866] | 0.458 [0.441–0.483] | 0.000 [0.000–0.000] | 0.383 [0.380–0.384] | 1956216 [1956207–1956227] | 3.925 [3.808–4.138] |
| thp | 3 | 0.196 [0.193–0.209] | 0.182 [0.179–0.194] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7272 [7261–7282] | 1.335 [1.163–1.356] |
| fill | 3 | 0.194 [0.194–0.196] | 0.181 [0.181–0.181] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7283 [7248–7300] | 1.344 [1.332–1.352] |
| fill-streams16 | 3 | 0.205 [0.194–0.210] | 0.190 [0.180–0.195] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7316 [7300–7321] | 1.296 [1.212–1.323] |

- base − upstream, median wall: +0.628 s (0.839 s vs 0.211 s)
- thp − upstream, median wall: -0.015 s (0.196 s vs 0.211 s)
- fill − upstream, median wall: -0.016 s (0.194 s vs 0.211 s)
- fill-streams16 − upstream, median wall: -0.006 s (0.205 s vs 0.211 s)

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 61.404 [61.347–61.408] | 60.440 [60.383–60.443] | 0.948 [0.947–0.948] | 0.017 [0.008–0.017] | 50175 [49562–50178] | 0.916 [0.867–0.967] |
| base | 3 | 61.687 [61.605–61.693] | 60.329 [60.253–60.330] | 0.971 [0.967–0.981] | 0.384 [0.382–0.385] | 1994700 [1992458–1994963] | 2.881 [2.870–2.914] |
| thp | 3 | 61.305 [61.227–61.318] | 60.306 [60.228–60.323] | 0.975 [0.972–0.976] | 0.023 [0.022–0.023] | 46836 [45991–48250] | 0.997 [0.986–1.024] |
| fill | 3 | 61.328 [61.325–61.377] | 60.331 [60.330–60.384] | 0.971 [0.971–0.974] | 0.022 [0.022–0.022] | 44464 [43986–46243] | 0.976 [0.975–1.076] |
| fill-streams16 | 3 | 61.317 [61.204–61.339] | 60.319 [60.212–60.351] | 0.969 [0.964–0.974] | 0.022 [0.022–0.022] | 44527 [43338–45151] | 1.047 [0.972–1.080] |

- base − upstream, median wall: +0.282 s (61.687 s vs 61.404 s)
- thp − upstream, median wall: -0.099 s (61.305 s vs 61.404 s)
- fill − upstream, median wall: -0.076 s (61.328 s vs 61.404 s)
- fill-streams16 − upstream, median wall: -0.087 s (61.317 s vs 61.404 s)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.430 [0.430–0.431] | 0.194 [0.194–0.194] | 0.220 [0.220–0.220] | 0.016 [0.016–0.016] | 50599 [50596–50632] | 1.392 [1.368–1.402] |
| base | 3 | 1.139 [1.094–1.158] | 0.446 [0.416–0.455] | 0.303 [0.285–0.311] | 0.391 [0.390–0.393] | 2017440 [2014914–2017659] | 3.820 [3.658–3.935] |
| thp | 3 | 0.504 [0.475–0.504] | 0.183 [0.182–0.198] | 0.281 [0.266–0.297] | 0.025 [0.025–0.026] | 70385 [66693–71049] | 1.408 [1.257–1.438] |
| fill | 3 | 0.474 [0.469–0.507] | 0.180 [0.180–0.198] | 0.268 [0.264–0.283] | 0.026 [0.024–0.026] | 67532 [64355–69530] | 1.433 [1.392–1.435] |
| fill-streams16 | 3 | 0.484 [0.470–0.487] | 0.180 [0.177–0.183] | 0.274 [0.268–0.282] | 0.025 [0.025–0.026] | 67199 [66377–67212] | 1.429 [1.218–1.455] |

- base − upstream, median wall: +0.709 s (1.139 s vs 0.430 s)
- thp − upstream, median wall: +0.073 s (0.504 s vs 0.430 s)
- fill − upstream, median wall: +0.044 s (0.474 s vs 0.430 s)
- fill-streams16 − upstream, median wall: +0.054 s (0.484 s vs 0.430 s)

## Attribution (one row per change, Law 5)

Median wall seconds before → after each change, and the difference; ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 60.700 → 60.340 (-0.359) | 0.839 → 0.196 (-0.643) | 61.687 → 61.305 (-0.381) | 1.139 → 0.504 (-0.636) |
| thp → fill | 60.340 → 60.347 (+0.006) | 0.196 → 0.194 (-0.001) | 61.305 → 61.328 (+0.023) | 0.504 → 0.474 (-0.030) |
| fill → fill-streams16 | 60.347 → 60.341 (-0.006) | 0.194 → 0.205 (+0.010) | 61.328 → 61.317 (-0.011) | 0.474 → 0.484 (+0.010) |

Output check: every run of an input wrote the same --output bytes.
