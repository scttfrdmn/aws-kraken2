### g0c — run `20261006-091414-1b5fe49`

| | |
|---|---|
| commit | `1b5fe49030b75ea6278ae78826f2f502db10b51a` (tree dirty: false) |
| upstream pin | `2731b35f7abb26ec926517274f3d87e78d42fd76` (describe `2.17.2-20-g2731b35`) |
| spec | `runs/g0c-runs.json` (sha256 `83e3585564ac`) |
| instance | 1 × `c8gn.2xlarge` (on-demand), AMI `ami-09325776a00699513` |
| region / AZ | us-west-2 / us-west-2b |
| truffle price at launch | $0.474/h |
| start → stop | 2026-10-06T09:14:55+00:00 → 2026-10-06T09:28:41Z (826 s) |
| cost | $0.108757 — on-demand truffle price x (terminated_at - launch_time), 60 s minimum; compute only, excludes EBS and S3 requests |
| TTL / cost_limit | 50m / $1.0 |
| task | state completed, exit 0, retry_class "" |
| shell flags | inherited `hBc`, after `set +e` `hBc` |
| preflight region | us-west-2, asserted equal to the region of each declared bucket (kraken2-ncbi-refseq-complete-v205) before the spec body ran |
| bucket allow-list | cookbook-942542972736-us-west-2, kraken2-ncbi-refseq-complete-v205. `aws s3`/`s3api` calls outside it were refused; curl and SDK calls are not covered |
| drop_caches usable | true |
| object tags | ok=true: tag-objects: s3://cookbook-942542972736-us-west-2/aws-kraken2/g0c/20261006-091414-1b5fe49/: 15 objects, 14 tagged now, 1 already tagged, 0 failed |
| S3 requests (spec-recorded) | 18238 |
| sample accessions | none |
| tools | spawn 0.123.0, truffle 0.57.1 |

**Bucket Payer**

| bucket | payer (launch host) | payer (instance) |
|---|---|---|
| kraken2-ncbi-refseq-complete-v205 | BucketOwner | BucketOwner |

**Datasets (head-object at launch)**

| object | size (bytes) | ETag | VersionId | LastModified |
|---|---|---|---|---|
| s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205/hash.k2d | 1189091671800 | `f80959f9556b50d76b3e744afdd3b22a-8860` | null | 2023-08-30T13:49:06+00:00 |
| s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205/opts.k2d | 56 | `24fb1753eb45d74643ef13f16562df6b` | null | 2023-08-30T14:00:49+00:00 |

**decoded/object.json**

| field | value |
|---|---|
| uri | s3://kraken2-ncbi-refseq-complete-v205/Kraken2_RefSeqCompleteV205/hash.k2d |
| etag | f80959f9556b50d76b3e744afdd3b22a-8860 |
| version_id | null |
| size | 1189091671800 |
| sha256 | bc6c65498309a6a32b121edec171a7d2189493020b2014e9c7f6c4cf0e96382c |
| sha256_source | out/pass/summary.json |
| sha256_check | tables/checks.tsv all yes: ETag equal at launch, before, on every GET (If-Match + response ETag/Content-Range) and after; bytes streamed == object size; complete pass |

**decoded/pass.json**

