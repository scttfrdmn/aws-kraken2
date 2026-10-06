# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `97bd1656f79f1c2a3129b5f81a79bb63ddd644e0`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.18.51-120.163.amzn2023.aarch64, r8gd.2xlarge, 8 CPUs, 62 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. Linux aarch64 on EC2 (make run).
Repetitions: 3; threads fixed at 8 for both implementations; states run: cold warm (requested: cold warm; cold available: True, via ak2_drop_caches); 2026-10-06T11:21:35Z to 2026-10-06T11:29:15Z.
Database storage: device /dev/nvme0n1, disk model Amazon EC2 NVMe Instance Storage.
Cold load rate (hash.k2d bytes / median cold load s): 1012–1021 MiB/s over every implementation and input. They agree within 5%: the cold rungs are capped by the storage, so they cannot resolve a difference in the load path itself.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

No A/A control pair in this run: "within noise" falls back to overlapping min–max ranges, which is lax at small n.

## Acceptance: `final` vs upstream, median whole-process wall

| cell | upstream s | final s | Δ s | verdict |
|---|---|---|---|---|
| empty cold | 7.526 [6.718–7.526] | 7.486 [7.485–7.486] | -0.040 | ≤ upstream by median, within noise |
| empty warm | 0.267 [0.261–0.268] | 0.253 [0.245–0.254] | -0.013 | ≤ upstream (ranges separated) |
| pe cold | 7.806 [7.779–7.807] | 7.732 [7.731–7.737] | -0.074 | ≤ upstream (ranges separated) |
| pe warm | 0.453 [0.449–0.457] | 0.463 [0.448–0.464] | +0.009 | > upstream by median, within noise |

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 7.526 [6.718–7.526] | 7.510 [6.703–7.511] | 0.001 [0.000–0.001] | 0.015 [0.014–0.015] | 6474 [6473–6477] | 1.219 [1.219–1.306] |
| base | 3 | 7.822 [7.820–7.827] | 7.471 [7.470–7.471] | 0.000 [0.000–0.000] | 0.350 [0.349–0.355] | 1956183 [1956174–1956184] | 2.749 [2.741–2.750] |
| thp | 3 | 7.486 [7.485–7.487] | 7.472 [7.471–7.473] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7226 [7222–7230] | 1.259 [1.210–1.303] |
| fill | 3 | 7.486 [7.485–7.486] | 7.471 [7.471–7.471] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7260 [7222–7286] | 1.242 [1.236–1.256] |
| scan | 3 | 7.486 [7.485–7.486] | 7.472 [7.471–7.472] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7244 [7205–7259] | 1.242 [1.205–1.243] |
| recycle | 3 | 7.486 [7.485–7.486] | 7.472 [7.471–7.472] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7237 [7209–7268] | 1.212 [1.175–1.224] |
| final | 3 | 7.486 [7.485–7.486] | 7.472 [7.471–7.472] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7267 [7252–7276] | 1.218 [1.195–1.218] |

- base − upstream, median wall: +0.297 s (7.822 s vs 7.526 s): > upstream
- thp − upstream, median wall: -0.040 s (7.486 s vs 7.526 s): ≤ upstream by median, within noise
- fill − upstream, median wall: -0.040 s (7.486 s vs 7.526 s): ≤ upstream by median, within noise
- scan − upstream, median wall: -0.040 s (7.486 s vs 7.526 s): ≤ upstream by median, within noise
- recycle − upstream, median wall: -0.040 s (7.486 s vs 7.526 s): ≤ upstream by median, within noise
- final − upstream, median wall: -0.040 s (7.486 s vs 7.526 s): ≤ upstream by median, within noise

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.267 [0.261–0.268] | 0.253 [0.248–0.255] | 0.001 [0.001–0.001] | 0.013 [0.013–0.013] | 6502 [6496–6503] | 1.805 [1.785–1.879] |
| base | 3 | 0.876 [0.858–0.938] | 0.504 [0.488–0.564] | 0.000 [0.000–0.000] | 0.372 [0.370–0.374] | 1956224 [1956219–1956235] | 3.967 [3.700–4.134] |
| thp | 3 | 0.255 [0.253–0.260] | 0.242 [0.241–0.247] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7253 [7244–7290] | 1.781 [1.771–1.882] |
| fill | 3 | 0.275 [0.259–0.278] | 0.262 [0.246–0.265] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7266 [7251–7266] | 1.685 [1.635–1.898] |
| scan | 3 | 0.254 [0.246–0.258] | 0.242 [0.234–0.245] | 0.000 [0.000–0.000] | 0.012 [0.012–0.013] | 7257 [7246–7280] | 1.833 [1.799–1.840] |
| recycle | 3 | 0.251 [0.248–0.254] | 0.238 [0.235–0.241] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7262 [7245–7291] | 1.775 [1.742–1.786] |
| final | 3 | 0.253 [0.245–0.254] | 0.240 [0.233–0.242] | 0.000 [0.000–0.000] | 0.012 [0.012–0.013] | 7262 [7229–7267] | 1.820 [1.721–1.867] |

