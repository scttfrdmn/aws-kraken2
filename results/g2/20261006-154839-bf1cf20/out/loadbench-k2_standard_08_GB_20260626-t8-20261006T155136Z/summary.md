# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `bf1cf209885495dd434479ac7054c86bba4773e1`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.18.51-120.163.amzn2023.aarch64, m7g.2xlarge, 8 CPUs, 31 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. Linux aarch64 on EC2 (make run).
Repetitions: cold 3, warm 10; threads fixed at 8 for both implementations; states run: cold warm (requested: cold warm; cold available: True, via ak2_drop_caches); 2026-10-06T15:51:36Z to 2026-10-06T17:09:18Z.
Warm-up (unrecorded, not in any cell): one cold run of upstream on `empty` before the matrix, wall 61.414659 s, load 61.397885 s.
Database storage: device /dev/nvme0n1p1, disk model Amazon Elastic Block Store, EBS {"id": "vol-057e58e7c2fc1e80d", "type": "gp3", "iops": 3000, "throughput_mibps": 125, "size_gib": 80}.
Cold load rate (hash.k2d bytes / median cold load s): 126–127 MiB/s over every implementation and input. They agree within 5%: the cold rungs are capped by the storage, so they cannot resolve a difference in the load path itself.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

Noise floor per cell (largest |Δ median wall| over the A/A control pairs final → final-aa): empty cold 0.022 s; empty warm 0.004 s; pe cold 0.044 s; pe warm 0.004 s. A difference at or below it is marked "within noise".

## Acceptance: `final` vs upstream, median whole-process wall

| cell | upstream s | final s | Δ s | verdict |
|---|---|---|---|---|
| empty cold | 60.453 [60.394–61.102] | 60.340 [60.285–60.342] | -0.113 | ≤ upstream (ranges separated) |
| empty warm | 0.191 [0.183–0.232] | 0.175 [0.167–0.205] | -0.016 | ≤ upstream by median, within noise |
| pe cold | 61.343 [61.340–61.408] | 61.300 [61.270–61.303] | -0.042 | ≤ upstream by median, within noise |
| pe warm | 0.411 [0.405–0.456] | 0.387 [0.378–0.394] | -0.024 | ≤ upstream (ranges separated) |

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 60.453 [60.394–61.102] | 60.436 [60.377–61.086] | 0.001 [0.001–0.001] | 0.016 [0.015–0.016] | 6473 [6472–6476] | 0.996 [0.964–1.000] |
| base | 3 | 60.718 [60.714–61.023] | 60.342 [60.339–60.644] | 0.000 [0.000–0.000] | 0.375 [0.374–0.378] | 1956225 [1956204–1956228] | 2.763 [2.747–2.764] |
| thp | 3 | 60.376 [60.344–60.422] | 60.359 [60.327–60.407] | 0.000 [0.000–0.000] | 0.015 [0.015–0.016] | 7231 [7221–7254] | 1.001 [0.992–1.011] |
| fill | 3 | 60.368 [60.338–60.387] | 60.352 [60.323–60.371] | 0.000 [0.000–0.000] | 0.015 [0.014–0.015] | 7252 [7222–7255] | 0.986 [0.985–0.993] |
| scan | 3 | 60.343 [60.341–60.354] | 60.327 [60.325–60.339] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7273 [7243–7274] | 0.986 [0.968–0.996] |
| recycle | 3 | 60.352 [60.265–60.399] | 60.336 [60.249–60.382] | 0.000 [0.000–0.000] | 0.015 [0.014–0.016] | 7248 [7246–7269] | 0.976 [0.969–0.980] |
| rc | 3 | 60.352 [60.278–60.396] | 60.336 [60.263–60.380] | 0.000 [0.000–0.000] | 0.015 [0.014–0.015] | 7242 [7197–7266] | 0.982 [0.982–0.982] |
| matesize | 3 | 60.361 [60.354–60.417] | 60.345 [60.339–60.401] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7243 [7217–7264] | 0.976 [0.967–1.008] |
| batch | 3 | 60.344 [60.340–60.388] | 60.328 [60.323–60.371] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7257 [7249–7266] | 0.977 [0.966–0.982] |
| final | 3 | 60.340 [60.285–60.342] | 60.324 [60.269–60.326] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7250 [7244–7266] | 0.996 [0.993–1.003] |
| final-aa | 3 | 60.318 [60.267–60.344] | 60.302 [60.250–60.329] | 0.000 [0.000–0.000] | 0.015 [0.014–0.016] | 7237 [7228–7241] | 0.984 [0.983–0.998] |

