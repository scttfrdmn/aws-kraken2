# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `dab2575cfdf4546f3a6c9effb66fb5ad43c458d1`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.18.51-120.163.amzn2023.aarch64, m7g.2xlarge, 8 CPUs, 31 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. Linux aarch64 on EC2 (make run).
Repetitions: 3; threads fixed at 8 for both implementations; states run: cold warm (requested: cold warm; cold available: True, via ak2_drop_caches); 2026-10-06T12:22:49Z to 2026-10-06T13:30:49Z.
Database storage: device /dev/nvme0n1p1, disk model Amazon Elastic Block Store, EBS {"id": "vol-049b534f7b147ca3e", "type": "gp3", "iops": 3000, "throughput_mibps": 125, "size_gib": 80}.
Cold load rate (hash.k2d bytes / median cold load s): 126–127 MiB/s over every implementation and input. They agree within 5%: the cold rungs are capped by the storage, so they cannot resolve a difference in the load path itself.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

Noise floor per cell, from 1 A/A control pair(s) (batch → final): the larger of the pairs' largest |Δ median wall| and half the median min–max width of their rungs: empty cold 0.020 s (half range); empty warm 0.004 s (half range); pe cold 0.080 s (A/A Δ); pe warm 0.011 s (half range). Verdicts: |Δ| at or below the floor is "within noise (below floor)"; above it, "ranges overlap" or "ranges separated" by the min–max ranges. With one pair the floor itself is a single sample.

## Acceptance: `final` vs upstream, median whole-process wall

| cell | upstream s | final s | Δ s | verdict |
|---|---|---|---|---|
| empty cold | 60.393 [60.343–61.735] | 60.351 [60.342–60.354] | -0.041 | ≤ upstream, above floor, ranges overlap |
| empty warm | 0.189 [0.188–0.205] | 0.173 [0.173–0.183] | -0.016 | ≤ upstream (ranges separated) |
| pe cold | 61.342 [61.342–61.358] | 61.273 [61.195–61.312] | -0.069 | within noise (below floor) |
| pe warm | 0.409 [0.408–0.418] | 0.387 [0.381–0.406] | -0.022 | ≤ upstream (ranges separated) |

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 60.393 [60.343–61.735] | 60.376 [60.326–61.719] | 0.001 [0.001–0.001] | 0.016 [0.015–0.016] | 6474 [6474–6476] | 0.974 [0.938–0.978] |
| base | 3 | 60.671 [60.643–60.702] | 60.296 [60.270–60.327] | 0.000 [0.000–0.000] | 0.374 [0.373–0.374] | 1956211 [1956182–1956225] | 2.715 [2.705–2.727] |
| thp | 3 | 60.341 [60.341–60.344] | 60.325 [60.325–60.328] | 0.000 [0.000–0.000] | 0.014 [0.014–0.015] | 7233 [7233–7265] | 0.944 [0.915–0.960] |
| fill | 3 | 60.388 [60.341–60.418] | 60.372 [60.325–60.402] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7237 [7223–7238] | 0.940 [0.911–0.976] |
| scan | 3 | 60.362 [60.311–60.424] | 60.346 [60.296–60.408] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7242 [7224–7265] | 0.938 [0.933–0.979] |
| recycle | 3 | 60.344 [60.276–60.346] | 60.328 [60.260–60.331] | 0.000 [0.000–0.000] | 0.015 [0.014–0.015] | 7238 [7220–7268] | 0.939 [0.935–0.961] |
| rc | 3 | 60.342 [60.242–60.389] | 60.327 [60.227–60.374] | 0.000 [0.000–0.000] | 0.014 [0.014–0.015] | 7228 [7158–7247] | 0.937 [0.928–0.959] |
| matesize | 3 | 60.385 [60.342–60.392] | 60.369 [60.326–60.377] | 0.000 [0.000–0.000] | 0.014 [0.014–0.015] | 7241 [7238–7258] | 0.939 [0.937–0.964] |
| batch | 3 | 60.346 [60.346–60.413] | 60.330 [60.329–60.397] | 0.000 [0.000–0.000] | 0.015 [0.015–0.015] | 7239 [7216–7258] | 0.929 [0.921–0.968] |
| final | 3 | 60.351 [60.342–60.354] | 60.335 [60.327–60.339] | 0.000 [0.000–0.000] | 0.014 [0.014–0.015] | 7233 [7231–7235] | 0.936 [0.920–0.966] |