- base − upstream, median wall: +0.609 s (0.876 s vs 0.267 s): > upstream
- thp − upstream, median wall: -0.012 s (0.255 s vs 0.267 s): ≤ upstream (ranges separated)
- fill − upstream, median wall: +0.008 s (0.275 s vs 0.267 s): > upstream by median, within noise
- scan − upstream, median wall: -0.012 s (0.254 s vs 0.267 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.016 s (0.251 s vs 0.267 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.013 s (0.253 s vs 0.267 s): ≤ upstream (ranges separated)

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 7.806 [7.779–7.807] | 7.536 [7.511–7.538] | 0.253 [0.252–0.253] | 0.017 [0.016–0.017] | 49893 [49890–49895] | 1.264 [1.187–1.306] |
| base | 3 | 8.128 [8.125–8.139] | 7.471 [7.469–7.471] | 0.289 [0.287–0.305] | 0.366 [0.364–0.367] | 2014611 [2014433–2014880] | 2.798 [2.772–2.827] |
| thp | 3 | 7.790 [7.778–7.793] | 7.471 [7.471–7.472] | 0.296 [0.285–0.300] | 0.021 [0.021–0.021] | 66170 [65557–66924] | 1.295 [1.209–1.299] |
| fill | 3 | 7.779 [7.770–7.780] | 7.470 [7.470–7.471] | 0.286 [0.279–0.288] | 0.021 [0.021–0.022] | 65975 [65515–66188] | 1.311 [1.273–1.327] |
| scan | 3 | 7.731 [7.730–7.732] | 7.471 [7.471–7.472] | 0.237 [0.237–0.238] | 0.022 [0.021–0.022] | 65881 [65808–65904] | 1.270 [1.224–1.287] |
| recycle | 3 | 7.733 [7.732–7.734] | 7.472 [7.471–7.472] | 0.239 [0.238–0.240] | 0.022 [0.021–0.022] | 66970 [66892–67512] | 1.235 [1.187–1.295] |
| final | 3 | 7.732 [7.731–7.737] | 7.472 [7.472–7.473] | 0.238 [0.237–0.240] | 0.021 [0.021–0.024] | 66875 [66724–67513] | 1.243 [1.241–1.309] |

- base − upstream, median wall: +0.322 s (8.128 s vs 7.806 s): > upstream
- thp − upstream, median wall: -0.015 s (7.790 s vs 7.806 s): ≤ upstream by median, within noise
- fill − upstream, median wall: -0.026 s (7.779 s vs 7.806 s): ≤ upstream by median, within noise
- scan − upstream, median wall: -0.075 s (7.731 s vs 7.806 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.072 s (7.733 s vs 7.806 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.074 s (7.732 s vs 7.806 s): ≤ upstream (ranges separated)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.453 [0.449–0.457] | 0.250 [0.247–0.253] | 0.189 [0.188–0.189] | 0.015 [0.014–0.015] | 50602 [50594–50602] | 1.806 [1.761–1.904] |
| base | 3 | 1.107 [1.084–1.182] | 0.468 [0.463–0.557] | 0.237 [0.232–0.255] | 0.387 [0.384–0.389] | 2016406 [2013852–2018194] | 3.959 [3.958–3.990] |
| thp | 3 | 0.510 [0.485–0.527] | 0.238 [0.237–0.255] | 0.250 [0.225–0.252] | 0.021 [0.021–0.021] | 66850 [64436–67539] | 1.861 [1.797–1.918] |
| fill | 3 | 0.501 [0.499–0.517] | 0.238 [0.233–0.240] | 0.245 [0.240–0.256] | 0.021 [0.021–0.023] | 67764 [66305–70030] | 1.789 [1.759–1.812] |
| scan | 3 | 0.456 [0.449–0.462] | 0.241 [0.239–0.241] | 0.192 [0.190–0.200] | 0.021 [0.021–0.022] | 67179 [66075–67512] | 1.854 [1.846–1.906] |
| recycle | 3 | 0.460 [0.446–0.462] | 0.240 [0.234–0.241] | 0.197 [0.190–0.199] | 0.022 [0.021–0.023] | 69966 [69845–70843] | 1.846 [1.751–1.916] |
| final | 3 | 0.463 [0.448–0.464] | 0.242 [0.232–0.244] | 0.196 [0.195–0.200] | 0.022 [0.021–0.023] | 69650 [69281–70218] | 1.882 [1.759–1.906] |

- base − upstream, median wall: +0.654 s (1.107 s vs 0.453 s): > upstream
- thp − upstream, median wall: +0.056 s (0.510 s vs 0.453 s): > upstream
- fill − upstream, median wall: +0.048 s (0.501 s vs 0.453 s): > upstream
- scan − upstream, median wall: +0.002 s (0.456 s vs 0.453 s): > upstream by median, within noise
- recycle − upstream, median wall: +0.007 s (0.460 s vs 0.453 s): > upstream by median, within noise
- final − upstream, median wall: +0.009 s (0.463 s vs 0.453 s): > upstream by median, within noise

## Attribution (one row per change, Law 5)

Median [min–max] wall seconds before → after each change, and the difference of the medians; "within noise" where it is at or below the cell's noise floor (above), or, without a control pair, where the min–max ranges overlap. "(A/A control)" marks a pair with the same binary. Ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 7.822 [7.820–7.827] → 7.486 [7.485–7.487] (-0.336) | 0.876 [0.858–0.938] → 0.255 [0.253–0.260] (-0.621) | 8.128 [8.125–8.139] → 7.790 [7.778–7.793] (-0.337) | 1.107 [1.084–1.182] → 0.510 [0.485–0.527] (-0.597) |
| thp → fill | 7.486 [7.485–7.487] → 7.486 [7.485–7.486] (-0.000, within noise) | 0.255 [0.253–0.260] → 0.275 [0.259–0.278] (+0.020, within noise) | 7.790 [7.778–7.793] → 7.779 [7.770–7.780] (-0.011, within noise) | 0.510 [0.485–0.527] → 0.501 [0.499–0.517] (-0.008, within noise) |
| fill → scan | 7.486 [7.485–7.486] → 7.486 [7.485–7.486] (+0.000, within noise) | 0.275 [0.259–0.278] → 0.254 [0.246–0.258] (-0.020) | 7.779 [7.770–7.780] → 7.731 [7.730–7.732] (-0.048) | 0.501 [0.499–0.517] → 0.456 [0.449–0.462] (-0.046) |
| scan → recycle | 7.486 [7.485–7.486] → 7.486 [7.485–7.486] (+0.000, within noise) | 0.254 [0.246–0.258] → 0.251 [0.248–0.254] (-0.003, within noise) | 7.731 [7.730–7.732] → 7.733 [7.732–7.734] (+0.002, within noise) | 0.456 [0.449–0.462] → 0.460 [0.446–0.462] (+0.005, within noise) |
| recycle → final | 7.486 [7.485–7.486] → 7.486 [7.485–7.486] (+0.000, within noise) | 0.251 [0.248–0.254] → 0.253 [0.245–0.254] (+0.002, within noise) | 7.733 [7.732–7.734] → 7.732 [7.731–7.737] (-0.001, within noise) | 0.460 [0.446–0.462] → 0.463 [0.448–0.464] (+0.002, within noise) |

Output check: every run of an input wrote the same --output bytes.
