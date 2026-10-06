# g0b hash equivalence, run 20261006-115110-411d4b4

Upstream pin `2731b35f7abb26ec926517274f3d87e78d42fd76` (`2.17.2-20-g2731b35`); commit `411d4b430c577c80d9041483ed8167b2738dd9bb` (dirty: false). Failed checks: 0.
Raw per-run files are alongside; `manifest.json` has the run metadata.

```
scripts/g0b.sh all  (G0B_DBS="viral standard8" G0B_RUN_ID=20261006-115110-411d4b4)
per db: chash_keys opts.k2d keys 20261005 SRR062634_200000_1.fq SRR062634_200000_2.fq
        (pop = real, subthreshold, random; keys-<pop>.u64)
        chash_dump{,.dh} hash.k2d < keys-<pop>.u64 > up{,.dh}-<pop>.bin
        k2probe equiv-hash -mode linear -load ram|mmap -expect up-<pop>.bin
        k2probe equiv-hash -mode double -expect up.dh-<pop>.bin
        k2probe equiv-hash -mode double -stop=false -expect up-<pop>.bin
synthetic 40-bit: chash_build{,.dh} hash{,.dh}.k2d 1000003 18 22 700000 20261005 keys{,.dh}.u64
        chash_dump{,.dh} hash{,.dh}.k2d < keys{,.dh}.u64 > up{,.dh}.bin
        k2probe equiv-hash -mode linear -load ram|mmap (vs up.bin); -mode double (vs up.dh.bin)

pin 2731b35f7abb26ec926517274f3d87e78d42fd76
pin_describe 2.17.2-20-g2731b35
src /Users/scttfrdmn/src/aws-kraken2/.oracle/src-2731b35f7abb26ec926517274f3d87e78d42fd76 (HEAD 2731b35f7abb26ec926517274f3d87e78d42fd76, no tracked modifications; src sha256 93acd0e6bb4ba8a44fffaf4dc5a076bab08586a5f1a883d835511df6bf5c8ea1)
harness upstream/chash_build.cc sha256 7455ed710411d73c1c23e62373c8139c784b10a13bad27ae257e5d5ce15f8e63
variant lp
cxx /opt/homebrew/bin/g++-16 (g++-16 (Homebrew GCC 16.2.0) 16.2.0)
cxxflags -fopenmp -Wall -std=c++11 -O3 -fPIC -g -DLINEAR_PROBING
ldflags  -lz
archive /Users/scttfrdmn/src/aws-kraken2/.claude/worktrees/agent-a8ce1cfdd59803a40/.oracle/harness/2731b35f7abb26ec926517274f3d87e78d42fd76/lib-lp-d113c84e94b1/libkraken2.a
built 2026-10-06T11:51:51Z Darwin arm64
pin 2731b35f7abb26ec926517274f3d87e78d42fd76
pin_describe 2.17.2-20-g2731b35
src /Users/scttfrdmn/src/aws-kraken2/.oracle/src-2731b35f7abb26ec926517274f3d87e78d42fd76 (HEAD 2731b35f7abb26ec926517274f3d87e78d42fd76, no tracked modifications; src sha256 93acd0e6bb4ba8a44fffaf4dc5a076bab08586a5f1a883d835511df6bf5c8ea1)
harness upstream/chash_build.cc sha256 7455ed710411d73c1c23e62373c8139c784b10a13bad27ae257e5d5ce15f8e63
variant dh
cxx /opt/homebrew/bin/g++-16 (g++-16 (Homebrew GCC 16.2.0) 16.2.0)
cxxflags -fopenmp -Wall -std=c++11 -O3 -fPIC -g
ldflags  -lz
archive /Users/scttfrdmn/src/aws-kraken2/.claude/worktrees/agent-a8ce1cfdd59803a40/.oracle/harness/2731b35f7abb26ec926517274f3d87e78d42fd76/lib-dh-34e0adce6e88/libkraken2.a
built 2026-10-06T11:51:51Z Darwin arm64
pin 2731b35f7abb26ec926517274f3d87e78d42fd76
pin_describe 2.17.2-20-g2731b35
src /Users/scttfrdmn/src/aws-kraken2/.oracle/src-2731b35f7abb26ec926517274f3d87e78d42fd76 (HEAD 2731b35f7abb26ec926517274f3d87e78d42fd76, no tracked modifications; src sha256 93acd0e6bb4ba8a44fffaf4dc5a076bab08586a5f1a883d835511df6bf5c8ea1)
harness upstream/chash_dump.cc sha256 6f47fe701f0491651cfe39bd750c5bdb98a4046bad2f02192e05b34eec50943c
variant lp
cxx /opt/homebrew/bin/g++-16 (g++-16 (Homebrew GCC 16.2.0) 16.2.0)
cxxflags -fopenmp -Wall -std=c++11 -O3 -fPIC -g -DLINEAR_PROBING
ldflags  -lz
archive /Users/scttfrdmn/src/aws-kraken2/.claude/worktrees/agent-a8ce1cfdd59803a40/.oracle/harness/2731b35f7abb26ec926517274f3d87e78d42fd76/lib-lp-d113c84e94b1/libkraken2.a
built 2026-10-06T11:51:50Z Darwin arm64
pin 2731b35f7abb26ec926517274f3d87e78d42fd76
pin_describe 2.17.2-20-g2731b35
src /Users/scttfrdmn/src/aws-kraken2/.oracle/src-2731b35f7abb26ec926517274f3d87e78d42fd76 (HEAD 2731b35f7abb26ec926517274f3d87e78d42fd76, no tracked modifications; src sha256 93acd0e6bb4ba8a44fffaf4dc5a076bab08586a5f1a883d835511df6bf5c8ea1)
harness upstream/chash_dump.cc sha256 6f47fe701f0491651cfe39bd750c5bdb98a4046bad2f02192e05b34eec50943c
variant dh
cxx /opt/homebrew/bin/g++-16 (g++-16 (Homebrew GCC 16.2.0) 16.2.0)
cxxflags -fopenmp -Wall -std=c++11 -O3 -fPIC -g
ldflags  -lz
archive /Users/scttfrdmn/src/aws-kraken2/.claude/worktrees/agent-a8ce1cfdd59803a40/.oracle/harness/2731b35f7abb26ec926517274f3d87e78d42fd76/lib-dh-34e0adce6e88/libkraken2.a
built 2026-10-06T11:51:51Z Darwin arm64
pin 2731b35f7abb26ec926517274f3d87e78d42fd76
pin_describe 2.17.2-20-g2731b35
src /Users/scttfrdmn/src/aws-kraken2/.oracle/src-2731b35f7abb26ec926517274f3d87e78d42fd76 (HEAD 2731b35f7abb26ec926517274f3d87e78d42fd76, no tracked modifications; src sha256 93acd0e6bb4ba8a44fffaf4dc5a076bab08586a5f1a883d835511df6bf5c8ea1)
harness upstream/chash_keys.cc sha256 f4b242fa0ffb26c78e2f93f93445642c0902405cb264bd108d341c7f26197ed0
variant lp
cxx /opt/homebrew/bin/g++-16 (g++-16 (Homebrew GCC 16.2.0) 16.2.0)
cxxflags -fopenmp -Wall -std=c++11 -O3 -fPIC -g -DLINEAR_PROBING
ldflags  -lz
archive /Users/scttfrdmn/src/aws-kraken2/.claude/worktrees/agent-a8ce1cfdd59803a40/.oracle/harness/2731b35f7abb26ec926517274f3d87e78d42fd76/lib-lp-d113c84e94b1/libkraken2.a
built 2026-10-06T11:51:49Z Darwin arm64
```