- base − upstream, median wall: +0.265 s (60.718 s vs 60.453 s): > upstream
- thp − upstream, median wall: -0.077 s (60.376 s vs 60.453 s): ≤ upstream by median, within noise
- fill − upstream, median wall: -0.085 s (60.368 s vs 60.453 s): ≤ upstream (ranges separated)
- scan − upstream, median wall: -0.110 s (60.343 s vs 60.453 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.101 s (60.352 s vs 60.453 s): ≤ upstream by median, within noise
- rc − upstream, median wall: -0.101 s (60.352 s vs 60.453 s): ≤ upstream by median, within noise
- matesize − upstream, median wall: -0.092 s (60.361 s vs 60.453 s): ≤ upstream by median, within noise
- batch − upstream, median wall: -0.109 s (60.344 s vs 60.453 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.113 s (60.340 s vs 60.453 s): ≤ upstream (ranges separated)
- final-aa − upstream, median wall: -0.135 s (60.318 s vs 60.453 s): ≤ upstream (ranges separated)

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 10 | 0.191 [0.183–0.232] | 0.176 [0.168–0.215] | 0.001 [0.001–0.001] | 0.014 [0.014–0.017] | 6501 [6482–6507] | 1.113 [1.061–1.201] |
| base | 10 | 0.836 [0.791–0.905] | 0.450 [0.404–0.521] | 0.000 [0.000–0.000] | 0.385 [0.382–0.388] | 1956220 [1956185–1956266] | 3.619 [3.367–3.828] |
| thp | 10 | 0.177 [0.169–0.191] | 0.162 [0.154–0.177] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7255 [7225–7269] | 1.123 [0.996–1.204] |
| fill | 10 | 0.173 [0.169–0.183] | 0.159 [0.155–0.170] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7250 [7212–7302] | 1.118 [1.096–1.174] |
| scan | 10 | 0.175 [0.166–0.208] | 0.161 [0.153–0.194] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7260 [7200–7285] | 1.094 [0.956–1.267] |
| recycle | 10 | 0.176 [0.166–0.200] | 0.162 [0.153–0.186] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7260 [7228–7274] | 1.105 [0.986–1.217] |
| rc | 10 | 0.172 [0.167–0.197] | 0.157 [0.153–0.183] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7266 [7223–7300] | 1.096 [1.076–1.171] |
| matesize | 10 | 0.173 [0.167–0.195] | 0.159 [0.153–0.180] | 0.000 [0.000–0.001] | 0.014 [0.013–0.014] | 7274 [7233–7387] | 1.100 [1.061–1.212] |
| batch | 10 | 0.174 [0.166–0.194] | 0.161 [0.151–0.179] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7284 [7235–7318] | 1.126 [1.023–1.165] |
| final | 10 | 0.175 [0.167–0.205] | 0.161 [0.154–0.190] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7268 [7249–7351] | 1.092 [1.043–1.154] |
| final-aa | 10 | 0.171 [0.166–0.188] | 0.157 [0.152–0.173] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7282 [7256–7299] | 1.112 [0.969–1.289] |

- base − upstream, median wall: +0.646 s (0.836 s vs 0.191 s): > upstream
- thp − upstream, median wall: -0.014 s (0.177 s vs 0.191 s): ≤ upstream by median, within noise
- fill − upstream, median wall: -0.017 s (0.173 s vs 0.191 s): ≤ upstream by median, within noise
- scan − upstream, median wall: -0.015 s (0.175 s vs 0.191 s): ≤ upstream by median, within noise
- recycle − upstream, median wall: -0.015 s (0.176 s vs 0.191 s): ≤ upstream by median, within noise
- rc − upstream, median wall: -0.019 s (0.172 s vs 0.191 s): ≤ upstream by median, within noise
- matesize − upstream, median wall: -0.017 s (0.173 s vs 0.191 s): ≤ upstream by median, within noise
- batch − upstream, median wall: -0.016 s (0.174 s vs 0.191 s): ≤ upstream by median, within noise
- final − upstream, median wall: -0.016 s (0.175 s vs 0.191 s): ≤ upstream by median, within noise
- final-aa − upstream, median wall: -0.020 s (0.171 s vs 0.191 s): ≤ upstream by median, within noise

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 61.343 [61.340–61.408] | 60.379 [60.377–60.444] | 0.947 [0.946–0.947] | 0.017 [0.017–0.017] | 49563 [49562–49564] | 0.957 [0.911–1.045] |
| base | 3 | 61.670 [61.627–61.686] | 60.323 [60.261–60.328] | 0.972 [0.967–0.979] | 0.384 [0.380–0.386] | 1994064 [1992508–1994150] | 2.841 [2.694–2.988] |
| thp | 3 | 61.332 [61.309–61.335] | 60.341 [60.324–60.344] | 0.964 [0.962–0.971] | 0.022 [0.021–0.022] | 46390 [43332–46398] | 0.998 [0.973–1.176] |
| fill | 3 | 61.321 [61.315–61.328] | 60.330 [60.324–60.330] | 0.974 [0.961–0.975] | 0.022 [0.021–0.022] | 43724 [43229–45232] | 1.080 [0.992–1.102] |
| scan | 3 | 61.273 [61.262–61.312] | 60.332 [60.320–60.371] | 0.918 [0.917–0.919] | 0.022 [0.022–0.023] | 45712 [45357–46282] | 1.043 [0.953–1.054] |
| recycle | 3 | 61.278 [61.188–61.325] | 60.337 [60.247–60.384] | 0.918 [0.918–0.919] | 0.022 [0.021–0.022] | 45155 [40333–47156] | 0.993 [0.967–1.043] |
| rc | 3 | 61.200 [61.191–61.298] | 60.267 [60.261–60.324] | 0.910 [0.907–0.953] | 0.022 [0.020–0.022] | 44572 [33622–46129] | 1.114 [1.031–1.139] |
| matesize | 3 | 61.195 [61.153–61.255] | 60.261 [60.217–60.326] | 0.912 [0.907–0.913] | 0.021 [0.021–0.021] | 41626 [37030–45174] | 0.993 [0.982–1.088] |
| batch | 3 | 61.256 [61.254–61.257] | 60.329 [60.327–60.330] | 0.906 [0.905–0.907] | 0.020 [0.020–0.021] | 37534 [36181–38828] | 0.971 [0.947–0.998] |
| final | 3 | 61.300 [61.270–61.303] | 60.372 [60.337–60.372] | 0.909 [0.906–0.910] | 0.021 [0.021–0.022] | 43868 [41289–44089] | 1.071 [0.984–1.125] |
| final-aa | 3 | 61.256 [61.140–61.265] | 60.325 [60.210–60.336] | 0.907 [0.906–0.908] | 0.022 [0.021–0.022] | 42041 [41876–43554] | 0.969 [0.952–1.055] |

- base − upstream, median wall: +0.327 s (61.670 s vs 61.343 s): > upstream
- thp − upstream, median wall: -0.011 s (61.332 s vs 61.343 s): ≤ upstream by median, within noise
- fill − upstream, median wall: -0.021 s (61.321 s vs 61.343 s): ≤ upstream by median, within noise
- scan − upstream, median wall: -0.070 s (61.273 s vs 61.343 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.064 s (61.278 s vs 61.343 s): ≤ upstream (ranges separated)
- rc − upstream, median wall: -0.142 s (61.200 s vs 61.343 s): ≤ upstream (ranges separated)
- matesize − upstream, median wall: -0.148 s (61.195 s vs 61.343 s): ≤ upstream (ranges separated)
- batch − upstream, median wall: -0.087 s (61.256 s vs 61.343 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.042 s (61.300 s vs 61.343 s): ≤ upstream by median, within noise
- final-aa − upstream, median wall: -0.086 s (61.256 s vs 61.343 s): ≤ upstream (ranges separated)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 10 | 0.411 [0.405–0.456] | 0.174 [0.170–0.219] | 0.220 [0.218–0.222] | 0.016 [0.015–0.017] | 50600 [50578–50633] | 1.173 [1.132–1.305] |
| base | 10 | 1.133 [1.089–1.186] | 0.442 [0.402–0.498] | 0.293 [0.282–0.300] | 0.396 [0.390–0.403] | 2017094 [2015238–2018902] | 3.863 [3.533–3.952] |
| thp | 10 | 0.468 [0.454–0.494] | 0.160 [0.153–0.169] | 0.285 [0.266–0.302] | 0.027 [0.025–0.028] | 67662 [65944–71168] | 1.227 [1.083–1.272] |
| fill | 10 | 0.468 [0.455–0.520] | 0.160 [0.153–0.193] | 0.282 [0.272–0.301] | 0.026 [0.024–0.029] | 67748 [66148–68784] | 1.201 [1.149–1.359] |
| scan | 10 | 0.408 [0.399–0.434] | 0.157 [0.153–0.181] | 0.224 [0.221–0.228] | 0.025 [0.024–0.026] | 66625 [63325–70477] | 1.249 [1.141–1.396] |
| recycle | 10 | 0.416 [0.396–0.434] | 0.164 [0.153–0.176] | 0.226 [0.217–0.237] | 0.026 [0.024–0.029] | 69580 [68309–71904] | 1.216 [1.011–1.386] |
| rc | 10 | 0.405 [0.390–0.425] | 0.161 [0.151–0.175] | 0.217 [0.211–0.222] | 0.026 [0.024–0.030] | 69492 [66647–70729] | 1.218 [1.087–1.326] |
| matesize | 10 | 0.383 [0.377–0.422] | 0.158 [0.153–0.196] | 0.201 [0.197–0.205] | 0.025 [0.024–0.026] | 66139 [65478–68074] | 1.179 [1.046–1.303] |
| batch | 10 | 0.384 [0.373–0.400] | 0.160 [0.152–0.173] | 0.199 [0.195–0.203] | 0.026 [0.024–0.028] | 66025 [65078–67559] | 1.180 [1.129–1.284] |
| final | 10 | 0.387 [0.378–0.394] | 0.160 [0.153–0.171] | 0.198 [0.196–0.208] | 0.025 [0.024–0.027] | 63101 [61673–65024] | 1.199 [1.101–1.362] |
| final-aa | 10 | 0.383 [0.374–0.403] | 0.161 [0.153–0.170] | 0.199 [0.195–0.207] | 0.024 [0.024–0.025] | 63206 [58864–64621] | 1.202 [1.112–1.252] |

- base − upstream, median wall: +0.721 s (1.133 s vs 0.411 s): > upstream
- thp − upstream, median wall: +0.057 s (0.468 s vs 0.411 s): > upstream
- fill − upstream, median wall: +0.057 s (0.468 s vs 0.411 s): > upstream
- scan − upstream, median wall: -0.003 s (0.408 s vs 0.411 s): ≤ upstream by median, within noise
- recycle − upstream, median wall: +0.004 s (0.416 s vs 0.411 s): > upstream
- rc − upstream, median wall: -0.006 s (0.405 s vs 0.411 s): ≤ upstream by median, within noise
- matesize − upstream, median wall: -0.029 s (0.383 s vs 0.411 s): ≤ upstream by median, within noise
- batch − upstream, median wall: -0.027 s (0.384 s vs 0.411 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.024 s (0.387 s vs 0.411 s): ≤ upstream (ranges separated)
- final-aa − upstream, median wall: -0.028 s (0.383 s vs 0.411 s): ≤ upstream (ranges separated)

## Attribution (one row per change, Law 5)

Median [min–max] wall seconds before → after each change, and the difference of the medians; "within noise" where it is at or below the cell's noise floor (above), or, without a control pair, where the min–max ranges overlap. "(A/A control)" marks a pair with the same binary. Ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 60.718 [60.714–61.023] → 60.376 [60.344–60.422] (-0.341) | 0.836 [0.791–0.905] → 0.177 [0.169–0.191] (-0.659) | 61.670 [61.627–61.686] → 61.332 [61.309–61.335] (-0.338) | 1.133 [1.089–1.186] → 0.468 [0.454–0.494] (-0.665) |
| thp → fill | 60.376 [60.344–60.422] → 60.368 [60.338–60.387] (-0.008, within noise) | 0.177 [0.169–0.191] → 0.173 [0.169–0.183] (-0.004, within noise) | 61.332 [61.309–61.335] → 61.321 [61.315–61.328] (-0.011, within noise) | 0.468 [0.454–0.494] → 0.468 [0.455–0.520] (-0.000, within noise) |
| fill → scan | 60.368 [60.338–60.387] → 60.343 [60.341–60.354] (-0.026) | 0.173 [0.169–0.183] → 0.175 [0.166–0.208] (+0.002, within noise) | 61.321 [61.315–61.328] → 61.273 [61.262–61.312] (-0.048) | 0.468 [0.455–0.520] → 0.408 [0.399–0.434] (-0.060) |
| scan → recycle | 60.343 [60.341–60.354] → 60.352 [60.265–60.399] (+0.009, within noise) | 0.175 [0.166–0.208] → 0.176 [0.166–0.200] (+0.000, within noise) | 61.273 [61.262–61.312] → 61.278 [61.188–61.325] (+0.005, within noise) | 0.408 [0.399–0.434] → 0.416 [0.396–0.434] (+0.008) |
| recycle → rc | 60.352 [60.265–60.399] → 60.352 [60.278–60.396] (+0.001, within noise) | 0.176 [0.166–0.200] → 0.172 [0.167–0.197] (-0.004, within noise) | 61.278 [61.188–61.325] → 61.200 [61.191–61.298] (-0.078) | 0.416 [0.396–0.434] → 0.405 [0.390–0.425] (-0.011) |
| rc → matesize | 60.352 [60.278–60.396] → 60.361 [60.354–60.417] (+0.009, within noise) | 0.172 [0.167–0.197] → 0.173 [0.167–0.195] (+0.002, within noise) | 61.200 [61.191–61.298] → 61.195 [61.153–61.255] (-0.005, within noise) | 0.405 [0.390–0.425] → 0.383 [0.377–0.422] (-0.022) |
| matesize → batch | 60.361 [60.354–60.417] → 60.344 [60.340–60.388] (-0.017, within noise) | 0.173 [0.167–0.195] → 0.174 [0.166–0.194] (+0.001, within noise) | 61.195 [61.153–61.255] → 61.256 [61.254–61.257] (+0.061) | 0.383 [0.377–0.422] → 0.384 [0.373–0.400] (+0.002, within noise) |
| batch → final | 60.344 [60.340–60.388] → 60.340 [60.285–60.342] (-0.004, within noise) | 0.174 [0.166–0.194] → 0.175 [0.167–0.205] (+0.000, within noise) | 61.256 [61.254–61.257] → 61.300 [61.270–61.303] (+0.044) | 0.384 [0.373–0.400] → 0.387 [0.378–0.394] (+0.003, within noise) |
| final → final-aa (A/A control) | 60.340 [60.285–60.342] → 60.318 [60.267–60.344] (-0.022, within noise) | 0.175 [0.167–0.205] → 0.171 [0.166–0.188] (-0.004, within noise) | 61.300 [61.270–61.303] → 61.256 [61.140–61.265] (-0.044, within noise) | 0.387 [0.378–0.394] → 0.383 [0.374–0.403] (-0.004, within noise) |

Output check: every run of an input wrote the same --output bytes.
