# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `16bc8b03c1cf62cf58743eccc677a48768b68e17`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Linux aarch64 6.18.51-120.163.amzn2023.aarch64, r8g.2xlarge, 8 CPUs, 62 GiB, page size 4096, THP enabled `always [madvise] never`, defrag `always defer defer+madvise [madvise] never`. Linux aarch64 on EC2 (make run).
Repetitions: 3; states run: cold warm (requested: cold warm; cold available: True, via ak2_drop_caches); 2026-10-06T10:06:34Z to 2026-10-06T10:47:48Z.
Cold load rate (hash.k2d bytes / median cold load s): 126–127 MiB/s over every implementation and input. They agree within 5%: the cold rungs are capped by the storage, so they cannot resolve a difference in the load path itself.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

## input `empty`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 60.717 [60.427–61.158] | 60.702 [60.412–61.143] | 0.001 [0.000–0.001] | 0.014 [0.014–0.014] | 6475 [6470–6479] | 0.836 [0.750–0.866] |
| base | 3 | 60.681 [60.606–60.683] | 60.323 [60.249–60.327] | 0.000 [0.000–0.000] | 0.357 [0.355–0.357] | 1956182 [1956179–1956217] | 2.352 [2.351–2.358] |
| thp | 3 | 60.388 [60.340–60.517] | 60.373 [60.326–60.503] | 0.000 [0.000–0.000] | 0.013 [0.013–0.014] | 7225 [7223–7261] | 0.871 [0.871–0.876] |
| fill | 3 | 60.350 [60.310–60.361] | 60.335 [60.297–60.345] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7224 [7191–7277] | 0.865 [0.847–0.874] |
| fill-streams16 | 3 | 60.284 [60.238–60.413] | 60.269 [60.223–60.399] | 0.000 [0.000–0.000] | 0.014 [0.013–0.014] | 7264 [7254–7301] | 0.854 [0.829–0.869] |

- base − upstream, median wall: -0.036 s (60.681 s vs 60.717 s)
- thp − upstream, median wall: -0.329 s (60.388 s vs 60.717 s)
- fill − upstream, median wall: -0.366 s (60.350 s vs 60.717 s)
- fill-streams16 − upstream, median wall: -0.432 s (60.284 s vs 60.717 s)

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.194 [0.190–0.196] | 0.181 [0.177–0.182] | 0.001 [0.001–0.001] | 0.013 [0.012–0.013] | 6501 [6498–6504] | 1.226 [1.183–1.244] |
| base | 3 | 0.782 [0.761–0.847] | 0.429 [0.407–0.493] | 0.000 [0.000–0.000] | 0.354 [0.353–0.355] | 1956206 [1956184–1956254] | 3.611 [3.505–3.676] |
| thp | 3 | 0.190 [0.182–0.193] | 0.177 [0.169–0.180] | 0.000 [0.000–0.000] | 0.012 [0.012–0.013] | 7291 [7271–7295] | 1.221 [1.111–1.248] |
| fill | 3 | 0.186 [0.181–0.186] | 0.173 [0.168–0.174] | 0.000 [0.000–0.000] | 0.012 [0.012–0.012] | 7259 [7251–7268] | 1.203 [1.203–1.226] |
| fill-streams16 | 3 | 0.177 [0.171–0.182] | 0.164 [0.158–0.168] | 0.000 [0.000–0.000] | 0.013 [0.012–0.013] | 7307 [7277–7322] | 1.211 [1.188–1.223] |

- base − upstream, median wall: +0.588 s (0.782 s vs 0.194 s)
- thp − upstream, median wall: -0.004 s (0.190 s vs 0.194 s)
- fill − upstream, median wall: -0.008 s (0.186 s vs 0.194 s)
- fill-streams16 − upstream, median wall: -0.017 s (0.177 s vs 0.194 s)