- base − upstream, median wall: +0.278 s (60.671 s vs 60.393 s): > upstream, above floor, ranges overlap
- thp − upstream, median wall: -0.052 s (60.341 s vs 60.393 s): ≤ upstream, above floor, ranges overlap
- fill − upstream, median wall: -0.005 s (60.388 s vs 60.393 s): within noise (below floor)
- scan − upstream, median wall: -0.031 s (60.362 s vs 60.393 s): ≤ upstream, above floor, ranges overlap
- recycle − upstream, median wall: -0.049 s (60.344 s vs 60.393 s): ≤ upstream, above floor, ranges overlap
- rc − upstream, median wall: -0.050 s (60.342 s vs 60.393 s): ≤ upstream, above floor, ranges overlap
- matesize − upstream, median wall: -0.008 s (60.385 s vs 60.393 s): within noise (below floor)
- batch − upstream, median wall: -0.047 s (60.346 s vs 60.393 s): ≤ upstream, above floor, ranges overlap
- final − upstream, median wall: -0.041 s (60.351 s vs 60.393 s): ≤ upstream, above floor, ranges overlap

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.189 [0.188–0.205] | 0.174 [0.174–0.191] | 0.001 [0.001–0.001] | 0.014 [0.013–0.014] | 6502 [6500–6509] | 1.143 [1.079–1.162] |
| base | 3 | 0.880 [0.820–0.895] | 0.502 [0.439–0.516] | 0.000 [0.000–0.000] | 0.379 [0.377–0.381] | 1956208 [1956187–1956210] | 3.495 [3.329–3.707] |
| thp | 3 | 0.173 [0.173–0.175] | 0.159 [0.159–0.161] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7237 [7219–7281] | 1.153 [1.140–1.153] |
| fill | 3 | 0.174 [0.171–0.175] | 0.160 [0.158–0.161] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7276 [7261–7278] | 1.142 [1.138–1.148] |
| scan | 3 | 0.172 [0.172–0.173] | 0.159 [0.159–0.159] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7259 [7247–7284] | 1.147 [1.143–1.149] |
| recycle | 3 | 0.177 [0.172–0.192] | 0.164 [0.159–0.178] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7257 [7252–7263] | 1.147 [1.064–1.188] |
| rc | 3 | 0.173 [0.172–0.189] | 0.159 [0.158–0.176] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7259 [7259–7264] | 1.137 [1.067–1.140] |
| matesize | 3 | 0.174 [0.171–0.174] | 0.160 [0.157–0.160] | 0.000 [0.000–0.000] | 0.013 [0.013–0.013] | 7254 [7253–7267] | 1.137 [1.129–1.146] |
| batch | 3 | 0.171 [0.171–0.176] | 0.157 [0.157–0.162] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7272 [7263–7275] | 1.164 [1.150–1.192] |
| final | 3 | 0.173 [0.173–0.183] | 0.159 [0.159–0.168] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7285 [7272–7304] | 1.152 [1.098–1.176] |

