# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `9035dd6687f62bb45e82df1e0968d2d2422655d1`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.18.51-120.163.amzn2023.aarch64, r8gd.2xlarge, 8 CPUs, 62 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. Linux aarch64 on EC2 (make run).
Repetitions: cold 3, warm 10; threads fixed at 8 for both implementations; states run: cold warm (requested: cold warm; cold available: True, via ak2_drop_caches); 2026-10-06T14:02:16Z to 2026-10-06T14:16:10Z.
Warm-up (unrecorded, not in any cell): one cold run of upstream on `empty` before the matrix, wall 6.730015 s, load 6.714048 s.
Database storage: device /dev/nvme0n1, disk model Amazon EC2 NVMe Instance Storage.
Cold load rate (hash.k2d bytes / median cold load s): 1012–1021 MiB/s over every implementation and input. They agree within 5%: the cold rungs are capped by the storage, so they cannot resolve a difference in the load path itself.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

Noise floor per cell (largest |Δ median wall| over the A/A control pairs final → final-aa): empty cold 0.004 s; empty warm 0.002 s; pe cold 0.002 s; pe warm 0.022 s. A difference at or below it is marked "within noise".

## Acceptance: `final` vs upstream, median whole-process wall

| cell | upstream s | final s | Δ s | verdict |
|---|---|---|---|---|
| empty cold | 7.539 [7.527–7.961] | 7.491 [7.489–7.493] | -0.048 | ≤ upstream (ranges separated) |
| empty warm | 0.225 [0.197–0.296] | 0.196 [0.184–0.253] | -0.029 | ≤ upstream by median, within noise |
| pe cold | 7.813 [7.788–7.814] | 7.722 [7.720–7.729] | -0.091 | ≤ upstream (ranges separated) |
| pe warm | 0.420 [0.386–0.478] | 0.397 [0.372–0.457] | -0.023 | ≤ upstream by median, within noise |

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 7.539 [7.527–7.961] | 7.523 [7.510–7.945] | 0.001 [0.001–0.001] | 0.016 [0.015–0.016] | 6476 [6476–6482] | 1.249 [1.248–1.260] |
| base | 3 | 7.827 [7.820–7.833] | 7.471 [7.469–7.474] | 0.000 [0.000–0.000] | 0.356 [0.350–0.358] | 1956199 [1956100–1956230] | 2.793 [2.792–2.808] |
| thp | 3 | 7.486 [7.483–7.486] | 7.471 [7.468–7.471] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7234 [7226–7247] | 1.314 [1.241–1.316] |
| fill | 3 | 7.487 [7.487–7.489] | 7.472 [7.472–7.473] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7240 [7203–7266] | 1.263 [1.245–1.268] |
| scan | 3 | 7.486 [7.485–7.490] | 7.472 [7.471–7.475] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7234 [7215–7238] | 1.266 [1.265–1.272] |
| recycle | 3 | 7.485 [7.483–7.485] | 7.470 [7.469–7.470] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7255 [7200–7260] | 1.267 [1.216–1.269] |
| rc | 3 | 7.486 [7.484–7.487] | 7.471 [7.469–7.472] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7280 [7258–7287] | 1.244 [1.239–1.260] |
| matesize | 3 | 7.486 [7.484–7.490] | 7.471 [7.469–7.475] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7241 [7222–7250] | 1.267 [1.223–1.275] |
| batch | 3 | 7.488 [7.487–7.488] | 7.473 [7.473–7.473] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7265 [7218–7315] | 1.269 [1.243–1.279] |
| final | 3 | 7.491 [7.489–7.493] | 7.476 [7.474–7.478] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7222 [7219–7278] | 1.239 [1.234–1.254] |
| final-aa | 3 | 7.488 [7.486–7.489] | 7.473 [7.471–7.474] | 0.000 [0.000–0.000] | 0.014 [0.014–0.014] | 7238 [7237–7242] | 1.240 [1.240–1.241] |