## input `pe`, cold

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 61.360 [61.352–61.371] | 60.421 [60.412–60.433] | 0.924 [0.923–0.925] | 0.015 [0.005–0.015] | 49562 [49558–50174] | 0.928 [0.904–0.932] |
| base | 3 | 61.571 [61.533–61.629] | 60.259 [60.225–60.328] | 0.947 [0.939–0.948] | 0.360 [0.359–0.364] | 1995237 [1993434–1998243] | 2.431 [2.284–2.503] |
| thp | 3 | 61.288 [61.226–61.313] | 60.326 [60.262–60.358] | 0.940 [0.934–0.942] | 0.021 [0.020–0.021] | 46213 [43351–46371] | 0.919 [0.889–0.943] |
| fill | 3 | 61.310 [61.240–61.319] | 60.346 [60.280–60.359] | 0.939 [0.938–0.944] | 0.020 [0.019–0.021] | 44003 [43430–48331] | 0.952 [0.894–0.985] |
| fill-streams16 | 3 | 61.225 [61.213–61.305] | 60.248 [60.246–60.349] | 0.942 [0.934–0.957] | 0.021 [0.021–0.021] | 46530 [45295–47932] | 0.957 [0.820–1.011] |

- base − upstream, median wall: +0.211 s (61.571 s vs 61.360 s)
- thp − upstream, median wall: -0.073 s (61.288 s vs 61.360 s)
- fill − upstream, median wall: -0.051 s (61.310 s vs 61.360 s)
- fill-streams16 − upstream, median wall: -0.135 s (61.225 s vs 61.360 s)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.387 [0.382–0.389] | 0.185 [0.179–0.186] | 0.188 [0.188–0.188] | 0.014 [0.014–0.014] | 50600 [50595–50632] | 1.315 [1.270–1.335] |
| base | 3 | 0.999 [0.996–1.022] | 0.398 [0.384–0.421] | 0.235 [0.229–0.250] | 0.366 [0.364–0.369] | 2015982 [2014564–2020333] | 3.606 [3.417–3.694] |
| thp | 3 | 0.430 [0.428–0.445] | 0.173 [0.167–0.174] | 0.237 [0.232–0.248] | 0.024 [0.022–0.024] | 66208 [66005–68296] | 1.300 [1.219–1.354] |
| fill | 3 | 0.437 [0.424–0.445] | 0.172 [0.170–0.174] | 0.241 [0.230–0.251] | 0.023 [0.022–0.023] | 67937 [64603–68487] | 1.297 [1.291–1.306] |
| fill-streams16 | 3 | 0.430 [0.429–0.430] | 0.164 [0.164–0.172] | 0.241 [0.234–0.242] | 0.023 [0.023–0.024] | 67855 [67095–67881] | 1.329 [1.229–1.340] |

- base − upstream, median wall: +0.612 s (0.999 s vs 0.387 s)
- thp − upstream, median wall: +0.043 s (0.430 s vs 0.387 s)
- fill − upstream, median wall: +0.050 s (0.437 s vs 0.387 s)
- fill-streams16 − upstream, median wall: +0.042 s (0.430 s vs 0.387 s)

## Attribution (one row per change, Law 5)

Median [min–max] wall seconds before → after each change, and the difference of the medians; "within noise" where the two min–max ranges overlap. Ladder order is `LB_LADDER`'s.

| change | empty cold | empty warm | pe cold | pe warm |
|---|---|---|---|---|
| base → thp | 60.681 [60.606–60.683] → 60.388 [60.340–60.517] (-0.293) | 0.782 [0.761–0.847] → 0.190 [0.182–0.193] (-0.593) | 61.571 [61.533–61.629] → 61.288 [61.226–61.313] (-0.284) | 0.999 [0.996–1.022] → 0.430 [0.428–0.445] (-0.569) |
| thp → fill | 60.388 [60.340–60.517] → 60.350 [60.310–60.361] (-0.037, within noise) | 0.190 [0.182–0.193] → 0.186 [0.181–0.186] (-0.004, within noise) | 61.288 [61.226–61.313] → 61.310 [61.240–61.319] (+0.022, within noise) | 0.430 [0.428–0.445] → 0.437 [0.424–0.445] (+0.007, within noise) |
| fill → fill-streams16 | 60.350 [60.310–60.361] → 60.284 [60.238–60.413] (-0.066, within noise) | 0.186 [0.181–0.186] → 0.177 [0.171–0.182] (-0.009, within noise) | 61.310 [61.240–61.319] → 61.225 [61.213–61.305] (-0.085, within noise) | 0.437 [0.424–0.445] → 0.430 [0.429–0.430] (-0.008, within noise) |

Output check: every run of an input wrote the same --output bytes.