## standard8

```
source s3://genome-idx/kraken/k2_standard_08_GB_20260626.tar.gz
etag "815577bbfd245c6e337f1bea41fae968-709"
fetched 2026-10-06T01:19:22Z

k=35
l=31
spaced_seed_mask=0x3ffffffff3333333
toggle_mask=0xe37e28c4271b5a2d
minimum_acceptable_hash_value=17113767929583441920
revcom_version=1
records=400000
minimizers=26400000
ambiguous=33762
skipped=24453588
real_keys=1912650
classify_lookups=653333
random_keys=1912650
seed=20261005
```

### upstream-random

```
mode=linear load=ram load_s=0.142 keys=1912650 hits=168 get_ns_per_key=139.1 getbatch_ns_per_key=97.3 
```

### upstream-real

```
mode=linear load=ram load_s=0.176 keys=1912650 hits=1788602 get_ns_per_key=32.4 getbatch_ns_per_key=6.0 
```

### upstream-subthreshold

```
mode=linear load=ram load_s=0.165 keys=24453588 hits=0 get_ns_per_key=29.8 getbatch_ns_per_key=26.1 
```

### upstream.dh-random

```
mode=double load=ram load_s=0.139 keys=1912650 hits=58 get_ns_per_key=114.1 getbatch_ns_per_key=87.8 
```

### upstream.dh-real

```
mode=double load=ram load_s=0.143 keys=1912650 hits=1763653 get_ns_per_key=21.2 getbatch_ns_per_key=7.7 
```

### upstream.dh-subthreshold

```
mode=double load=ram load_s=0.143 keys=24453588 hits=0 get_ns_per_key=30.9 getbatch_ns_per_key=30.1 
```

### go-double-vs-dh-random

```
equiv-hash standard8-random-vs-upstream-dh: mode=double load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 58, go hits 58 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.196 s)
  hits at the home cell: upstream 15, go 15 | past it: upstream 43, go 43
  go load 0.147s, get 0.240s (125.5 ns/key, 1 thread)
  probes upstream hits   n=58 mean=3.224 max=11: 1:15 2:13 3:9 4:8 5:3 6:5 7:2 8:1 9:1 10:0 11:1
  probes upstream misses n=1912592 mean=3.329 max=43: 1:574442 2:401973 3:281818 4:196543 5:137352 6:96167 7:67410 8:47139 9:32872 10:23091 11:16220 12:11213 13:7861 14:5564 15:3905 16:2777 17:1821 18:1321 19:924 20:648 21:453 22:322 23:250 24:147 25:115 26:69 27:56 28:32 29:25 30:21 31:17 32:9 >32:15
  probes go hits         n=58 mean=3.224 max=11: 1:15 2:13 3:9 4:8 5:3 6:5 7:2 8:1 9:1 10:0 11:1
  probes go misses       n=1912592 mean=3.329 max=43: 1:574442 2:401973 3:281818 4:196543 5:137352 6:96167 7:67410 8:47139 9:32872 10:23091 11:16220 12:11213 13:7861 14:5564 15:3905 16:2777 17:1821 18:1321 19:924 20:648 21:453 22:322 23:250 24:147 25:115 26:69 27:56 28:32 29:25 30:21 31:17 32:9 >32:15
```

### go-double-vs-dh-real

```
equiv-hash standard8-real-vs-upstream-dh: mode=double load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 1763653, go hits 1763653 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.030 s)
  hits at the home cell: upstream 1763608, go 1763608 | past it: upstream 45, go 45
  go load 0.140s, get 0.057s (29.7 ns/key, 1 thread)
  probes upstream hits   n=1763653 mean=1.000 max=8: 1:1763608 2:14 3:12 4:9 5:8 6:0 7:0 8:2
  probes upstream misses n=148997 mean=3.481 max=39: 1:37821 2:33272 3:22946 4:16728 5:10958 6:9057 7:5309 8:4007 9:3005 10:1768 11:1157 12:885 13:604 14:429 15:293 16:253 17:168 18:85 19:80 20:46 21:40 22:12 23:15 24:24 25:14 26:10 27:2 28:4 >32:5
  probes go hits         n=1763653 mean=1.000 max=8: 1:1763608 2:14 3:12 4:9 5:8 6:0 7:0 8:2
  probes go misses       n=148997 mean=3.481 max=39: 1:37821 2:33272 3:22946 4:16728 5:10958 6:9057 7:5309 8:4007 9:3005 10:1768 11:1157 12:885 13:604 14:429 15:293 16:253 17:168 18:85 19:80 20:46 21:40 22:12 23:15 24:24 25:14 26:10 27:2 28:4 >32:5
```

### go-double-vs-dh-subthreshold

```
equiv-hash standard8-subthreshold-vs-upstream-dh: mode=double load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 24453588 compared 24453588 | upstream hits 0, go hits 0 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.948 s)
  hits at the home cell: upstream 0, go 0 | past it: upstream 0, go 0
  go load 0.148s, get 1.011s (41.3 ns/key, 1 thread)
  probes upstream hits   n=0 mean=0.000 max=0:
  probes upstream misses n=24453588 mean=3.327 max=43: 1:7350513 2:5136277 3:3604971 4:2511051 5:1753289 6:1237141 7:860402 8:598267 9:422686 10:293929 11:203675 12:145891 13:99813 14:72324 15:48851 16:34902 17:23333 18:16654 19:12556 20:8152 21:5586 22:4117 23:2889 24:1837 25:1308 26:962 27:706 28:421 29:318 30:301 31:143 32:126 >32:197
  probes go hits         n=0 mean=0.000 max=0:
  probes go misses       n=24453588 mean=3.327 max=43: 1:7350513 2:5136277 3:3604971 4:2511051 5:1753289 6:1237141 7:860402 8:598267 9:422686 10:293929 11:203675 12:145891 13:99813 14:72324 15:48851 16:34902 17:23333 18:16654 19:12556 20:8152 21:5586 22:4117 23:2889 24:1837 25:1308 26:962 27:706 28:421 29:318 30:301 31:143 32:126 >32:197
```