- base − upstream, median wall: +0.288 s (7.827 s vs 7.539 s): > upstream
- thp − upstream, median wall: -0.053 s (7.486 s vs 7.539 s): ≤ upstream (ranges separated)
- fill − upstream, median wall: -0.052 s (7.487 s vs 7.539 s): ≤ upstream (ranges separated)
- scan − upstream, median wall: -0.052 s (7.486 s vs 7.539 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.054 s (7.485 s vs 7.539 s): ≤ upstream (ranges separated)
- rc − upstream, median wall: -0.053 s (7.486 s vs 7.539 s): ≤ upstream (ranges separated)
- matesize − upstream, median wall: -0.053 s (7.486 s vs 7.539 s): ≤ upstream (ranges separated)
- batch − upstream, median wall: -0.051 s (7.488 s vs 7.539 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.048 s (7.491 s vs 7.539 s): ≤ upstream (ranges separated)
- final-aa − upstream, median wall: -0.051 s (7.488 s vs 7.539 s): ≤ upstream (ranges separated)

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 10 | 0.225 [0.197–0.296] | 0.211 [0.183–0.280] | 0.001 [0.001–0.001] | 0.013 [0.013–0.015] | 6501 [6472–6507] | 1.354 [1.291–1.690] |
| base | 10 | 0.799 [0.771–0.895] | 0.418 [0.390–0.523] | 0.000 [0.000–0.000] | 0.384 [0.372–0.393] | 1956212 [1956147–1956265] | 3.492 [3.243–3.854] |
| thp | 10 | 0.205 [0.186–0.252] | 0.192 [0.172–0.238] | 0.000 [0.000–0.000] | 0.013 [0.012–0.014] | 7266 [7237–7309] | 1.341 [1.249–1.797] |
| fill | 10 | 0.200 [0.184–0.274] | 0.187 [0.172–0.260] | 0.000 [0.000–0.000] | 0.013 [0.012–0.014] | 7264 [7212–7276] | 1.350 [1.297–1.750] |
| scan | 10 | 0.203 [0.185–0.247] | 0.189 [0.171–0.234] | 0.000 [0.000–0.000] | 0.013 [0.012–0.014] | 7266 [7253–7296] | 1.347 [1.229–1.755] |
| recycle | 10 | 0.200 [0.186–0.248] | 0.187 [0.173–0.234] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7274 [7223–7316] | 1.338 [1.293–1.792] |
| rc | 10 | 0.192 [0.184–0.243] | 0.179 [0.171–0.229] | 0.000 [0.000–0.000] | 0.013 [0.012–0.014] | 7262 [7230–7279] | 1.368 [1.313–1.715] |
| matesize | 10 | 0.215 [0.186–0.248] | 0.202 [0.172–0.235] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7248 [7230–7276] | 1.342 [1.230–1.806] |
| batch | 10 | 0.201 [0.189–0.265] | 0.188 [0.175–0.252] | 0.000 [0.000–0.000] | 0.013 [0.012–0.014] | 7274 [7246–7356] | 1.355 [1.243–1.849] |
| final | 10 | 0.196 [0.184–0.253] | 0.182 [0.171–0.239] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7285 [7236–7305] | 1.342 [1.314–1.703] |
| final-aa | 10 | 0.198 [0.183–0.277] | 0.185 [0.170–0.263] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7261 [7238–7294] | 1.345 [1.246–1.690] |

- base − upstream, median wall: +0.575 s (0.799 s vs 0.225 s): > upstream
- thp − upstream, median wall: -0.019 s (0.205 s vs 0.225 s): ≤ upstream by median, within noise
- fill − upstream, median wall: -0.025 s (0.200 s vs 0.225 s): ≤ upstream by median, within noise
- scan − upstream, median wall: -0.021 s (0.203 s vs 0.225 s): ≤ upstream by median, within noise
- recycle − upstream, median wall: -0.024 s (0.200 s vs 0.225 s): ≤ upstream by median, within noise
- rc − upstream, median wall: -0.032 s (0.192 s vs 0.225 s): ≤ upstream by median, within noise
- matesize − upstream, median wall: -0.010 s (0.215 s vs 0.225 s): ≤ upstream by median, within noise
- batch − upstream, median wall: -0.023 s (0.201 s vs 0.225 s): ≤ upstream by median, within noise
- final − upstream, median wall: -0.029 s (0.196 s vs 0.225 s): ≤ upstream by median, within noise
- final-aa − upstream, median wall: -0.027 s (0.198 s vs 0.225 s): ≤ upstream by median, within noise

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 7.813 [7.788–7.814] | 7.542 [7.517–7.543] | 0.254 [0.253–0.254] | 0.017 [0.017–0.017] | 49894 [49892–50118] | 1.267 [1.242–1.379] |
| base | 3 | 8.140 [8.130–8.144] | 7.472 [7.469–7.473] | 0.300 [0.297–0.302] | 0.366 [0.363–0.369] | 2014489 [2014258–2014529] | 2.913 [2.849–2.920] |
| thp | 3 | 7.785 [7.778–7.786] | 7.472 [7.470–7.473] | 0.290 [0.282–0.292] | 0.023 [0.022–0.024] | 66057 [65783–66386] | 1.270 [1.224–1.433] |
| fill | 3 | 7.774 [7.765–7.793] | 7.472 [7.472–7.474] | 0.279 [0.271–0.297] | 0.022 [0.022–0.022] | 65452 [65111–65556] | 1.356 [1.344–1.366] |
| scan | 3 | 7.732 [7.732–7.740] | 7.473 [7.473–7.476] | 0.236 [0.236–0.241] | 0.022 [0.022–0.022] | 65882 [65725–65883] | 1.353 [1.287–1.417] |
| recycle | 3 | 7.736 [7.732–7.737] | 7.472 [7.472–7.474] | 0.241 [0.238–0.242] | 0.022 [0.022–0.022] | 67156 [66668–67221] | 1.299 [1.257–1.344] |
| rc | 3 | 7.727 [7.723–7.729] | 7.472 [7.472–7.473] | 0.231 [0.228–0.234] | 0.022 [0.022–0.022] | 66807 [66223–67209] | 1.285 [1.244–1.312] |
| matesize | 3 | 7.723 [7.720–7.726] | 7.471 [7.468–7.472] | 0.230 [0.229–0.230] | 0.022 [0.021–0.023] | 63536 [63520–64016] | 1.270 [1.238–1.341] |
| batch | 3 | 7.725 [7.724–7.726] | 7.473 [7.473–7.474] | 0.229 [0.227–0.230] | 0.022 [0.022–0.022] | 63770 [63705–63846] | 1.362 [1.307–1.399] |
| final | 3 | 7.722 [7.720–7.729] | 7.473 [7.471–7.478] | 0.229 [0.225–0.229] | 0.021 [0.021–0.021] | 56788 [56614–56906] | 1.289 [1.271–1.314] |
| final-aa | 3 | 7.724 [7.721–7.729] | 7.476 [7.472–7.479] | 0.228 [0.225–0.228] | 0.021 [0.021–0.022] | 56732 [56660–57218] | 1.348 [1.306–1.372] |

- base − upstream, median wall: +0.327 s (8.140 s vs 7.813 s): > upstream
- thp − upstream, median wall: -0.027 s (7.785 s vs 7.813 s): ≤ upstream (ranges separated)
- fill − upstream, median wall: -0.039 s (7.774 s vs 7.813 s): ≤ upstream by median, within noise
- scan − upstream, median wall: -0.081 s (7.732 s vs 7.813 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.076 s (7.736 s vs 7.813 s): ≤ upstream (ranges separated)
- rc − upstream, median wall: -0.086 s (7.727 s vs 7.813 s): ≤ upstream (ranges separated)
- matesize − upstream, median wall: -0.090 s (7.723 s vs 7.813 s): ≤ upstream (ranges separated)
- batch − upstream, median wall: -0.088 s (7.725 s vs 7.813 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.091 s (7.722 s vs 7.813 s): ≤ upstream (ranges separated)
- final-aa − upstream, median wall: -0.088 s (7.724 s vs 7.813 s): ≤ upstream (ranges separated)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 10 | 0.420 [0.386–0.478] | 0.210 [0.177–0.267] | 0.192 [0.190–0.195] | 0.015 [0.015–0.019] | 50597 [50045–50699] | 1.451 [1.345–1.827] |
| base | 10 | 1.081 [1.038–1.127] | 0.428 [0.385–0.461] | 0.254 [0.243–0.259] | 0.403 [0.388–0.418] | 2015302 [2013787–2017214] | 3.635 [3.433–3.989] |
| thp | 10 | 0.474 [0.441–0.509] | 0.191 [0.178–0.242] | 0.252 [0.234–0.259] | 0.025 [0.022–0.028] | 66963 [63949–70574] | 1.474 [1.347–1.850] |
| fill | 10 | 0.466 [0.438–0.501] | 0.191 [0.176–0.230] | 0.249 [0.233–0.255] | 0.025 [0.022–0.030] | 67002 [65968–70513] | 1.445 [1.353–1.773] |
| scan | 10 | 0.416 [0.389–0.472] | 0.190 [0.167–0.256] | 0.197 [0.194–0.212] | 0.025 [0.022–0.029] | 65584 [63961–70707] | 1.459 [1.234–1.855] |
| recycle | 10 | 0.427 [0.392–0.456] | 0.200 [0.166–0.234] | 0.200 [0.196–0.207] | 0.026 [0.022–0.028] | 68436 [67243–70136] | 1.455 [1.354–1.834] |
| rc | 10 | 0.412 [0.389–0.454] | 0.194 [0.174–0.248] | 0.189 [0.184–0.196] | 0.025 [0.022–0.030] | 68180 [67548–71156] | 1.464 [1.365–1.851] |
| matesize | 10 | 0.389 [0.375–0.465] | 0.187 [0.174–0.264] | 0.176 [0.173–0.179] | 0.025 [0.022–0.028] | 65966 [64875–67217] | 1.444 [1.313–1.821] |
| batch | 10 | 0.397 [0.375–0.434] | 0.193 [0.174–0.236] | 0.176 [0.173–0.185] | 0.025 [0.022–0.031] | 66074 [65007–68346] | 1.455 [1.411–1.839] |
| final | 10 | 0.397 [0.372–0.457] | 0.196 [0.172–0.253] | 0.175 [0.173–0.184] | 0.024 [0.021–0.029] | 63266 [60270–65293] | 1.475 [1.385–1.747] |
| final-aa | 10 | 0.375 [0.368–0.439] | 0.176 [0.169–0.235] | 0.174 [0.172–0.182] | 0.024 [0.021–0.026] | 63144 [59296–65244] | 1.427 [1.310–1.810] |

- base − upstream, median wall: +0.661 s (1.081 s vs 0.420 s): > upstream
- thp − upstream, median wall: +0.054 s (0.474 s vs 0.420 s): > upstream
- fill − upstream, median wall: +0.046 s (0.466 s vs 0.420 s): > upstream
- scan − upstream, median wall: -0.004 s (0.416 s vs 0.420 s): ≤ upstream by median, within noise
- recycle − upstream, median wall: +0.007 s (0.427 s vs 0.420 s): > upstream by median, within noise
- rc − upstream, median wall: -0.009 s (0.412 s vs 0.420 s): ≤ upstream by median, within noise
- matesize − upstream, median wall: -0.031 s (0.389 s vs 0.420 s): ≤ upstream by median, within noise
- batch − upstream, median wall: -0.023 s (0.397 s vs 0.420 s): ≤ upstream by median, within noise
- final − upstream, median wall: -0.023 s (0.397 s vs 0.420 s): ≤ upstream by median, within noise
- final-aa − upstream, median wall: -0.045 s (0.375 s vs 0.420 s): ≤ upstream by median, within noise

## Attribution (one row per change, Law 5)

Median [min–max] wall seconds before → after each change, and the difference of the medians; "within noise" where it is at or below the cell's noise floor (above), or, without a control pair, where the min–max ranges overlap. "(A/A control)" marks a pair with the same binary. Ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 7.827 [7.820–7.833] → 7.486 [7.483–7.486] (-0.341) | 0.799 [0.771–0.895] → 0.205 [0.186–0.252] (-0.594) | 8.140 [8.130–8.144] → 7.785 [7.778–7.786] (-0.354) | 1.081 [1.038–1.127] → 0.474 [0.441–0.509] (-0.607) |
| thp → fill | 7.486 [7.483–7.486] → 7.487 [7.487–7.489] (+0.001, within noise) | 0.205 [0.186–0.252] → 0.200 [0.184–0.274] (-0.006) | 7.785 [7.778–7.786] → 7.774 [7.765–7.793] (-0.012) | 0.474 [0.441–0.509] → 0.466 [0.438–0.501] (-0.009, within noise) |
| fill → scan | 7.487 [7.487–7.489] → 7.486 [7.485–7.490] (-0.000, within noise) | 0.200 [0.184–0.274] → 0.203 [0.185–0.247] (+0.004) | 7.774 [7.765–7.793] → 7.732 [7.732–7.740] (-0.042) | 0.466 [0.438–0.501] → 0.416 [0.389–0.472] (-0.050) |
| scan → recycle | 7.486 [7.485–7.490] → 7.485 [7.483–7.485] (-0.001, within noise) | 0.203 [0.185–0.247] → 0.200 [0.186–0.248] (-0.003) | 7.732 [7.732–7.740] → 7.736 [7.732–7.737] (+0.004) | 0.416 [0.389–0.472] → 0.427 [0.392–0.456] (+0.011, within noise) |
| recycle → rc | 7.485 [7.483–7.485] → 7.486 [7.484–7.487] (+0.001, within noise) | 0.200 [0.186–0.248] → 0.192 [0.184–0.243] (-0.008) | 7.736 [7.732–7.737] → 7.727 [7.723–7.729] (-0.009) | 0.427 [0.392–0.456] → 0.412 [0.389–0.454] (-0.015, within noise) |
| rc → matesize | 7.486 [7.484–7.487] → 7.486 [7.484–7.490] (+0.000, within noise) | 0.192 [0.184–0.243] → 0.215 [0.186–0.248] (+0.023) | 7.727 [7.723–7.729] → 7.723 [7.720–7.726] (-0.004) | 0.412 [0.389–0.454] → 0.389 [0.375–0.465] (-0.023) |
| matesize → batch | 7.486 [7.484–7.490] → 7.488 [7.487–7.488] (+0.002, within noise) | 0.215 [0.186–0.248] → 0.201 [0.189–0.265] (-0.014) | 7.723 [7.720–7.726] → 7.725 [7.724–7.726] (+0.002, within noise) | 0.389 [0.375–0.465] → 0.397 [0.375–0.434] (+0.008, within noise) |
| batch → final | 7.488 [7.487–7.488] → 7.491 [7.489–7.493] (+0.003, within noise) | 0.201 [0.189–0.265] → 0.196 [0.184–0.253] (-0.005) | 7.725 [7.724–7.726] → 7.722 [7.720–7.729] (-0.003) | 0.397 [0.375–0.434] → 0.397 [0.372–0.457] (-0.000, within noise) |
| final → final-aa (A/A control) | 7.491 [7.489–7.493] → 7.488 [7.486–7.489] (-0.004, within noise) | 0.196 [0.184–0.253] → 0.198 [0.183–0.277] (+0.002, within noise) | 7.722 [7.720–7.729] → 7.724 [7.721–7.729] (+0.002, within noise) | 0.397 [0.372–0.457] → 0.375 [0.368–0.439] (-0.022, within noise) |

Output check: every run of an input wrote the same --output bytes.
