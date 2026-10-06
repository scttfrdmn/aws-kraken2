# make loadbench: k2_standard_08_GB_20260626, 8 threads

Commit `5d20b9420a2de0699c05b4fc9005a51320a53e41`; upstream `2731b35f7abb26ec926517274f3d87e78d42fd76` (2.17.2-20-g2731b35). Host: Darwin arm64 27.0.0, Mac16,6, 16 CPUs, 64 GiB, page size 16384, THP enabled `n/a`, defrag `n/a`. NOT a make run on Linux aarch64 EC2: development evidence only.
Repetitions: 3; states run: warm (requested: cold warm; cold available: False, via none); 2026-10-06T09:14:24Z to 2026-10-06T09:14:38Z.

Each cell: median [min–max] over the repetitions. wall: exec to exit. load: exec to "Loading database information... done." on stderr (startup, including upstream's Perl wrapper, plus the opts/taxo/hash loads). classify: the classifier's own "processed in" figure. tail: that line to exit (report, flushes, teardown). minflt: minor page faults of the whole process tree. All from `runs.tsv`.

## input `empty`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.241 [0.241–0.248] | 0.171 [0.169–0.178] | 0.000 [0.000–0.000] | 0.070 [0.070–0.071] | 490989 [490985–490996] | 1.236 [1.235–1.288] |
| base | 3 | 0.219 [0.217–0.224] | 0.153 [0.152–0.154] | 0.000 [0.000–0.000] | 0.065 [0.064–0.071] | 489583 [489571–489585] | 1.229 [1.206–1.240] |
| thp | 3 | 0.219 [0.217–0.224] | 0.151 [0.149–0.155] | 0.000 [0.000–0.000] | 0.069 [0.066–0.069] | 489579 [489569–489586] | 1.227 [1.205–1.251] |
| fill | 3 | 0.225 [0.220–0.226] | 0.153 [0.150–0.154] | 0.000 [0.000–0.000] | 0.073 [0.065–0.075] | 489576 [489573–489590] | 1.238 [1.217–1.243] |
| fill-streams16 | 3 | 0.236 [0.230–0.240] | 0.164 [0.163–0.164] | 0.000 [0.000–0.000] | 0.073 [0.066–0.076] | 489610 [489610–489617] | 2.409 [2.399–2.419] |

- base − upstream, median wall: -0.022 s (0.219 s vs 0.241 s)
- thp − upstream, median wall: -0.022 s (0.219 s vs 0.241 s)
- fill − upstream, median wall: -0.016 s (0.225 s vs 0.241 s)
- fill-streams16 − upstream, median wall: -0.005 s (0.236 s vs 0.241 s)

## input `pe`, warm

| impl | n | wall s | load s | classify s | tail s | minflt | sys s |
|---|---|---|---|---|---|---|---|
| upstream | 3 | 0.371 [0.367–0.382] | 0.173 [0.172–0.173] | 0.128 [0.125–0.137] | 0.070 [0.070–0.072] | 501585 [501581–501648] | 1.331 [1.328–1.335] |
| base | 3 | 0.378 [0.377–0.381] | 0.156 [0.154–0.157] | 0.153 [0.152–0.155] | 0.068 [0.067–0.071] | 504190 [503582–504208] | 1.317 [1.303–1.338] |
| thp | 3 | 0.373 [0.372–0.379] | 0.155 [0.154–0.155] | 0.150 [0.148–0.156] | 0.069 [0.068–0.069] | 504201 [503874–504270] | 1.324 [1.319–1.330] |
| fill | 3 | 0.378 [0.374–0.379] | 0.157 [0.155–0.160] | 0.150 [0.149–0.151] | 0.068 [0.067–0.071] | 504202 [503957–504340] | 1.313 [1.312–1.348] |
| fill-streams16 | 3 | 0.387 [0.387–0.389] | 0.163 [0.159–0.164] | 0.153 [0.144–0.153] | 0.074 [0.070–0.080] | 504248 [503467–504591] | 2.450 [2.355–2.488] |

- base − upstream, median wall: +0.006 s (0.378 s vs 0.371 s)
- thp − upstream, median wall: +0.002 s (0.373 s vs 0.371 s)
- fill − upstream, median wall: +0.006 s (0.378 s vs 0.371 s)
- fill-streams16 − upstream, median wall: +0.016 s (0.387 s vs 0.371 s)

## Attribution (one row per change, Law 5)

Median [min–max] wall seconds before → after each change, and the difference of the medians; "within noise" where the two min–max ranges overlap. Ladder order is `LB_LADDER`'s.

| change | empty warm | pe warm |
|---|---|---|
| base → thp | 0.219 [0.217–0.224] → 0.219 [0.217–0.224] (+0.000, within noise) | 0.378 [0.377–0.381] → 0.373 [0.372–0.379] (-0.005, within noise) |
| thp → fill | 0.219 [0.217–0.224] → 0.225 [0.220–0.226] (+0.006, within noise) | 0.373 [0.372–0.379] → 0.378 [0.374–0.379] (+0.005, within noise) |
| fill → fill-streams16 | 0.225 [0.220–0.226] → 0.236 [0.230–0.240] (+0.011) | 0.378 [0.374–0.379] → 0.387 [0.387–0.389] (+0.010) |

Output check: every run of an input wrote the same --output bytes.
