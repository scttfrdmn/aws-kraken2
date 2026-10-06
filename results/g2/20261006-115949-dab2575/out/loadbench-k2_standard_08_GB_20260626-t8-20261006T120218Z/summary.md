# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `dab2575cfdf4546f3a6c9effb66fb5ad43c458d1`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.18.51-120.163.amzn2023.aarch64, r8gd.2xlarge, 8 CPUs, 62 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. Linux aarch64 on EC2 (make run).
Repetitions: 3; threads fixed at 8 for both implementations; states run: cold warm (requested: cold warm; cold available: True, via ak2_drop_caches); 2026-10-06T12:02:18Z to 2026-10-06T12:12:39Z.
Database storage: device /dev/nvme0n1, disk model Amazon EC2 NVMe Instance Storage.
Cold load rate (hash.k2d bytes / median cold load s): 1012–1022 MiB/s over every implementation and input. They agree within 5%: the cold rungs are capped by the storage, so they cannot resolve a difference in the load path itself.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

Noise floor per cell, from 1 A/A control pair(s) (batch → final): the larger of the pairs' largest |Δ median wall| and half the median min–max width of their rungs: empty cold 0.002 s (A/A Δ); empty warm 0.014 s (A/A Δ); pe cold 0.004 s (A/A Δ); pe warm 0.006 s (half range). Verdicts: |Δ| at or below the floor is "within noise (below floor)"; above it, "ranges overlap" or "ranges separated" by the min–max ranges. With one pair the floor itself is a single sample.

## Acceptance: `final` vs upstream, median whole-process wall

| cell | upstream s | final s | Δ s | verdict |
|---|---|---|---|---|
| empty cold | 7.527 [6.791–7.553] | 7.489 [7.488–7.489] | -0.039 | ≤ upstream, above floor, ranges overlap |
| empty warm | 0.265 [0.248–0.278] | 0.249 [0.231–0.276] | -0.016 | ≤ upstream, above floor, ranges overlap |
| pe cold | 7.809 [7.808–7.816] | 7.733 [7.733–7.735] | -0.076 | ≤ upstream (ranges separated) |
| pe warm | 0.474 [0.447–0.474] | 0.427 [0.426–0.431] | -0.047 | ≤ upstream (ranges separated) |

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 7.527 [6.791–7.553] | 7.512 [6.775–7.537] | 0.001 [0.000–0.001] | 0.015 [0.015–0.016] | 6476 [6473–6477] | 1.214 [1.213–1.315] |
| base | 3 | 7.821 [7.820–7.827] | 7.471 [7.471–7.472] | 0.000 [0.000–0.000] | 0.349 [0.348–0.355] | 1956217 [1956217–1956217] | 2.753 [2.744–2.756] |
| thp | 3 | 7.485 [7.485–7.488] | 7.472 [7.471–7.473] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7218 [7216–7288] | 1.247 [1.225–1.285] |
| fill | 3 | 7.486 [7.484–7.488] | 7.472 [7.470–7.474] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7244 [7233–7268] | 1.229 [1.217–1.233] |
| scan | 3 | 7.486 [7.485–7.487] | 7.472 [7.471–7.472] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7250 [7217–7265] | 1.209 [1.209–1.214] |
| recycle | 3 | 7.486 [7.485–7.486] | 7.472 [7.471–7.472] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7232 [7218–7252] | 1.209 [1.207–1.229] |
| rc | 3 | 7.485 [7.484–7.487] | 7.471 [7.470–7.472] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7249 [7243–7265] | 1.221 [1.220–1.227] |
| matesize | 3 | 7.485 [7.483–7.485] | 7.471 [7.469–7.472] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7244 [7229–7251] | 1.217 [1.214–1.234] |
| batch | 3 | 7.487 [7.486–7.488] | 7.473 [7.472–7.474] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7235 [7221–7255] | 1.206 [1.197–1.227] |
| final | 3 | 7.489 [7.488–7.489] | 7.474 [7.473–7.475] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7226 [7221–7249] | 1.210 [1.208–1.221] |