- base − upstream, median wall: +0.691 s (0.880 s vs 0.189 s): > upstream (ranges separated)
- thp − upstream, median wall: -0.016 s (0.173 s vs 0.189 s): ≤ upstream (ranges separated)
- fill − upstream, median wall: -0.015 s (0.174 s vs 0.189 s): ≤ upstream (ranges separated)
- scan − upstream, median wall: -0.016 s (0.172 s vs 0.189 s): ≤ upstream (ranges separated)
- recycle − upstream, median wall: -0.012 s (0.177 s vs 0.189 s): ≤ upstream, above floor, ranges overlap
- rc − upstream, median wall: -0.016 s (0.173 s vs 0.189 s): ≤ upstream, above floor, ranges overlap
- matesize − upstream, median wall: -0.015 s (0.174 s vs 0.189 s): ≤ upstream (ranges separated)
- batch − upstream, median wall: -0.017 s (0.171 s vs 0.189 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.016 s (0.173 s vs 0.189 s): ≤ upstream (ranges separated)

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 61.342 [61.342–61.358] | 60.379 [60.377–60.396] | 0.947 [0.946–0.948] | 0.017 [0.016–0.017] | 49564 [49560–50176] | 1.067 [0.999–1.094] |
| base | 3 | 61.672 [61.587–61.747] | 60.326 [60.230–60.385] | 0.972 [0.966–0.974] | 0.384 [0.379–0.387] | 1994340 [1994146–1995343] | 2.775 [2.663–2.865] |
| thp | 3 | 61.262 [61.234–61.281] | 60.265 [60.243–60.292] | 0.967 [0.966–0.974] | 0.022 [0.022–0.022] | 46633 [44476–46677] | 1.084 [1.040–1.110] |
| fill | 3 | 61.247 [61.235–61.375] | 60.251 [60.248–60.384] | 0.967 [0.962–0.977] | 0.022 [0.021–0.022] | 46119 [45872–46385] | 0.949 [0.936–0.967] |
| scan | 3 | 61.268 [61.266–61.272] | 60.327 [60.322–60.328] | 0.921 [0.919–0.922] | 0.021 [0.021–0.023] | 46009 [44637–48015] | 0.966 [0.896–0.991] |
| recycle | 3 | 61.269 [61.237–61.270] | 60.329 [60.293–60.329] | 0.919 [0.918–0.921] | 0.021 [0.020–0.021] | 42417 [38791–45001] | 0.965 [0.919–1.023] |
| rc | 3 | 61.305 [61.255–61.310] | 60.374 [60.326–60.381] | 0.908 [0.907–0.908] | 0.021 [0.020–0.021] | 40767 [39445–44903] | 0.933 [0.919–0.981] |
| matesize | 3 | 61.256 [61.255–61.277] | 60.327 [60.326–60.346] | 0.908 [0.908–0.909] | 0.020 [0.020–0.020] | 35816 [34991–39616] | 0.974 [0.928–1.022] |
| batch | 3 | 61.193 [61.142–61.253] | 60.265 [60.212–60.327] | 0.907 [0.905–0.907] | 0.020 [0.020–0.021] | 37180 [35141–38613] | 0.983 [0.922–0.999] |
| final | 3 | 61.273 [61.195–61.312] | 60.346 [60.268–60.383] | 0.906 [0.906–0.908] | 0.020 [0.020–0.020] | 37453 [37062–39708] | 0.947 [0.901–1.008] |

- base − upstream, median wall: +0.330 s (61.672 s vs 61.342 s): > upstream (ranges separated)
- thp − upstream, median wall: -0.080 s (61.262 s vs 61.342 s): ≤ upstream (ranges separated)
- fill − upstream, median wall: -0.095 s (61.247 s vs 61.342 s): ≤ upstream, above floor, ranges overlap
- scan − upstream, median wall: -0.074 s (61.268 s vs 61.342 s): within noise (below floor)
- recycle − upstream, median wall: -0.073 s (61.269 s vs 61.342 s): within noise (below floor)
- rc − upstream, median wall: -0.037 s (61.305 s vs 61.342 s): within noise (below floor)
- matesize − upstream, median wall: -0.086 s (61.256 s vs 61.342 s): ≤ upstream (ranges separated)
- batch − upstream, median wall: -0.149 s (61.193 s vs 61.342 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.069 s (61.273 s vs 61.342 s): within noise (below floor)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.409 [0.408–0.418] | 0.175 [0.174–0.182] | 0.218 [0.218–0.221] | 0.016 [0.016–0.016] | 50598 [50596–50626] | 1.209 [1.202–1.223] |
| base | 3 | 1.109 [1.069–1.120] | 0.445 [0.401–0.450] | 0.274 [0.273–0.275] | 0.395 [0.388–0.397] | 2017223 [2016402–2017926] | 3.917 [3.570–3.984] |
| thp | 3 | 0.474 [0.460–0.480] | 0.162 [0.161–0.164] | 0.288 [0.274–0.292] | 0.024 [0.024–0.025] | 66865 [66341–67090] | 1.292 [1.246–1.317] |
| fill | 3 | 0.471 [0.469–0.509] | 0.160 [0.159–0.187] | 0.286 [0.285–0.297] | 0.026 [0.024–0.026] | 67399 [67260–72110] | 1.194 [1.158–1.217] |
| scan | 3 | 0.407 [0.401–0.409] | 0.160 [0.158–0.160] | 0.222 [0.219–0.224] | 0.025 [0.023–0.025] | 66404 [65551–66511] | 1.245 [1.226–1.265] |
| recycle | 3 | 0.434 [0.418–0.439] | 0.177 [0.170–0.184] | 0.224 [0.223–0.237] | 0.025 [0.024–0.027] | 70109 [69174–70498] | 1.179 [1.145–1.184] |
| rc | 3 | 0.399 [0.394–0.399] | 0.158 [0.157–0.160] | 0.214 [0.210–0.215] | 0.026 [0.026–0.026] | 69527 [69445–70195] | 1.216 [1.202–1.234] |
| matesize | 3 | 0.403 [0.385–0.405] | 0.178 [0.159–0.181] | 0.201 [0.198–0.203] | 0.024 [0.024–0.025] | 65904 [65848–67224] | 1.151 [1.105–1.257] |
| batch | 3 | 0.395 [0.381–0.399] | 0.162 [0.159–0.173] | 0.202 [0.197–0.208] | 0.025 [0.024–0.025] | 66196 [65889–66863] | 1.249 [1.197–1.253] |
| final | 3 | 0.387 [0.381–0.406] | 0.160 [0.158–0.185] | 0.197 [0.196–0.202] | 0.025 [0.024–0.025] | 66584 [66378–66666] | 1.198 [1.086–1.257] |

- base − upstream, median wall: +0.700 s (1.109 s vs 0.409 s): > upstream (ranges separated)
- thp − upstream, median wall: +0.065 s (0.474 s vs 0.409 s): > upstream (ranges separated)
- fill − upstream, median wall: +0.062 s (0.471 s vs 0.409 s): > upstream (ranges separated)
- scan − upstream, median wall: -0.002 s (0.407 s vs 0.409 s): within noise (below floor)
- recycle − upstream, median wall: +0.025 s (0.434 s vs 0.409 s): > upstream (ranges separated)
- rc − upstream, median wall: -0.010 s (0.399 s vs 0.409 s): within noise (below floor)
- matesize − upstream, median wall: -0.006 s (0.403 s vs 0.409 s): within noise (below floor)
- batch − upstream, median wall: -0.013 s (0.395 s vs 0.409 s): ≤ upstream (ranges separated)
- final − upstream, median wall: -0.022 s (0.387 s vs 0.409 s): ≤ upstream (ranges separated)

## Attribution (one row per change, Law 5)

Median [min–max] wall seconds before → after each change, and the difference of the medians, classified by the same rule as the acceptance table (noise floor, then min–max ranges). "(A/A control)" marks a pair with the same binary. Ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 60.671 [60.643–60.702] → 60.341 [60.341–60.344] (-0.330, ≤ (ranges separated)) | 0.880 [0.820–0.895] → 0.173 [0.173–0.175] (-0.707, ≤ (ranges separated)) | 61.672 [61.587–61.747] → 61.262 [61.234–61.281] (-0.410, ≤ (ranges separated)) | 1.109 [1.069–1.120] → 0.474 [0.460–0.480] (-0.635, ≤ (ranges separated)) |
| thp → fill | 60.341 [60.341–60.344] → 60.388 [60.341–60.418] (+0.047, >, above floor, ranges overlap) | 0.173 [0.173–0.175] → 0.174 [0.171–0.175] (+0.001, within noise (below floor)) | 61.262 [61.234–61.281] → 61.247 [61.235–61.375] (-0.015, within noise (below floor)) | 0.474 [0.460–0.480] → 0.471 [0.469–0.509] (-0.003, within noise (below floor)) |
| fill → scan | 60.388 [60.341–60.418] → 60.362 [60.311–60.424] (-0.026, ≤, above floor, ranges overlap) | 0.174 [0.171–0.175] → 0.172 [0.172–0.173] (-0.001, within noise (below floor)) | 61.247 [61.235–61.375] → 61.268 [61.266–61.272] (+0.021, within noise (below floor)) | 0.471 [0.469–0.509] → 0.407 [0.401–0.409] (-0.064, ≤ (ranges separated)) |
| scan → recycle | 60.362 [60.311–60.424] → 60.344 [60.276–60.346] (-0.018, within noise (below floor)) | 0.172 [0.172–0.173] → 0.177 [0.172–0.192] (+0.005, >, above floor, ranges overlap) | 61.268 [61.266–61.272] → 61.269 [61.237–61.270] (+0.001, within noise (below floor)) | 0.407 [0.401–0.409] → 0.434 [0.418–0.439] (+0.027, > (ranges separated)) |
| recycle → rc | 60.344 [60.276–60.346] → 60.342 [60.242–60.389] (-0.002, within noise (below floor)) | 0.177 [0.172–0.192] → 0.173 [0.172–0.189] (-0.005, ≤, above floor, ranges overlap) | 61.269 [61.237–61.270] → 61.305 [61.255–61.310] (+0.036, within noise (below floor)) | 0.434 [0.418–0.439] → 0.399 [0.394–0.399] (-0.035, ≤ (ranges separated)) |
| rc → matesize | 60.342 [60.242–60.389] → 60.385 [60.342–60.392] (+0.043, >, above floor, ranges overlap) | 0.173 [0.172–0.189] → 0.174 [0.171–0.174] (+0.001, within noise (below floor)) | 61.305 [61.255–61.310] → 61.256 [61.255–61.277] (-0.049, within noise (below floor)) | 0.399 [0.394–0.399] → 0.403 [0.385–0.405] (+0.004, within noise (below floor)) |
| matesize → batch | 60.385 [60.342–60.392] → 60.346 [60.346–60.413] (-0.039, ≤, above floor, ranges overlap) | 0.174 [0.171–0.174] → 0.171 [0.171–0.176] (-0.002, within noise (below floor)) | 61.256 [61.255–61.277] → 61.193 [61.142–61.253] (-0.062, within noise (below floor)) | 0.403 [0.385–0.405] → 0.395 [0.381–0.399] (-0.008, within noise (below floor)) |
| batch → final (A/A control) | 60.346 [60.346–60.413] → 60.351 [60.342–60.354] (+0.005, within noise (below floor)) | 0.171 [0.171–0.176] → 0.173 [0.173–0.183] (+0.002, within noise (below floor)) | 61.193 [61.142–61.253] → 61.273 [61.195–61.312] (+0.080, within noise (below floor)) | 0.395 [0.381–0.399] → 0.387 [0.381–0.406] (-0.009, within noise (below floor)) |

Output check: every run of an input wrote the same --output bytes.
