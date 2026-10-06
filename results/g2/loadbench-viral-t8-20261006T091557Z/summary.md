# make loadbench: k2_viral_20260626, 8 threads

Commit `95111e64afe4e234b2e1ab35c9a3316c5b609ec3`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.12.13-200.fc41.aarch64, Apple Virtualization Generic Platform, 8 CPUs, 8 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. NOT a make run on Linux aarch64 EC2: development evidence only.
Repetitions: 3; states run: cold warm (requested: cold warm; cold available: True, via drop_caches-root); 2026-10-06T09:15:57Z to 2026-10-06T09:16:18Z.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.033 [0.032–0.145] | 0.031 [0.031–0.142] | 0.001 [0.001–0.001] | 0.001 [0.001–0.002] | 2120 [2120–2121] | 0.120 [0.069–0.121] |
| base | 3 | 0.051 [0.049–0.056] | 0.037 [0.035–0.040] | 0.000 [0.000–0.000] | 0.013 [0.013–0.015] | 160221 [160213–160233] | 0.258 [0.246–0.283] |
| thp | 3 | 0.023 [0.022–0.024] | 0.021 [0.020–0.022] | 0.000 [0.000–0.000] | 0.001 [0.001–0.001] | 2308 [2307–2345] | 0.114 [0.110–0.116] |
| fill | 3 | 0.023 [0.022–0.023] | 0.021 [0.021–0.021] | 0.000 [0.000–0.000] | 0.001 [0.001–0.001] | 2312 [2293–2335] | 0.113 [0.113–0.115] |
| fill-streams16 | 3 | 0.023 [0.023–0.024] | 0.021 [0.021–0.022] | 0.000 [0.000–0.000] | 0.001 [0.001–0.001] | 2410 [2387–2430] | 0.123 [0.121–0.125] |

- base − upstream, median wall: +0.018 s (0.051 s vs 0.033 s)
- thp − upstream, median wall: -0.010 s (0.023 s vs 0.033 s)
- fill − upstream, median wall: -0.010 s (0.023 s vs 0.033 s)
- fill-streams16 − upstream, median wall: -0.010 s (0.023 s vs 0.033 s)

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.019 [0.019–0.019] | 0.018 [0.018–0.018] | 0.001 [0.001–0.001] | 0.001 [0.001–0.001] | 2132 [2131–2133] | 0.070 [0.068–0.077] |
| base | 3 | 0.045 [0.044–0.051] | 0.031 [0.031–0.037] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 160225 [160211–160228] | 0.223 [0.219–0.270] |
| thp | 3 | 0.015 [0.015–0.015] | 0.013 [0.013–0.013] | 0.000 [0.000–0.000] | 0.001 [0.001–0.001] | 2306 [2301–2318] | 0.072 [0.056–0.073] |
| fill | 3 | 0.014 [0.014–0.015] | 0.013 [0.013–0.013] | 0.000 [0.000–0.000] | 0.001 [0.001–0.001] | 2336 [2325–2348] | 0.070 [0.067–0.072] |
| fill-streams16 | 3 | 0.015 [0.014–0.015] | 0.013 [0.012–0.014] | 0.000 [0.000–0.000] | 0.001 [0.001–0.001] | 2370 [2325–2401] | 0.070 [0.069–0.070] |

- base − upstream, median wall: +0.025 s (0.045 s vs 0.019 s)
- thp − upstream, median wall: -0.005 s (0.015 s vs 0.019 s)
- fill − upstream, median wall: -0.005 s (0.014 s vs 0.019 s)
- fill-streams16 − upstream, median wall: -0.004 s (0.015 s vs 0.019 s)

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.300 [0.300–0.303] | 0.030 [0.030–0.031] | 0.268 [0.268–0.272] | 0.002 [0.001–0.002] | 39731 [39730–40079] | 0.142 [0.133–0.143] |
| base | 3 | 0.403 [0.403–0.408] | 0.037 [0.036–0.037] | 0.349 [0.348–0.354] | 0.016 [0.016–0.016] | 214877 [214478–215513] | 0.296 [0.290–0.302] |
| thp | 3 | 0.352 [0.348–0.369] | 0.022 [0.021–0.023] | 0.324 [0.321–0.340] | 0.005 [0.005–0.006] | 57269 [57132–57351] | 0.155 [0.147–0.156] |
| fill | 3 | 0.381 [0.367–0.393] | 0.021 [0.021–0.022] | 0.354 [0.339–0.365] | 0.005 [0.005–0.005] | 57564 [57117–57638] | 0.148 [0.144–0.152] |
| fill-streams16 | 3 | 0.363 [0.355–0.371] | 0.021 [0.020–0.021] | 0.336 [0.328–0.344] | 0.006 [0.006–0.006] | 57438 [57305–59217] | 0.168 [0.168–0.170] |

- base − upstream, median wall: +0.102 s (0.403 s vs 0.300 s)
- thp − upstream, median wall: +0.051 s (0.352 s vs 0.300 s)
- fill − upstream, median wall: +0.081 s (0.381 s vs 0.300 s)
- fill-streams16 − upstream, median wall: +0.063 s (0.363 s vs 0.300 s)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.283 [0.282–0.286] | 0.017 [0.017–0.018] | 0.264 [0.264–0.267] | 0.001 [0.001–0.001] | 39741 [39740–39741] | 0.093 [0.086–0.093] |
| base | 3 | 0.397 [0.388–0.413] | 0.030 [0.030–0.034] | 0.349 [0.341–0.361] | 0.016 [0.016–0.017] | 215437 [215371–215561] | 0.259 [0.256–0.283] |
| thp | 3 | 0.344 [0.342–0.362] | 0.013 [0.013–0.013] | 0.325 [0.323–0.342] | 0.005 [0.005–0.005] | 56483 [54219–56896] | 0.105 [0.100–0.113] |
| fill | 3 | 0.358 [0.346–0.358] | 0.013 [0.013–0.013] | 0.339 [0.327–0.339] | 0.006 [0.005–0.006] | 56814 [56727–57356] | 0.104 [0.103–0.112] |
| fill-streams16 | 3 | 0.360 [0.344–0.366] | 0.013 [0.013–0.013] | 0.340 [0.325–0.347] | 0.006 [0.005–0.006] | 56743 [56514–57591] | 0.111 [0.107–0.112] |

- base − upstream, median wall: +0.114 s (0.397 s vs 0.283 s)
- thp − upstream, median wall: +0.061 s (0.344 s vs 0.283 s)
- fill − upstream, median wall: +0.075 s (0.358 s vs 0.283 s)
- fill-streams16 − upstream, median wall: +0.077 s (0.360 s vs 0.283 s)

## Attribution (one row per change, Law 5)

Median wall seconds before → after each change, and the difference; ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 0.051 → 0.023 (-0.028) | 0.045 → 0.015 (-0.030) | 0.403 → 0.352 (-0.051) | 0.397 → 0.344 (-0.053) |
| thp → fill | 0.023 → 0.023 (-0.000) | 0.015 → 0.014 (-0.001) | 0.352 → 0.381 (+0.029) | 0.344 → 0.358 (+0.014) |
| fill → fill-streams16 | 0.023 → 0.023 (+0.000) | 0.014 → 0.015 (+0.001) | 0.381 → 0.363 (-0.018) | 0.358 → 0.360 (+0.002) |

Output check: every run of an input wrote the same --output bytes.