### go-double-vs-linear-random

```
equiv-hash standard8-random-double-vs-shipped: mode=double load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 168, go hits 58 | value mismatches 196, probe mismatches 1165551
  GetBatch value mismatches 196 (0.193 s)
  hits at the home cell: upstream 15, go 15 | past it: upstream 153, go 43
  go load 0.140s, get 0.237s (124.1 ns/key, 1 thread)
  probes upstream hits   n=168 mean=11.387 max=100: 1:15 2:15 3:14 4:14 5:5 6:9 7:6 8:12 9:3 10:8 11:9 12:7 13:4 14:8 15:2 16:6 17:5 18:1 19:1 20:4 21:1 22:0 23:1 24:1 25:2 26:0 27:1 28:0 29:1 30:1 31:1 >32:11
  probes upstream misses n=1912482 mean=6.043 max=204: 1:574442 2:289993 3:189338 4:138540 5:106145 6:84079 7:69001 8:57339 9:48074 10:40928 11:35022 12:30106 13:25933 14:22961 15:20270 16:18056 17:15873 18:14054 19:12399 20:11111 21:9977 22:9018 23:8059 24:7085 25:6560 26:5803 27:5363 28:4747 29:4389 30:4041 31:3635 32:3370 >32:36771
  probes go hits         n=58 mean=3.224 max=11: 1:15 2:13 3:9 4:8 5:3 6:5 7:2 8:1 9:1 10:0 11:1
  probes go misses       n=1912592 mean=3.329 max=43: 1:574442 2:401973 3:281818 4:196543 5:137352 6:96167 7:67410 8:47139 9:32872 10:23091 11:16220 12:11213 13:7861 14:5564 15:3905 16:2777 17:1821 18:1321 19:924 20:648 21:453 22:322 23:250 24:147 25:115 26:69 27:56 28:32 29:25 30:21 31:17 32:9 >32:15
```

### go-double-vs-linear-real

```
equiv-hash standard8-real-double-vs-shipped: mode=double load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 1788602, go hits 1763653 | value mismatches 25014, probe mismatches 92969
  GetBatch value mismatches 25014 (0.031 s)
  hits at the home cell: upstream 1763608, go 1763608 | past it: upstream 24994, go 45
  go load 0.138s, get 0.060s (31.6 ns/key, 1 thread)
  probes upstream hits   n=1788602 mean=1.020 max=95: 1:1763608 2:22497 3:635 4:413 5:21 6:27 7:11 8:1313 9:0 10:2 11:1 12:12 13:2 14:1 15:6 16:9 17:6 18:6 19:8 20:0 21:0 22:2 23:0 24:0 25:5 26:5 27:0 28:0 29:1 30:0 31:3 >32:8
  probes upstream misses n=124048 mean=5.935 max=149: 1:37821 2:19270 3:11888 4:8889 5:6874 6:5319 7:4401 8:3823 9:2976 10:2831 11:2199 12:1990 13:1721 14:1526 15:1243 16:1109 17:990 18:821 19:823 20:803 21:717 22:498 23:494 24:455 25:399 26:374 27:284 28:313 29:245 30:214 31:241 32:210 >32:2287
  probes go hits         n=1763653 mean=1.000 max=8: 1:1763608 2:14 3:12 4:9 5:8 6:0 7:0 8:2
  probes go misses       n=148997 mean=3.481 max=39: 1:37821 2:33272 3:22946 4:16728 5:10958 6:9057 7:5309 8:4007 9:3005 10:1768 11:1157 12:885 13:604 14:429 15:293 16:253 17:168 18:85 19:80 20:46 21:40 22:12 23:15 24:24 25:14 26:10 27:2 28:4 >32:5
```

### go-double-vs-linear-subthreshold

```
equiv-hash standard8-subthreshold-double-vs-shipped: mode=double load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 24453588 compared 24453588 | upstream hits 0, go hits 0 | value mismatches 0, probe mismatches 14896191
  GetBatch value mismatches 0 (0.953 s)
  hits at the home cell: upstream 0, go 0 | past it: upstream 0, go 0
  go load 0.144s, get 1.000s (40.9 ns/key, 1 thread)
  probes upstream hits   n=0 mean=0.000 max=0:
  probes upstream misses n=24453588 mean=6.037 max=217: 1:7350513 2:3696470 3:2423661 4:1763310 5:1361106 6:1075239 7:882782 8:738726 9:627753 10:515862 11:446035 12:391594 13:338870 14:293377 15:258021 16:228555 17:197090 18:176190 19:157549 20:141557 21:125032 22:116751 23:103684 24:92544 25:84428 26:75335 27:65815 28:62597 29:54955 30:50608 31:45546 32:42932 >32:469101
  probes go hits         n=0 mean=0.000 max=0:
  probes go misses       n=24453588 mean=3.327 max=43: 1:7350513 2:5136277 3:3604971 4:2511051 5:1753289 6:1237141 7:860402 8:598267 9:422686 10:293929 11:203675 12:145891 13:99813 14:72324 15:48851 16:34902 17:23333 18:16654 19:12556 20:8152 21:5586 22:4117 23:2889 24:1837 25:1308 26:962 27:706 28:421 29:318 30:301 31:143 32:126 >32:197
```

### go-linear-mmap-random

```
equiv-hash standard8-random: mode=linear load=mmap capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 168, go hits 168 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.039 s)
  hits at the home cell: upstream 15, go 15 | past it: upstream 153, go 153
  go load 0.000s, get 0.477s (249.3 ns/key, 1 thread)
  probes upstream hits   n=168 mean=11.387 max=100: 1:15 2:15 3:14 4:14 5:5 6:9 7:6 8:12 9:3 10:8 11:9 12:7 13:4 14:8 15:2 16:6 17:5 18:1 19:1 20:4 21:1 22:0 23:1 24:1 25:2 26:0 27:1 28:0 29:1 30:1 31:1 >32:11
  probes upstream misses n=1912482 mean=6.043 max=204: 1:574442 2:289993 3:189338 4:138540 5:106145 6:84079 7:69001 8:57339 9:48074 10:40928 11:35022 12:30106 13:25933 14:22961 15:20270 16:18056 17:15873 18:14054 19:12399 20:11111 21:9977 22:9018 23:8059 24:7085 25:6560 26:5803 27:5363 28:4747 29:4389 30:4041 31:3635 32:3370 >32:36771
  probes go hits         n=168 mean=11.387 max=100: 1:15 2:15 3:14 4:14 5:5 6:9 7:6 8:12 9:3 10:8 11:9 12:7 13:4 14:8 15:2 16:6 17:5 18:1 19:1 20:4 21:1 22:0 23:1 24:1 25:2 26:0 27:1 28:0 29:1 30:1 31:1 >32:11
  probes go misses       n=1912482 mean=6.043 max=204: 1:574442 2:289993 3:189338 4:138540 5:106145 6:84079 7:69001 8:57339 9:48074 10:40928 11:35022 12:30106 13:25933 14:22961 15:20270 16:18056 17:15873 18:14054 19:12399 20:11111 21:9977 22:9018 23:8059 24:7085 25:6560 26:5803 27:5363 28:4747 29:4389 30:4041 31:3635 32:3370 >32:36771
```