| field | value |
|---|---|
| object | https://kraken2-ncbi-refseq-complete-v205.s3.us-west-2.amazonaws.com/Kraken2_RefSeqCompleteV205/hash.k2d |
| etag | f80959f9556b50d76b3e744afdd3b22a-8860 |
| object_bytes | 1189091671800 |
| bytes_streamed | 1189091671800 |
| complete | true |
| sha256 | bc6c65498309a6a32b121edec171a7d2189493020b2014e9c7f6c4cf0e96382c |
| sha256_scope | bytes [0,1189091671800) |
| capacity | 297272917942 |
| header_size | 207831744422 |
| key_bits | 10 |
| value_bits | 22 |
| cells | 297272917942 |
| cells_equal_capacity | true |
| occupied | 207831744422 |
| occupied_equals_header_size | true |
| load_factor | 0.6991277438281459 |
| runs | 45022318699 |
| mean_run | 4.616193710756532 |
| run_p50 | 2 |
| run_p90 | 11 |
| run_p99 | 32 |
| run_p99_9 | 59 |
| run_p99_99 | 89 |
| run_p99_999 | 121 |
| run_p99_9999 | 154 |
| longest_run | 302 |
| longest_run_start_slot | 91471303946 |
| longest_run_wraps | false |
| wrap_run_joined | false |
| theory_runs | 44987242886.79727 |
| theory_runs_ge_longest | 5.023815539137876 |
| theory_mean_run | 4.619792880950121 |
| miss_probes_from_runs | 5.994749487612913 |
| knuth_miss_probes | 6.023390121783806 |
| chunk_bytes | 67108864 |
| workers | 48 |
| window | 72 |
| gomaxprocs | 8 |
| go_version | go1.27.1 |
| started | 2026-10-06T09:16:05Z |
| finished | 2026-10-06T09:28:05Z |
| wall_seconds | 720.56981465 |
| wall_gb_per_s | 1.6502102192243142 |
| sha_busy_seconds | 719.043254111 |
| sha_gb_per_s_while_busy | 1.6537136882956387 |
| consumer_stall_seconds | 1.362297109 |
| fetch_busy_seconds_summed | 15067.134254372 |
| fetch_mb_per_s_per_stream | 78.91956437933534 |
| scan_busy_seconds_summed | 940.666134631 |
| scan_gb_per_s_per_worker | 1.264095334171301 |
| get_requests | 17720 |
| get_retries | 0 |
| knuth_hit_probes_uniform_key_null | 2.161834847658426 |

**decoded/provenance.json**

| field | value |
|---|---|
| decoded_at_commit | b27b55f0dba89f70fac98af6620bd0b42cbcac52 |
| decoded_at | 2026-10-06T09:53:01Z |
| decoder | scripts/post/g0c-runs.sh (k2probe runs output) |

**decoded/rules.json**

| field | value |
|---|---|
| shard_rule | shard i of N (N = 2, 4, ..., 64) owns slots [floor(i*C/N), floor((i+1)*C/N)), C = capacity; its boundary is floor((i+1)*C/N), and i = N-1 ends at the wrap (slot C-1 then slot 0) |
| tail_rule | tail(b) = 0 if slot b-1 is empty, else run_past(b) + 1: the occupied cells from b on (mod C) plus the empty cell that stops a miss probing from b-1; tail(N) = max over its N boundaries |
| theory | expected runs of length L = (C - occupied) * e^{-a(L+1)} (a(L+1))^L / (L+1)!, a = occupied/C (Borel; Poisson model of linear probing: Flajolet, Poblete & Viola 1998; Knuth TAOCP 3, 6.4) |
| knuth | hit 1/2(1+1/(1-a)), miss 1/2(1+1/(1-a)^2) |

**decoded/theory-tail.json**

| field | value |
|---|---|
| rel_residual_65_128 | -0.049125135 |
| rel_residual_129_256 | -0.16032093 |
| observed_257_512 | 35 |
| theory_257_512 | 82.299249 |
| longest_run | 302 |
| observed_runs_ge_longest | 1 |
| theory_runs_ge_longest | 5.023815539137876 |
| borel_over_predicts_long_tail | true |
| source | out/pass/hist.tsv, out/pass/hist-raw.tsv, out/pass/summary.json |

**tables/boundaries.tsv**