- base − upstream, median wall: +0.294 s (7.821 s vs 7.527 s): > upstream (ranges separated)
- thp − upstream, median wall: -0.042 s (7.485 s vs 7.527 s): ≤ upstream, above floor, ranges overlap
- fill − upstream, median wall: -0.041 s (7.486 s vs 7.527 s): ≤ upstream, above floor, ranges overlap
- scan − upstream, median wall: -0.042 s (7.486 s vs 7.527 s): ≤ upstream, above floor, ranges overlap
- recycle − upstream, median wall: -0.042 s (7.486 s vs 7.527 s): ≤ upstream, above floor, ranges overlap
- rc − upstream, median wall: -0.042 s (7.485 s vs 7.527 s): ≤ upstream, above floor, ranges overlap
- matesize − upstream, median wall: -0.042 s (7.485 s vs 7.527 s): ≤ upstream, above floor, ranges overlap
- batch − upstream, median wall: -0.040 s (7.487 s vs 7.527 s): ≤ upstream, above floor, ranges overlap
- final − upstream, median wall: -0.039 s (7.489 s vs 7.527 s): ≤ upstream, above floor, ranges overlap

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.265 [0.248–0.278] | 0.252 [0.235–0.265] | 0.001 [0.000–0.001] | 0.013 [0.012–0.013] | 6498 [6497–6500] | 1.669 [1.609–1.767] |
| base | 3 | 0.854 [0.848–0.859] | 0.482 [0.478–0.489] | 0.000 [0.000–0.000] | 0.370 [0.370–0.372] | 1956230 [1956225–1956258] | 4.113 [4.075–4.156] |
| thp | 3 | 0.249 [0.247–0.250] | 0.236 [0.234–0.238] | 0.000 [0.000–0.000] | 0.012 [0.012–0.012] | 7256 [7225–7310] | 1.799 [1.793–1.823] |
| fill | 3 | 0.246 [0.240–0.249] | 0.233 [0.228–0.236] | 0.000 [0.000–0.000] | 0.012 [0.012–0.013] | 7260 [7242–7264] | 1.758 [1.727–1.829] |
| scan | 3 | 0.249 [0.240–0.253] | 0.236 [0.227–0.240] | 0.000 [0.000–0.000] | 0.012 [0.012–0.013] | 7252 [7235–7308] | 1.688 [1.611–1.792] |
| recycle | 3 | 0.239 [0.238–0.246] | 0.226 [0.226–0.233] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7252 [7218–7280] | 1.715 [1.682–1.776] |
| rc | 3 | 0.248 [0.242–0.264] | 0.235 [0.229–0.251] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7273 [7264–7279] | 1.696 [1.595–1.771] |
| matesize | 3 | 0.245 [0.244–0.257] | 0.232 [0.231–0.244] | 0.000 [0.000–0.000] | 0.012 [0.012–0.013] | 7257 [7249–7280] | 1.774 [1.640–1.781] |
| batch | 3 | 0.235 [0.230–0.240] | 0.222 [0.217–0.227] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7257 [7237–7347] | 1.688 [1.625–1.696] |
| final | 3 | 0.249 [0.231–0.276] | 0.236 [0.218–0.263] | 0.000 [0.000–0.000] | 0.012 [0.012–0.013] | 7268 [7262–7294] | 1.639 [1.561–1.765] |