### go-linear-mmap-real

```
equiv-hash standard8-real: mode=linear load=mmap capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 1788602, go hits 1788602 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.014 s)
  hits at the home cell: upstream 1763608, go 1763608 | past it: upstream 24994, go 24994
  go load 0.000s, get 0.214s (111.7 ns/key, 1 thread)
  probes upstream hits   n=1788602 mean=1.020 max=95: 1:1763608 2:22497 3:635 4:413 5:21 6:27 7:11 8:1313 9:0 10:2 11:1 12:12 13:2 14:1 15:6 16:9 17:6 18:6 19:8 20:0 21:0 22:2 23:0 24:0 25:5 26:5 27:0 28:0 29:1 30:0 31:3 >32:8
  probes upstream misses n=124048 mean=5.935 max=149: 1:37821 2:19270 3:11888 4:8889 5:6874 6:5319 7:4401 8:3823 9:2976 10:2831 11:2199 12:1990 13:1721 14:1526 15:1243 16:1109 17:990 18:821 19:823 20:803 21:717 22:498 23:494 24:455 25:399 26:374 27:284 28:313 29:245 30:214 31:241 32:210 >32:2287
  probes go hits         n=1788602 mean=1.020 max=95: 1:1763608 2:22497 3:635 4:413 5:21 6:27 7:11 8:1313 9:0 10:2 11:1 12:12 13:2 14:1 15:6 16:9 17:6 18:6 19:8 20:0 21:0 22:2 23:0 24:0 25:5 26:5 27:0 28:0 29:1 30:0 31:3 >32:8
  probes go misses       n=124048 mean=5.935 max=149: 1:37821 2:19270 3:11888 4:8889 5:6874 6:5319 7:4401 8:3823 9:2976 10:2831 11:2199 12:1990 13:1721 14:1526 15:1243 16:1109 17:990 18:821 19:823 20:803 21:717 22:498 23:494 24:455 25:399 26:374 27:284 28:313 29:245 30:214 31:241 32:210 >32:2287
```

### go-linear-mmap-subthreshold

```
equiv-hash standard8-subthreshold: mode=linear load=mmap capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 24453588 compared 24453588 | upstream hits 0, go hits 0 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.300 s)
  hits at the home cell: upstream 0, go 0 | past it: upstream 0, go 0
  go load 0.000s, get 0.973s (39.8 ns/key, 1 thread)
  probes upstream hits   n=0 mean=0.000 max=0:
  probes upstream misses n=24453588 mean=6.037 max=217: 1:7350513 2:3696470 3:2423661 4:1763310 5:1361106 6:1075239 7:882782 8:738726 9:627753 10:515862 11:446035 12:391594 13:338870 14:293377 15:258021 16:228555 17:197090 18:176190 19:157549 20:141557 21:125032 22:116751 23:103684 24:92544 25:84428 26:75335 27:65815 28:62597 29:54955 30:50608 31:45546 32:42932 >32:469101
  probes go hits         n=0 mean=0.000 max=0:
  probes go misses       n=24453588 mean=6.037 max=217: 1:7350513 2:3696470 3:2423661 4:1763310 5:1361106 6:1075239 7:882782 8:738726 9:627753 10:515862 11:446035 12:391594 13:338870 14:293377 15:258021 16:228555 17:197090 18:176190 19:157549 20:141557 21:125032 22:116751 23:103684 24:92544 25:84428 26:75335 27:65815 28:62597 29:54955 30:50608 31:45546 32:42932 >32:469101
```

### go-linear-ram-random

```
equiv-hash standard8-random: mode=linear load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 168, go hits 168 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.041 s)
  hits at the home cell: upstream 15, go 15 | past it: upstream 153, go 153
  go load 0.145s, get 0.265s (138.6 ns/key, 1 thread)
  probes upstream hits   n=168 mean=11.387 max=100: 1:15 2:15 3:14 4:14 5:5 6:9 7:6 8:12 9:3 10:8 11:9 12:7 13:4 14:8 15:2 16:6 17:5 18:1 19:1 20:4 21:1 22:0 23:1 24:1 25:2 26:0 27:1 28:0 29:1 30:1 31:1 >32:11
  probes upstream misses n=1912482 mean=6.043 max=204: 1:574442 2:289993 3:189338 4:138540 5:106145 6:84079 7:69001 8:57339 9:48074 10:40928 11:35022 12:30106 13:25933 14:22961 15:20270 16:18056 17:15873 18:14054 19:12399 20:11111 21:9977 22:9018 23:8059 24:7085 25:6560 26:5803 27:5363 28:4747 29:4389 30:4041 31:3635 32:3370 >32:36771
  probes go hits         n=168 mean=11.387 max=100: 1:15 2:15 3:14 4:14 5:5 6:9 7:6 8:12 9:3 10:8 11:9 12:7 13:4 14:8 15:2 16:6 17:5 18:1 19:1 20:4 21:1 22:0 23:1 24:1 25:2 26:0 27:1 28:0 29:1 30:1 31:1 >32:11
  probes go misses       n=1912482 mean=6.043 max=204: 1:574442 2:289993 3:189338 4:138540 5:106145 6:84079 7:69001 8:57339 9:48074 10:40928 11:35022 12:30106 13:25933 14:22961 15:20270 16:18056 17:15873 18:14054 19:12399 20:11111 21:9977 22:9018 23:8059 24:7085 25:6560 26:5803 27:5363 28:4747 29:4389 30:4041 31:3635 32:3370 >32:36771
```

### go-linear-ram-real