| j | slot_b | first_N | slot_b_minus_1_occupied | run_past | tail | run_start | run_len |
|---|---|---|---|---|---|---|---|
| 1 | 4644889342 | 64 | true | 14 | 15 | 4644889337 | 19 |
| 2 | 9289778685 | 32 | true | 8 | 9 | 9289778677 | 16 |
| 3 | 13934668028 | 64 | true | 10 | 11 | 13934668027 | 11 |
| 4 | 18579557371 | 16 | true | 5 | 6 | 18579557357 | 19 |
| 5 | 23224446714 | 64 | false | 0 | 0 | 0 | 0 |
| 6 | 27869336057 | 32 | true | 0 | 1 | 27869336054 | 3 |
| 7 | 32514225399 | 64 | true | 0 | 1 | 32514225397 | 2 |
| 8 | 37159114742 | 8 | true | 14 | 15 | 37159114738 | 18 |
| 9 | 41804004085 | 64 | true | 4 | 5 | 41804004080 | 9 |
| 10 | 46448893428 | 32 | true | 0 | 1 | 46448893425 | 3 |
| 11 | 51093782771 | 64 | true | 4 | 5 | 51093782769 | 6 |
| 12 | 55738672114 | 16 | true | 6 | 7 | 55738672112 | 8 |
| 13 | 60383561456 | 64 | true | 30 | 31 | 60383561455 | 31 |
| 14 | 65028450799 | 32 | false | 0 | 0 | 0 | 0 |
| 15 | 69673340142 | 64 | false | 0 | 0 | 0 | 0 |
| 16 | 74318229485 | 4 | false | 0 | 0 | 0 | 0 |
| 17 | 78963118828 | 64 | true | 6 | 7 | 78963118823 | 11 |
| 18 | 83608008171 | 32 | false | 0 | 0 | 0 | 0 |
| 19 | 88252897514 | 64 | true | 7 | 8 | 88252897513 | 8 |
| 20 | 92897786856 | 16 | false | 0 | 0 | 0 | 0 |
| 21 | 97542676199 | 64 | true | 8 | 9 | 97542676192 | 15 |
| 22 | 102187565542 | 32 | false | 0 | 0 | 0 | 0 |
| 23 | 106832454885 | 64 | true | 0 | 1 | 106832454862 | 23 |
| 24 | 111477344228 | 8 | false | 0 | 0 | 0 | 0 |
| 25 | 116122233571 | 64 | true | 2 | 3 | 116122233570 | 3 |
| 26 | 120767122913 | 32 | false | 0 | 0 | 0 | 0 |
| 27 | 125412012256 | 64 | true | 0 | 1 | 125412012252 | 4 |
| 28 | 130056901599 | 16 | false | 0 | 0 | 0 | 0 |
| 29 | 134701790942 | 64 | true | 3 | 4 | 134701790937 | 8 |
| 30 | 139346680285 | 32 | true | 18 | 19 | 139346680268 | 35 |
| 31 | 143991569628 | 64 | true | 4 | 5 | 143991569627 | 5 |
| 32 | 148636458971 | 2 | true | 12 | 13 | 148636458968 | 15 |
| 33 | 153281348313 | 64 | false | 0 | 0 | 0 | 0 |
| 34 | 157926237656 | 32 | true | 3 | 4 | 157926237654 | 5 |
| 35 | 162571126999 | 64 | false | 0 | 0 | 0 | 0 |
| 36 | 167216016342 | 16 | true | 1 | 2 | 167216016341 | 2 |
| 37 | 171860905685 | 64 | true | 1 | 2 | 171860905684 | 2 |
| 38 | 176505795028 | 32 | true | 4 | 5 | 176505795027 | 5 |
| 39 | 181150684370 | 64 | false | 0 | 0 | 0 | 0 |
| 40 | 185795573713 | 8 | true | 4 | 5 | 185795573700 | 17 |
| 41 | 190440463056 | 64 | false | 0 | 0 | 0 | 0 |
| 42 | 195085352399 | 32 | true | 0 | 1 | 195085352398 | 1 |
| 43 | 199730241742 | 64 | true | 0 | 1 | 199730241740 | 2 |
| 44 | 204375131085 | 16 | true | 2 | 3 | 204375131083 | 4 |
| 45 | 209020020427 | 64 | false | 0 | 0 | 0 | 0 |
| 46 | 213664909770 | 32 | false | 0 | 0 | 0 | 0 |
| 47 | 218309799113 | 64 | true | 18 | 19 | 218309799084 | 47 |
| 48 | 222954688456 | 4 | true | 0 | 1 | 222954688455 | 1 |
| 49 | 227599577799 | 64 | true | 4 | 5 | 227599577798 | 5 |
| 50 | 232244467142 | 32 | true | 4 | 5 | 232244467138 | 8 |
| 51 | 236889356485 | 64 | false | 0 | 0 | 0 | 0 |
| 52 | 241534245827 | 16 | true | 11 | 12 | 241534245819 | 19 |
| 53 | 246179135170 | 64 | true | 3 | 4 | 246179135169 | 4 |
| 54 | 250824024513 | 32 | true | 2 | 3 | 250824024510 | 5 |
| 55 | 255468913856 | 64 | true | 5 | 6 | 255468913838 | 23 |
| 56 | 260113803199 | 8 | true | 4 | 5 | 260113803195 | 8 |
| 57 | 264758692542 | 64 | true | 1 | 2 | 264758692539 | 4 |
| 58 | 269403581884 | 32 | true | 0 | 1 | 269403581882 | 2 |
| 59 | 274048471227 | 64 | true | 1 | 2 | 274048471218 | 10 |
| 60 | 278693360570 | 16 | true | 9 | 10 | 278693360567 | 12 |