- base − upstream, median wall: +0.589 s (0.854 s vs 0.265 s): > upstream (ranges separated)
- thp − upstream, median wall: -0.016 s (0.249 s vs 0.265 s): ≤ upstream, above floor, ranges overlap
- fill − upstream, median wall: -0.019 s (0.246 s vs 0.265 s): ≤ upstream, above floor, ranges overlap
- scan − upstream, median wall: -0.016 s (0.249 s vs 0.265 s): ≤ upstream, above floor, ranges overlap
- recycle − upstream, median wall: -0.026 s (0.239 s vs 0.265 s): ≤ upstream (ranges separated)
- rc − upstream, median wall: -0.017 s (0.248 s vs 0.265 s): ≤ upstream, above floor, ranges overlap
- matesize − upstream, median wall: -0.020 s (0.245 s vs 0.265 s): ≤ upstream, above floor, ranges overlap
- batch − upstream, median wall: -0.030 s (0.235 s vs 0.265 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.016 s (0.249 s vs 0.265 s): ≤ upstream, above floor, ranges overlap

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 7.809 [7.808–7.816] | 7.535 [7.535–7.537] | 0.256 [0.256–0.264] | 0.016 [0.016–0.017] | 50020 [50020–50110] | 1.233 [1.209–1.258] |
| base | 3 | 8.144 [8.130–8.171] | 7.472 [7.472–7.473] | 0.314 [0.298–0.325] | 0.359 [0.358–0.372] | 2014598 [2014380–2014756] | 2.835 [2.821–2.862] |
| thp | 3 | 7.798 [7.797–7.804] | 7.467 [7.458–7.475] | 0.315 [0.301–0.317] | 0.021 [0.021–0.022] | 66121 [65658–66305] | 1.314 [1.196–1.337] |
| fill | 3 | 7.805 [7.802–7.806] | 7.470 [7.460–7.471] | 0.311 [0.310–0.324] | 0.022 [0.021–0.022] | 65942 [65940–65947] | 1.292 [1.206–1.347] |
| scan | 3 | 7.738 [7.738–7.743] | 7.462 [7.456–7.463] | 0.258 [0.254–0.260] | 0.021 [0.021–0.021] | 65368 [64613–65417] | 1.285 [1.219–1.311] |
| recycle | 3 | 7.753 [7.742–7.758] | 7.469 [7.467–7.470] | 0.261 [0.254–0.266] | 0.022 [0.022–0.022] | 66813 [66612–68375] | 1.264 [1.211–1.353] |
| rc | 3 | 7.748 [7.744–7.755] | 7.470 [7.467–7.471] | 0.256 [0.251–0.266] | 0.021 [0.021–0.022] | 66555 [66396–66846] | 1.269 [1.250–1.328] |
| matesize | 3 | 7.729 [7.729–7.745] | 7.463 [7.459–7.479] | 0.244 [0.243–0.246] | 0.023 [0.022–0.023] | 63599 [63400–63618] | 1.237 [1.209–1.291] |
| batch | 3 | 7.738 [7.734–7.739] | 7.473 [7.471–7.475] | 0.242 [0.238–0.246] | 0.021 [0.021–0.023] | 63584 [63572–63847] | 1.282 [1.237–1.292] |
| final | 3 | 7.733 [7.733–7.735] | 7.473 [7.471–7.474] | 0.239 [0.237–0.240] | 0.022 [0.021–0.023] | 63386 [61964–63835] | 1.253 [1.200–1.305] |

- base − upstream, median wall: +0.335 s (8.144 s vs 7.809 s): > upstream (ranges separated)
- thp − upstream, median wall: -0.011 s (7.798 s vs 7.809 s): ≤ upstream (ranges separated)
- fill − upstream, median wall: -0.004 s (7.805 s vs 7.809 s): within noise (below floor)
- scan − upstream, median wall: -0.071 s (7.738 s vs 7.809 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.056 s (7.753 s vs 7.809 s): ≤ upstream (ranges separated)
- rc − upstream, median wall: -0.061 s (7.748 s vs 7.809 s): ≤ upstream (ranges separated)
- matesize − upstream, median wall: -0.080 s (7.729 s vs 7.809 s): ≤ upstream (ranges separated)
- batch − upstream, median wall: -0.072 s (7.738 s vs 7.809 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.076 s (7.733 s vs 7.809 s): ≤ upstream (ranges separated)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.474 [0.447–0.474] | 0.270 [0.243–0.270] | 0.189 [0.189–0.189] | 0.014 [0.014–0.015] | 50633 [50596–50636] | 1.730 [1.662–1.784] |
| base | 3 | 1.143 [1.109–1.153] | 0.486 [0.473–0.505] | 0.263 [0.255–0.266] | 0.382 [0.382–0.393] | 2016129 [2011813–2016803] | 4.159 [3.799–4.217] |
| thp | 3 | 0.486 [0.480–0.504] | 0.229 [0.226–0.235] | 0.233 [0.228–0.253] | 0.021 [0.021–0.023] | 66426 [64629–68655] | 1.783 [1.773–1.789] |
| fill | 3 | 0.519 [0.508–0.525] | 0.238 [0.234–0.257] | 0.252 [0.246–0.259] | 0.021 [0.021–0.022] | 67691 [66808–68488] | 1.716 [1.649–1.849] |
| scan | 3 | 0.453 [0.437–0.454] | 0.234 [0.222–0.238] | 0.194 [0.193–0.198] | 0.021 [0.021–0.022] | 66569 [66543–68344] | 1.812 [1.728–1.889] |
| recycle | 3 | 0.449 [0.446–0.454] | 0.234 [0.227–0.235] | 0.197 [0.193–0.198] | 0.022 [0.021–0.022] | 68555 [68384–68764] | 1.839 [1.803–1.870] |
| rc | 3 | 0.439 [0.427–0.443] | 0.231 [0.221–0.235] | 0.186 [0.185–0.187] | 0.021 [0.021–0.022] | 67944 [67512–68702] | 1.821 [1.699–1.855] |
| matesize | 3 | 0.429 [0.424–0.429] | 0.233 [0.230–0.233] | 0.174 [0.173–0.174] | 0.022 [0.022–0.022] | 65985 [65927–66515] | 1.804 [1.804–1.840] |
| batch | 3 | 0.432 [0.422–0.442] | 0.231 [0.230–0.248] | 0.173 [0.169–0.179] | 0.022 [0.021–0.023] | 66416 [65301–67878] | 1.787 [1.730–1.800] |
| final | 3 | 0.427 [0.426–0.431] | 0.230 [0.229–0.237] | 0.175 [0.169–0.179] | 0.022 [0.021–0.022] | 65987 [65834–66177] | 1.806 [1.784–1.849] |

- base − upstream, median wall: +0.669 s (1.143 s vs 0.474 s): > upstream (ranges separated)
- thp − upstream, median wall: +0.012 s (0.486 s vs 0.474 s): > upstream (ranges separated)
- fill − upstream, median wall: +0.045 s (0.519 s vs 0.474 s): > upstream (ranges separated)
- scan − upstream, median wall: -0.021 s (0.453 s vs 0.474 s): ≤ upstream, above floor, ranges overlap
- recycle − upstream, median wall: -0.024 s (0.449 s vs 0.474 s): ≤ upstream, above floor, ranges overlap
- rc − upstream, median wall: -0.034 s (0.439 s vs 0.474 s): ≤ upstream (ranges separated)
- matesize − upstream, median wall: -0.045 s (0.429 s vs 0.474 s): ≤ upstream (ranges separated)
- batch − upstream, median wall: -0.042 s (0.432 s vs 0.474 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.047 s (0.427 s vs 0.474 s): ≤ upstream (ranges separated)

## Attribution (one row per change, Law 5)

Median [min–max] wall seconds before → after each change, and the difference of the medians, classified by the same rule as the acceptance table (noise floor, then min–max ranges). "(A/A control)" marks a pair with the same binary. Ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 7.821 [7.820–7.827] → 7.485 [7.485–7.488] (-0.336, ≤ (ranges separated)) | 0.854 [0.848–0.859] → 0.249 [0.247–0.250] (-0.605, ≤ (ranges separated)) | 8.144 [8.130–8.171] → 7.798 [7.797–7.804] (-0.347, ≤ (ranges separated)) | 1.143 [1.109–1.153] → 0.486 [0.480–0.504] (-0.656, ≤ (ranges separated)) |
| thp → fill | 7.485 [7.485–7.488] → 7.486 [7.484–7.488] (+0.001, within noise (below floor)) | 0.249 [0.247–0.250] → 0.246 [0.240–0.249] (-0.003, within noise (below floor)) | 7.798 [7.797–7.804] → 7.805 [7.802–7.806] (+0.007, >, above floor, ranges overlap) | 0.486 [0.480–0.504] → 0.519 [0.508–0.525] (+0.033, > (ranges separated)) |
| fill → scan | 7.486 [7.484–7.488] → 7.486 [7.485–7.487] (-0.001, within noise (below floor)) | 0.246 [0.240–0.249] → 0.249 [0.240–0.253] (+0.002, within noise (below floor)) | 7.805 [7.802–7.806] → 7.738 [7.738–7.743] (-0.067, ≤ (ranges separated)) | 0.519 [0.508–0.525] → 0.453 [0.437–0.454] (-0.066, ≤ (ranges separated)) |
| scan → recycle | 7.486 [7.485–7.487] → 7.486 [7.485–7.486] (+0.000, within noise (below floor)) | 0.249 [0.240–0.253] → 0.239 [0.238–0.246] (-0.010, within noise (below floor)) | 7.738 [7.738–7.743] → 7.753 [7.742–7.758] (+0.015, >, above floor, ranges overlap) | 0.453 [0.437–0.454] → 0.449 [0.446–0.454] (-0.003, within noise (below floor)) |
| recycle → rc | 7.486 [7.485–7.486] → 7.485 [7.484–7.487] (-0.000, within noise (below floor)) | 0.239 [0.238–0.246] → 0.248 [0.242–0.264] (+0.009, within noise (below floor)) | 7.753 [7.742–7.758] → 7.748 [7.744–7.755] (-0.006, ≤, above floor, ranges overlap) | 0.449 [0.446–0.454] → 0.439 [0.427–0.443] (-0.010, ≤ (ranges separated)) |
| rc → matesize | 7.485 [7.484–7.487] → 7.485 [7.483–7.485] (-0.000, within noise (below floor)) | 0.248 [0.242–0.264] → 0.245 [0.244–0.257] (-0.003, within noise (below floor)) | 7.748 [7.744–7.755] → 7.729 [7.729–7.745] (-0.019, ≤, above floor, ranges overlap) | 0.439 [0.427–0.443] → 0.429 [0.424–0.429] (-0.010, ≤, above floor, ranges overlap) |
| matesize → batch | 7.485 [7.483–7.485] → 7.487 [7.486–7.488] (+0.002, > (ranges separated)) | 0.245 [0.244–0.257] → 0.235 [0.230–0.240] (-0.010, within noise (below floor)) | 7.729 [7.729–7.745] → 7.738 [7.734–7.739] (+0.008, >, above floor, ranges overlap) | 0.429 [0.424–0.429] → 0.432 [0.422–0.442] (+0.003, within noise (below floor)) |
| batch → final (A/A control) | 7.487 [7.486–7.488] → 7.489 [7.488–7.489] (+0.002, within noise (below floor)) | 0.235 [0.230–0.240] → 0.249 [0.231–0.276] (+0.014, within noise (below floor)) | 7.738 [7.734–7.739] → 7.733 [7.733–7.735] (-0.004, within noise (below floor)) | 0.432 [0.422–0.442] → 0.427 [0.426–0.431] (-0.006, within noise (below floor)) |

Output check: every run of an input wrote the same --output bytes.