```
equiv-hash standard8-real: mode=linear load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 1912650 compared 1912650 | upstream hits 1788602, go hits 1788602 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.013 s)
  hits at the home cell: upstream 1763608, go 1763608 | past it: upstream 24994, go 24994
  go load 0.141s, get 0.050s (26.2 ns/key, 1 thread)
  probes upstream hits   n=1788602 mean=1.020 max=95: 1:1763608 2:22497 3:635 4:413 5:21 6:27 7:11 8:1313 9:0 10:2 11:1 12:12 13:2 14:1 15:6 16:9 17:6 18:6 19:8 20:0 21:0 22:2 23:0 24:0 25:5 26:5 27:0 28:0 29:1 30:0 31:3 >32:8
  probes upstream misses n=124048 mean=5.935 max=149: 1:37821 2:19270 3:11888 4:8889 5:6874 6:5319 7:4401 8:3823 9:2976 10:2831 11:2199 12:1990 13:1721 14:1526 15:1243 16:1109 17:990 18:821 19:823 20:803 21:717 22:498 23:494 24:455 25:399 26:374 27:284 28:313 29:245 30:214 31:241 32:210 >32:2287
  probes go hits         n=1788602 mean=1.020 max=95: 1:1763608 2:22497 3:635 4:413 5:21 6:27 7:11 8:1313 9:0 10:2 11:1 12:12 13:2 14:1 15:6 16:9 17:6 18:6 19:8 20:0 21:0 22:2 23:0 24:0 25:5 26:5 27:0 28:0 29:1 30:0 31:3 >32:8
  probes go misses       n=124048 mean=5.935 max=149: 1:37821 2:19270 3:11888 4:8889 5:6874 6:5319 7:4401 8:3823 9:2976 10:2831 11:2199 12:1990 13:1721 14:1526 15:1243 16:1109 17:990 18:821 19:823 20:803 21:717 22:498 23:494 24:455 25:399 26:374 27:284 28:313 29:245 30:214 31:241 32:210 >32:2287
```

### go-linear-ram-subthreshold

```
equiv-hash standard8-subthreshold: mode=linear load=ram capacity=2000000000 size=1399434069 key_bits=16 value_bits=16 cell_bytes=4
  keys 24453588 compared 24453588 | upstream hits 0, go hits 0 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.311 s)
  hits at the home cell: upstream 0, go 0 | past it: upstream 0, go 0
  go load 0.152s, get 0.771s (31.5 ns/key, 1 thread)
  probes upstream hits   n=0 mean=0.000 max=0:
  probes upstream misses n=24453588 mean=6.037 max=217: 1:7350513 2:3696470 3:2423661 4:1763310 5:1361106 6:1075239 7:882782 8:738726 9:627753 10:515862 11:446035 12:391594 13:338870 14:293377 15:258021 16:228555 17:197090 18:176190 19:157549 20:141557 21:125032 22:116751 23:103684 24:92544 25:84428 26:75335 27:65815 28:62597 29:54955 30:50608 31:45546 32:42932 >32:469101
  probes go hits         n=0 mean=0.000 max=0:
  probes go misses       n=24453588 mean=6.037 max=217: 1:7350513 2:3696470 3:2423661 4:1763310 5:1361106 6:1075239 7:882782 8:738726 9:627753 10:515862 11:446035 12:391594 13:338870 14:293377 15:258021 16:228555 17:197090 18:176190 19:157549 20:141557 21:125032 22:116751 23:103684 24:92544 25:84428 26:75335 27:65815 28:62597 29:54955 30:50608 31:45546 32:42932 >32:469101
```

## synthetic40 (synthetic table built by upstream; cell-format port check)

```
capacity=1000003
size=700000
key_bits=18
value_bits=22
cell_bytes=5
keys=1400000
seed=20261005
```

### go-double-vs-dh

```
equiv-hash synthetic40-double-vs-dh: mode=double load=ram capacity=1000003 size=699998 key_bits=18 value_bits=22 cell_bytes=5
  keys 1400000 compared 1400000 | upstream hits 700007, go hits 700007 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.038 s)
  hits at the home cell: upstream 454493, go 454493 | past it: upstream 245514, go 245514
  go load 0.000s, get 0.038s (27.5 ns/key, 1 thread)
  probes upstream hits   n=700007 mean=1.721 max=26: 1:454493 2:130965 3:54627 4:26372 5:13881 6:7850 7:4543 8:2785 9:1648 10:1003 11:677 12:411 13:264 14:170 15:112 16:63 17:53 18:34 19:16 20:16 21:11 22:5 23:3 24:3 25:1 26:1
  probes upstream misses n=699993 mean=3.328 max=40: 1:210413 2:146750 3:103191 4:71907 5:50415 6:35530 7:24363 8:17216 9:12241 10:8402 11:5826 12:4156 13:2915 14:1997 15:1388 16:989 17:660 18:479 19:322 20:269 21:160 22:118 23:89 24:71 25:40 26:22 27:26 28:12 29:8 30:5 31:6 32:2 >32:5
  probes go hits         n=700007 mean=1.721 max=26: 1:454493 2:130965 3:54627 4:26372 5:13881 6:7850 7:4543 8:2785 9:1648 10:1003 11:677 12:411 13:264 14:170 15:112 16:63 17:53 18:34 19:16 20:16 21:11 22:5 23:3 24:3 25:1 26:1
  probes go misses       n=699993 mean=3.328 max=40: 1:210413 2:146750 3:103191 4:71907 5:50415 6:35530 7:24363 8:17216 9:12241 10:8402 11:5826 12:4156 13:2915 14:1997 15:1388 16:989 17:660 18:479 19:322 20:269 21:160 22:118 23:89 24:71 25:40 26:22 27:26 28:12 29:8 30:5 31:6 32:2 >32:5
```

### go-linear-mmap

```
equiv-hash synthetic40-linear-mmap: mode=linear load=mmap capacity=1000003 size=700000 key_bits=18 value_bits=22 cell_bytes=5
  keys 1400000 compared 1400000 | upstream hits 700013, go hits 700013 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.042 s)
  hits at the home cell: upstream 454544, go 454544 | past it: upstream 245469, go 245469
  go load 0.000s, get 0.043s (30.6 ns/key, 1 thread)
  probes upstream hits   n=700013 mean=2.170 max=127: 1:454544 2:107583 3:46892 4:26185 5:16262 6:10992 7:7739 8:5893 9:4304 10:3342 11:2635 12:2084 13:1756 14:1405 15:1157 16:1047 17:838 18:694 19:556 20:515 21:429 22:363 23:326 24:281 25:238 26:223 27:211 28:159 29:150 30:133 31:93 32:92 >32:892
  probes upstream misses n=699987 mean=6.064 max=136: 1:210158 2:105956 3:69413 4:50246 5:38455 6:30768 7:25277 8:20838 9:17798 10:14976 11:12876 12:11248 13:9559 14:8441 15:7471 16:6582 17:5786 18:5189 19:4651 20:4129 21:3691 22:3287 23:2909 24:2662 25:2530 26:2169 27:2001 28:1786 29:1625 30:1440 31:1406 32:1207 >32:13457
  probes go hits         n=700013 mean=2.170 max=127: 1:454544 2:107583 3:46892 4:26185 5:16262 6:10992 7:7739 8:5893 9:4304 10:3342 11:2635 12:2084 13:1756 14:1405 15:1157 16:1047 17:838 18:694 19:556 20:515 21:429 22:363 23:326 24:281 25:238 26:223 27:211 28:159 29:150 30:133 31:93 32:92 >32:892
  probes go misses       n=699987 mean=6.064 max=136: 1:210158 2:105956 3:69413 4:50246 5:38455 6:30768 7:25277 8:20838 9:17798 10:14976 11:12876 12:11248 13:9559 14:8441 15:7471 16:6582 17:5786 18:5189 19:4651 20:4129 21:3691 22:3287 23:2909 24:2662 25:2530 26:2169 27:2001 28:1786 29:1625 30:1440 31:1406 32:1207 >32:13457
```