_60 of 64 rows shown; full table in the file._

**tables/checks.tsv**

| check | observed | expected | ok |
|---|---|---|---|
| ETag: instance head-object before the pass | f80959f9556b50d76b3e744afdd3b22a-8860 | f80959f9556b50d76b3e744afdd3b22a-8860 | yes |
| ETag: k2probe -etag, enforced in internal/rangeread as If-Match on every GET plus a check of each response's ETag and Content-Range | f80959f9556b50d76b3e744afdd3b22a-8860 | f80959f9556b50d76b3e744afdd3b22a-8860 | yes |
| ETag: instance head-object after the pass | f80959f9556b50d76b3e744afdd3b22a-8860 | f80959f9556b50d76b3e744afdd3b22a-8860 | yes |
| bytes streamed | 1189091671800 | 1189091671800 | yes |
| complete pass | true | true | yes |
| cells counted == capacity | 297272917942 | 297272917942 | yes |
| occupied (value != 0) == header size | 207831744422 | 207831744422 | yes |
| SHA-256 scope | bytes [0,1189091671800) | bytes [0,1189091671800) | yes |

**tables/hist.tsv**

| lo | hi | observed | theory | residual | rel_residual | z |
|---|---|---|---|---|---|---|
| 1 | 1 | 15444914509 | 1.5446831e+10 | -1916061.4 | -0.00012404237 | -15.41664 |
| 2 | 2 | 8055115074 | 8.051186e+09 | 3929117.9 | 0.00048801728 | 43.78901 |
| 3 | 3 | 4978515537 | 4.9735507e+09 | 4964873.7 | 0.00099825538 | 70.400368 |
| 4 | 4 | 3380168144 | 3.3754043e+09 | 4763832.6 | 0.0014113369 | 81.996174 |
| 5 | 5 | 2436372677 | 2.432092e+09 | 4280669.8 | 0.0017600772 | 86.8004 |
| 6 | 6 | 1830384802 | 1.8265988e+09 | 3786018.3 | 0.0020727148 | 88.58519 |
| 7 | 7 | 1417702783 | 1.4142431e+09 | 3459705.9 | 0.0024463304 | 91.997738 |
| 8 | 8 | 1123728824 | 1.1207814e+09 | 2947374.6 | 0.0026297496 | 88.038952 |
| 9 | 9 | 907216212 | 9.0471142e+08 | 2504788.4 | 0.0027686048 | 83.27526 |
| 10 | 10 | 743384761 | 7.4126493e+08 | 2119827 | 0.0028597427 | 77.859873 |
| 11 | 11 | 616710616 | 6.1487705e+08 | 1833570.3 | 0.0029820114 | 73.944084 |
| 12 | 12 | 516912158 | 5.1534808e+08 | 1564075.1 | 0.0030349877 | 68.898105 |
| 13 | 13 | 437065766 | 4.3575871e+08 | 1307051.8 | 0.0029994853 | 62.613758 |
| 14 | 14 | 372360073 | 3.7127628e+08 | 1083796.3 | 0.00291911 | 56.246961 |
| 15 | 15 | 319349880 | 3.1844068e+08 | 909197.49 | 0.002855155 | 50.949973 |
| 16 | 16 | 275480448 | 2.7472099e+08 | 759458.3 | 0.0027644713 | 45.820309 |
| 17 | 17 | 238875288 | 2.3823107e+08 | 644220.11 | 0.0027041818 | 41.738331 |
| 18 | 18 | 208100272 | 2.0754212e+08 | 558154.97 | 0.0026893576 | 38.743752 |
| 19 | 19 | 181988716 | 1.8155598e+08 | 432734.04 | 0.0023834744 | 32.115581 |
| 20 | 20 | 159756356 | 1.5941767e+08 | 338684.81 | 0.0021245123 | 26.824244 |
| 21 | 21 | 140720508 | 1.4045377e+08 | 266738.97 | 0.0018991229 | 22.507112 |
| 22 | 22 | 124304700 | 1.2412832e+08 | 176381.45 | 0.0014209606 | 15.831333 |
| 23 | 23 | 110144406 | 1.1001072e+08 | 133684.44 | 0.0012151947 | 12.74569 |
| 24 | 24 | 97829870 | 97752049 | 77821.155 | 0.00079610766 | 7.8710874 |
| 25 | 25 | 87112388 | 87067330 | 45057.828 | 0.00051750557 | 4.828838 |
| 26 | 26 | 77720866 | 77722157 | -1291.4912 | -1.661677e-05 | -0.14649373 |
| 27 | 27 | 69487759 | 69522441 | -34681.639 | -0.00049885531 | -4.1594615 |
| 28 | 28 | 62256525 | 62306495 | -49970.203 | -0.00080200633 | -6.3305939 |
| 29 | 29 | 55856838 | 55938875 | -82037.134 | -0.0014665496 | -10.968661 |
| 30 | 30 | 50215685 | 50305524 | -89839.193 | -0.0017858713 | -12.66654 |
| 31 | 31 | 45204406 | 45309934 | -105527.93 | -0.0023290241 | -15.677279 |
| 32 | 32 | 40746776 | 40870077 | -123300.69 | -0.0030168941 | -19.286916 |
| 33 | 33 | 36789877 | 36915941 | -126063.51 | -0.00341488 | -20.748295 |
| 34 | 34 | 33252271 | 33387535 | -135263.83 | -0.0040513273 | -23.409358 |
| 35 | 35 | 30088983 | 30233268 | -144284.58 | -0.0047723779 | -26.240818 |
| 36 | 36 | 27262527 | 27408617 | -146089.78 | -0.0053300677 | -27.904631 |
| 37 | 37 | 24727200 | 24875038 | -147837.61 | -0.0059432115 | -29.641697 |
| 38 | 38 | 22453974 | 22599059 | -145084.52 | -0.0064199364 | -30.519393 |
| 39 | 39 | 20405309 | 20551530 | -146221.3 | -0.0071148619 | -32.254369 |
| 40 | 40 | 18557918 | 18706999 | -149081.36 | -0.0079692825 | -34.468413 |
| 41 | 41 | 16893294 | 17043182 | -149888.48 | -0.00879463 | -36.307214 |
| 42 | 42 | 15390311 | 15540525 | -150213.85 | -0.0096659442 | -38.104575 |
| 43 | 43 | 14038400 | 14181827 | -143426.75 | -0.010113419 | -38.085887 |
| 44 | 44 | 12804642 | 12951927 | -147285.2 | -0.011371682 | -40.925303 |
| 45 | 45 | 11699792 | 11837435 | -137642.74 | -0.011627751 | -40.005944 |
| 46 | 46 | 10689433 | 10826498 | -137064.87 | -0.01266013 | -41.656441 |
| 47 | 47 | 9775071 | 9908608.4 | -133537.39 | -0.013476907 | -42.422529 |
| 48 | 48 | 8939594 | 9074432.7 | -134838.71 | -0.014859189 | -44.761524 |
| 49 | 49 | 8186822 | 8315666.6 | -128844.57 | -0.015494196 | -44.680453 |
| 50 | 50 | 7497009 | 7624909.6 | -127900.6 | -0.016774048 | -46.318578 |
| 51 | 51 | 6873711 | 6995556.9 | -121845.87 | -0.017417608 | -46.068031 |
| 52 | 52 | 6303390 | 6421704.7 | -118314.7 | -0.018424189 | -46.68889 |
| 53 | 53 | 5786003 | 5898068.9 | -112065.85 | -0.019000431 | -46.144334 |
| 54 | 54 | 5310144 | 5419913.1 | -109769.13 | -0.020252932 | -47.150258 |
| 55 | 55 | 4876406 | 4982987.2 | -106581.15 | -0.021389008 | -47.745838 |
| 56 | 56 | 4481459 | 4583471.8 | -102012.75 | -0.022256656 | -47.649374 |
| 57 | 57 | 4118083 | 4217931.3 | -99848.251 | -0.023672328 | -48.617286 |
| 58 | 58 | 3787958 | 3883271.4 | -95313.387 | -0.024544611 | -48.367655 |
| 59 | 59 | 3484564 | 3576702.4 | -92138.393 | -0.02576071 | -48.719097 |
| 60 | 60 | 3204905 | 3295706.4 | -90801.388 | -0.027551419 | -50.017068 |