### go-linear-ram

```
equiv-hash synthetic40-linear-ram: mode=linear load=ram capacity=1000003 size=700000 key_bits=18 value_bits=22 cell_bytes=5
  keys 1400000 compared 1400000 | upstream hits 700013, go hits 700013 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.042 s)
  hits at the home cell: upstream 454544, go 454544 | past it: upstream 245469, go 245469
  go load 0.000s, get 0.043s (30.4 ns/key, 1 thread)
  probes upstream hits   n=700013 mean=2.170 max=127: 1:454544 2:107583 3:46892 4:26185 5:16262 6:10992 7:7739 8:5893 9:4304 10:3342 11:2635 12:2084 13:1756 14:1405 15:1157 16:1047 17:838 18:694 19:556 20:515 21:429 22:363 23:326 24:281 25:238 26:223 27:211 28:159 29:150 30:133 31:93 32:92 >32:892
  probes upstream misses n=699987 mean=6.064 max=136: 1:210158 2:105956 3:69413 4:50246 5:38455 6:30768 7:25277 8:20838 9:17798 10:14976 11:12876 12:11248 13:9559 14:8441 15:7471 16:6582 17:5786 18:5189 19:4651 20:4129 21:3691 22:3287 23:2909 24:2662 25:2530 26:2169 27:2001 28:1786 29:1625 30:1440 31:1406 32:1207 >32:13457
  probes go hits         n=700013 mean=2.170 max=127: 1:454544 2:107583 3:46892 4:26185 5:16262 6:10992 7:7739 8:5893 9:4304 10:3342 11:2635 12:2084 13:1756 14:1405 15:1157 16:1047 17:838 18:694 19:556 20:515 21:429 22:363 23:326 24:281 25:238 26:223 27:211 28:159 29:150 30:133 31:93 32:92 >32:892
  probes go misses       n=699987 mean=6.064 max=136: 1:210158 2:105956 3:69413 4:50246 5:38455 6:30768 7:25277 8:20838 9:17798 10:14976 11:12876 12:11248 13:9559 14:8441 15:7471 16:6582 17:5786 18:5189 19:4651 20:4129 21:3691 22:3287 23:2909 24:2662 25:2530 26:2169 27:2001 28:1786 29:1625 30:1440 31:1406 32:1207 >32:13457
```

## viral

```
source s3://genome-idx/kraken/k2_viral_20260626.tar.gz
etag "df6f9dd95095a9ea2e0cfc580b0f684a-69"
fetched 2026-10-06T00:17:31Z

k=35
l=31
spaced_seed_mask=0x3ffffffff3333333
toggle_mask=0xe37e28c4271b5a2d
minimum_acceptable_hash_value=0
revcom_version=1
records=400000
minimizers=26400000
ambiguous=33762
skipped=0
real_keys=26366238
classify_lookups=9016552
random_keys=26366238
seed=20261005
```

### upstream-random

```
mode=linear load=ram load_s=0.012 keys=26366238 hits=1050 get_ns_per_key=99.2 getbatch_ns_per_key=90.9 
```

### upstream-real

```
mode=linear load=ram load_s=0.012 keys=26366238 hits=38819 get_ns_per_key=24.5 getbatch_ns_per_key=25.3 
```

### upstream.dh-random

```
mode=double load=ram load_s=0.012 keys=26366238 hits=464 get_ns_per_key=78.7 getbatch_ns_per_key=75.1 
```

### upstream.dh-real

```
mode=double load=ram load_s=0.013 keys=26366238 hits=28188 get_ns_per_key=26.2 getbatch_ns_per_key=27.2 
```

### go-double-vs-dh-random

```
equiv-hash viral-random-vs-upstream-dh: mode=double load=ram capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 464, go hits 464 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (2.310 s)
  hits at the home cell: upstream 130, go 130 | past it: upstream 334, go 334
  go load 0.012s, get 2.276s (86.3 ns/key, 1 thread)
  probes upstream hits   n=464 mean=3.504 max=17: 1:130 2:96 3:69 4:40 5:31 6:29 7:25 8:14 9:9 10:9 11:3 12:6 13:0 14:2 15:0 16:0 17:1
  probes upstream misses n=26365774 mean=3.342 max=49: 1:7886635 2:5527563 3:3875453 4:2715865 5:1903474 6:1334137 7:933692 8:655265 9:460203 10:321126 11:225167 12:158394 13:110868 14:77518 15:53971 16:37700 17:26438 18:18604 19:13159 20:9070 21:6477 22:4535 23:3078 24:2208 25:1532 26:1084 27:775 28:552 29:373 30:257 31:186 32:106 >32:309
  probes go hits         n=464 mean=3.504 max=17: 1:130 2:96 3:69 4:40 5:31 6:29 7:25 8:14 9:9 10:9 11:3 12:6 13:0 14:2 15:0 16:0 17:1
  probes go misses       n=26365774 mean=3.342 max=49: 1:7886635 2:5527563 3:3875453 4:2715865 5:1903474 6:1334137 7:933692 8:655265 9:460203 10:321126 11:225167 12:158394 13:110868 14:77518 15:53971 16:37700 17:26438 18:18604 19:13159 20:9070 21:6477 22:4535 23:3078 24:2208 25:1532 26:1084 27:775 28:552 29:373 30:257 31:186 32:106 >32:309
```

### go-double-vs-dh-real