_60 of 67 rows shown; full table in the file._

**tables/phases.tsv**

| phase | start | seconds | cold |
|---|---|---|---|
| preamble | 2026-10-06T09:15:09Z | 2 | no |
| body | 2026-10-06T09:15:10Z | 0 | no |
| setup | 2026-10-06T09:15:11Z | 25 | no |
| head | 2026-10-06T09:15:36Z | 1 | no |
| pilot | 2026-10-06T09:15:37Z | 28 | no |
| pass | 2026-10-06T09:16:05Z | 721 | no |
| head-after | 2026-10-06T09:28:06Z | 0 | no |
| push | 2026-10-06T09:28:06Z | 2 | no |

**tables/rates.tsv**

| rung | bytes | wall_s | wall_GB_s | sha_busy_GB_s | sha_bench_GB_s | consumer_stall_s | fetch_MB_s_per_stream | scan_GB_s_per_worker | get_requests | get_retries | gomaxprocs | workers | chunk_bytes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| pilot | 34359738368 | 22.1 | 1.552 | 1.66 | 1.752 | 1.4 | 75.3 | 1.259 | 513 | 0 | 8 | 48 | 67108864 |
| pass | 1189091671800 | 720.6 | 1.65 | 1.654 | 0 | 1.4 | 78.9 | 1.264 | 17720 | 0 | 8 | 48 | 67108864 |