```
equiv-hash viral-real-vs-upstream-dh: mode=double load=ram capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 28188, go hits 28188 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.940 s)
  hits at the home cell: upstream 27892, go 27892 | past it: upstream 296, go 296
  go load 0.012s, get 0.928s (35.2 ns/key, 1 thread)
  probes upstream hits   n=28188 mean=1.036 max=14: 1:27892 2:90 3:71 4:32 5:27 6:25 7:8 8:14 9:5 10:3 11:7 12:5 13:4 14:5
  probes upstream misses n=26338050 mean=3.348 max=41: 1:7870468 2:5512410 3:3860745 4:2708150 5:1916710 6:1340148 7:931791 8:649856 9:465889 10:322973 11:229621 12:158130 13:111216 14:77738 15:54567 16:39112 17:26971 18:17976 19:13686 20:8730 21:6433 22:4144 23:3378 24:1996 25:1557 26:1065 27:796 28:457 29:487 30:329 31:160 32:123 >32:238
  probes go hits         n=28188 mean=1.036 max=14: 1:27892 2:90 3:71 4:32 5:27 6:25 7:8 8:14 9:5 10:3 11:7 12:5 13:4 14:5
  probes go misses       n=26338050 mean=3.348 max=41: 1:7870468 2:5512410 3:3860745 4:2708150 5:1916710 6:1340148 7:931791 8:649856 9:465889 10:322973 11:229621 12:158130 13:111216 14:77738 15:54567 16:39112 17:26971 18:17976 19:13686 20:8730 21:6433 22:4144 23:3378 24:1996 25:1557 26:1065 27:796 28:457 29:487 30:329 31:160 32:123 >32:238
```

### go-double-vs-linear-random

```
equiv-hash viral-random-double-vs-shipped: mode=double load=ram capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 1050, go hits 464 | value mismatches 1254, probe mismatches 16111627
  GetBatch value mismatches 1254 (2.305 s)
  hits at the home cell: upstream 130, go 130 | past it: upstream 920, go 334
  go load 0.012s, get 2.311s (87.7 ns/key, 1 thread)
  probes upstream hits   n=1050 mean=9.983 max=100: 1:130 2:126 3:90 4:69 5:70 6:65 7:56 8:44 9:32 10:41 11:26 12:29 13:31 14:15 15:23 16:17 17:11 18:11 19:16 20:13 21:10 22:4 23:5 24:9 25:11 26:14 27:6 28:10 29:1 30:4 31:4 32:2 >32:55
  probes upstream misses n=26365188 mean=6.077 max=188: 1:7886635 2:3977405 3:2615357 4:1903501 5:1465310 6:1166983 7:952178 8:790262 9:666858 10:565113 11:484423 12:419965 13:364728 14:317848 15:280561 16:247160 17:219351 18:194641 19:173863 20:155133 21:138270 22:124581 23:111555 24:100752 25:91273 26:82310 27:74359 28:67695 29:61147 30:55637 31:50163 32:46034 >32:514137
  probes go hits         n=464 mean=3.504 max=17: 1:130 2:96 3:69 4:40 5:31 6:29 7:25 8:14 9:9 10:9 11:3 12:6 13:0 14:2 15:0 16:0 17:1
  probes go misses       n=26365774 mean=3.342 max=49: 1:7886635 2:5527563 3:3875453 4:2715865 5:1903474 6:1334137 7:933692 8:655265 9:460203 10:321126 11:225167 12:158394 13:110868 14:77518 15:53971 16:37700 17:26438 18:18604 19:13159 20:9070 21:6477 22:4535 23:3078 24:2208 25:1532 26:1084 27:775 28:552 29:373 30:257 31:186 32:106 >32:309
```

### go-double-vs-linear-real

```
equiv-hash viral-real-double-vs-shipped: mode=double load=ram capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 38819, go hits 28188 | value mismatches 11223, probe mismatches 16095055
  GetBatch value mismatches 11223 (0.940 s)
  hits at the home cell: upstream 27892, go 27892 | past it: upstream 10927, go 296
  go load 0.012s, get 0.929s (35.2 ns/key, 1 thread)
  probes upstream hits   n=38819 mean=1.805 max=58: 1:27892 2:5732 3:2038 4:1170 5:134 6:1022 7:55 8:85 9:187 10:26 11:26 12:87 13:9 14:32 15:39 16:13 17:8 18:6 19:13 20:2 21:7 22:18 23:120 24:10 25:8 26:10 27:0 28:0 29:3 30:5 31:1 32:3 >32:58
  probes upstream misses n=26327419 mean=6.094 max=202: 1:7870468 2:3960546 3:2610260 4:1903723 5:1466466 6:1164129 7:962134 8:781957 9:662508 10:568392 11:481877 12:421481 13:361733 14:318088 15:277960 16:248836 17:220823 18:192537 19:168572 20:152568 21:140455 22:125662 23:117301 24:100294 25:90474 26:81310 27:76347 28:67010 29:62929 30:54872 31:49617 32:45646 >32:520444
  probes go hits         n=28188 mean=1.036 max=14: 1:27892 2:90 3:71 4:32 5:27 6:25 7:8 8:14 9:5 10:3 11:7 12:5 13:4 14:5
  probes go misses       n=26338050 mean=3.348 max=41: 1:7870468 2:5512410 3:3860745 4:2708150 5:1916710 6:1340148 7:931791 8:649856 9:465889 10:322973 11:229621 12:158130 13:111216 14:77738 15:54567 16:39112 17:26971 18:17976 19:13686 20:8730 21:6433 22:4144 23:3378 24:1996 25:1557 26:1065 27:796 28:457 29:487 30:329 31:160 32:123 >32:238
```

### go-linear-mmap-random

```
equiv-hash viral-random: mode=linear load=mmap capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 1050, go hits 1050 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.546 s)
  hits at the home cell: upstream 130, go 130 | past it: upstream 920, go 920
  go load 0.000s, get 2.677s (101.5 ns/key, 1 thread)
  probes upstream hits   n=1050 mean=9.983 max=100: 1:130 2:126 3:90 4:69 5:70 6:65 7:56 8:44 9:32 10:41 11:26 12:29 13:31 14:15 15:23 16:17 17:11 18:11 19:16 20:13 21:10 22:4 23:5 24:9 25:11 26:14 27:6 28:10 29:1 30:4 31:4 32:2 >32:55
  probes upstream misses n=26365188 mean=6.077 max=188: 1:7886635 2:3977405 3:2615357 4:1903501 5:1465310 6:1166983 7:952178 8:790262 9:666858 10:565113 11:484423 12:419965 13:364728 14:317848 15:280561 16:247160 17:219351 18:194641 19:173863 20:155133 21:138270 22:124581 23:111555 24:100752 25:91273 26:82310 27:74359 28:67695 29:61147 30:55637 31:50163 32:46034 >32:514137
  probes go hits         n=1050 mean=9.983 max=100: 1:130 2:126 3:90 4:69 5:70 6:65 7:56 8:44 9:32 10:41 11:26 12:29 13:31 14:15 15:23 16:17 17:11 18:11 19:16 20:13 21:10 22:4 23:5 24:9 25:11 26:14 27:6 28:10 29:1 30:4 31:4 32:2 >32:55
  probes go misses       n=26365188 mean=6.077 max=188: 1:7886635 2:3977405 3:2615357 4:1903501 5:1465310 6:1166983 7:952178 8:790262 9:666858 10:565113 11:484423 12:419965 13:364728 14:317848 15:280561 16:247160 17:219351 18:194641 19:173863 20:155133 21:138270 22:124581 23:111555 24:100752 25:91273 26:82310 27:74359 28:67695 29:61147 30:55637 31:50163 32:46034 >32:514137
```