**tables/requests.tsv**

| phase | op | count | bucket |
|---|---|---|---|
| preamble | HeadBucket-anon | 1 | kraken2-ncbi-refseq-complete-v205 |
| preamble | GetBucketRequestPayment | 1 | kraken2-ncbi-refseq-complete-v205 |
| preamble | GetBucketRequestPayment | 1 | kraken2-ncbi-refseq-complete-v205 |
| head | HeadObject | 1 | kraken2-ncbi-refseq-complete-v205 |
| pilot | GetObject-range | 513 | kraken2-ncbi-refseq-complete-v205 |
| pass | GetObject-range | 17720 | kraken2-ncbi-refseq-complete-v205 |
| head-after | HeadObject | 1 | kraken2-ncbi-refseq-complete-v205 |

**tables/tails.tsv**

| N | tail_cells | tail_bytes | at_boundary_slot | longest_run |
|---|---|---|---|---|
| 2 | 13 | 52 | 148636458971 | 302 |
| 4 | 13 | 52 | 148636458971 | 302 |
| 8 | 15 | 60 | 37159114742 | 302 |
| 16 | 15 | 60 | 37159114742 | 302 |
| 32 | 19 | 76 | 139346680285 | 302 |
| 64 | 31 | 124 | 60383561456 | 302 |