### go-linear-mmap-real

```
equiv-hash viral-real: mode=linear load=mmap capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 38819, go hits 38819 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.309 s)
  hits at the home cell: upstream 27892, go 27892 | past it: upstream 10927, go 10927
  go load 0.000s, get 0.720s (27.3 ns/key, 1 thread)
  probes upstream hits   n=38819 mean=1.805 max=58: 1:27892 2:5732 3:2038 4:1170 5:134 6:1022 7:55 8:85 9:187 10:26 11:26 12:87 13:9 14:32 15:39 16:13 17:8 18:6 19:13 20:2 21:7 22:18 23:120 24:10 25:8 26:10 27:0 28:0 29:3 30:5 31:1 32:3 >32:58
  probes upstream misses n=26327419 mean=6.094 max=202: 1:7870468 2:3960546 3:2610260 4:1903723 5:1466466 6:1164129 7:962134 8:781957 9:662508 10:568392 11:481877 12:421481 13:361733 14:318088 15:277960 16:248836 17:220823 18:192537 19:168572 20:152568 21:140455 22:125662 23:117301 24:100294 25:90474 26:81310 27:76347 28:67010 29:62929 30:54872 31:49617 32:45646 >32:520444
  probes go hits         n=38819 mean=1.805 max=58: 1:27892 2:5732 3:2038 4:1170 5:134 6:1022 7:55 8:85 9:187 10:26 11:26 12:87 13:9 14:32 15:39 16:13 17:8 18:6 19:13 20:2 21:7 22:18 23:120 24:10 25:8 26:10 27:0 28:0 29:3 30:5 31:1 32:3 >32:58
  probes go misses       n=26327419 mean=6.094 max=202: 1:7870468 2:3960546 3:2610260 4:1903723 5:1466466 6:1164129 7:962134 8:781957 9:662508 10:568392 11:481877 12:421481 13:361733 14:318088 15:277960 16:248836 17:220823 18:192537 19:168572 20:152568 21:140455 22:125662 23:117301 24:100294 25:90474 26:81310 27:76347 28:67010 29:62929 30:54872 31:49617 32:45646 >32:520444
```

### go-linear-ram-random

```
equiv-hash viral-random: mode=linear load=ram capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 1050, go hits 1050 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.528 s)
  hits at the home cell: upstream 130, go 130 | past it: upstream 920, go 920
  go load 0.013s, get 2.699s (102.4 ns/key, 1 thread)
  probes upstream hits   n=1050 mean=9.983 max=100: 1:130 2:126 3:90 4:69 5:70 6:65 7:56 8:44 9:32 10:41 11:26 12:29 13:31 14:15 15:23 16:17 17:11 18:11 19:16 20:13 21:10 22:4 23:5 24:9 25:11 26:14 27:6 28:10 29:1 30:4 31:4 32:2 >32:55
  probes upstream misses n=26365188 mean=6.077 max=188: 1:7886635 2:3977405 3:2615357 4:1903501 5:1465310 6:1166983 7:952178 8:790262 9:666858 10:565113 11:484423 12:419965 13:364728 14:317848 15:280561 16:247160 17:219351 18:194641 19:173863 20:155133 21:138270 22:124581 23:111555 24:100752 25:91273 26:82310 27:74359 28:67695 29:61147 30:55637 31:50163 32:46034 >32:514137
  probes go hits         n=1050 mean=9.983 max=100: 1:130 2:126 3:90 4:69 5:70 6:65 7:56 8:44 9:32 10:41 11:26 12:29 13:31 14:15 15:23 16:17 17:11 18:11 19:16 20:13 21:10 22:4 23:5 24:9 25:11 26:14 27:6 28:10 29:1 30:4 31:4 32:2 >32:55
  probes go misses       n=26365188 mean=6.077 max=188: 1:7886635 2:3977405 3:2615357 4:1903501 5:1465310 6:1166983 7:952178 8:790262 9:666858 10:565113 11:484423 12:419965 13:364728 14:317848 15:280561 16:247160 17:219351 18:194641 19:173863 20:155133 21:138270 22:124581 23:111555 24:100752 25:91273 26:82310 27:74359 28:67695 29:61147 30:55637 31:50163 32:46034 >32:514137
```

### go-linear-ram-real

```
equiv-hash viral-real: mode=linear load=ram capacity=162183314 size=113651066 key_bits=17 value_bits=15 cell_bytes=4
  keys 26366238 compared 26366238 | upstream hits 38819, go hits 38819 | value mismatches 0, probe mismatches 0
  GetBatch value mismatches 0 (0.314 s)
  hits at the home cell: upstream 27892, go 27892 | past it: upstream 10927, go 10927
  go load 0.012s, get 0.696s (26.4 ns/key, 1 thread)
  probes upstream hits   n=38819 mean=1.805 max=58: 1:27892 2:5732 3:2038 4:1170 5:134 6:1022 7:55 8:85 9:187 10:26 11:26 12:87 13:9 14:32 15:39 16:13 17:8 18:6 19:13 20:2 21:7 22:18 23:120 24:10 25:8 26:10 27:0 28:0 29:3 30:5 31:1 32:3 >32:58
  probes upstream misses n=26327419 mean=6.094 max=202: 1:7870468 2:3960546 3:2610260 4:1903723 5:1466466 6:1164129 7:962134 8:781957 9:662508 10:568392 11:481877 12:421481 13:361733 14:318088 15:277960 16:248836 17:220823 18:192537 19:168572 20:152568 21:140455 22:125662 23:117301 24:100294 25:90474 26:81310 27:76347 28:67010 29:62929 30:54872 31:49617 32:45646 >32:520444
  probes go hits         n=38819 mean=1.805 max=58: 1:27892 2:5732 3:2038 4:1170 5:134 6:1022 7:55 8:85 9:187 10:26 11:26 12:87 13:9 14:32 15:39 16:13 17:8 18:6 19:13 20:2 21:7 22:18 23:120 24:10 25:8 26:10 27:0 28:0 29:3 30:5 31:1 32:3 >32:58
  probes go misses       n=26327419 mean=6.094 max=202: 1:7870468 2:3960546 3:2610260 4:1903723 5:1466466 6:1164129 7:962134 8:781957 9:662508 10:568392 11:481877 12:421481 13:361733 14:318088 15:277960 16:248836 17:220823 18:192537 19:168572 20:152568 21:140455 22:125662 23:117301 24:100294 25:90474 26:81310 27:76347 28:67010 29:62929 30:54872 31:49617 32:45646 >32:520444
```