<details><summary>Files in results/g0c/20261006-091414-1b5fe49</summary>

| file | bytes | sha256 |
|---|---|---|
| completion.json | 386 | `121c51a7e046c3cf` |
| decoded/object.json | 502 | `9ae7fe7c0ba781ac` |
| decoded/pass.json | 1842 | `03c03e2b7d756887` |
| decoded/provenance.json | 173 | `333a5c48121b17ea` |
| decoded/rules.json | 660 | `631237564c9720f0` |
| decoded/theory-tail.json | 360 | `b206b0b362c2bf83` |
| launch.err | 99 | `24508761f81a6d0b` |
| launch.json | 165 | `53c699ffb188d765` |
| log/run.log | 10543 | `c579fb5a9f6b818b` |
| manifest.json | 6661 | `fe5448d7ce561473` |
| out/head-hash.k2d.after.json | 317 | `00588412d0516cf8` |
| out/head-hash.k2d.json | 317 | `00588412d0516cf8` |
| out/pass/boundaries.tsv | 2626 | `e2e4c41c19a985da` |
| out/pass/hist-raw.tsv | 2575 | `8f328058b8b0669a` |
| out/pass/hist.tsv | 4074 | `4fd6a316cfb028dd` |
| out/pass/summary.json | 2225 | `988ea93d29eab2ca` |
| out/pass/tails.tsv | 204 | `5bfc8c7d114923c2` |
| out/pilot/summary.json | 1900 | `efacec5733029dc8` |
| out/requests.tsv | 452 | `9a2f01038f9f401b` |
| payload.sh | 18329 | `3eb304e92aa8e754` |
| preflight.json | 497 | `1c75ebaf7c641c9d` |
| report.md | 18078 | `1dcf17f532cfe749` |
| spawn-plan.txt | 2801 | `bf266a4636d760c9` |
| spawn/ak2-g0c-20261006-091414-1b5fe49/command.log | 11049 | `2eebdd6ebe1ec777` |
| spawn/ak2-g0c-20261006-091414-1b5fe49/completion.json | 386 | `121c51a7e046c3cf` |
| spec.json | 4929 | `83e3585564acf66e` |
| spec.resolved.json | 3653 | `078f28424a92052c` |
| tables/boundaries.tsv | 2626 | `e2e4c41c19a985da` |
| tables/checks.tsv | 748 | `df170c74c964a41b` |
| tables/hist.tsv | 4074 | `4fd6a316cfb028dd` |
| tables/phases.tsv | 289 | `6c982e77aea61619` |
| tables/rates.tsv | 323 | `907d93ed5b1d82d7` |
| tables/requests.tsv | 452 | `9a2f01038f9f401b` |
| tables/tails.tsv | 204 | `5bfc8c7d114923c2` |

</details>

_Rendered by `make report GATE=g0c RUN=20261006-091414-1b5fe49` from `results/g0c/20261006-091414-1b5fe49/` only._
