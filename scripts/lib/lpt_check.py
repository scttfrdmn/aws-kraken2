#!/usr/bin/env python3
"""Check observed cohort placement against the placement the manifest asks for.

  lpt_check.py N MANIFEST LOG...

Recomputes each sample-parallel batch's placement from MANIFEST (cmd/aws-kraken2/place.go,
independently: parallel:lpt is largest weight first, ties in manifest order, to the node with the
least weight so far, ties to the lowest rank; parallel / parallel:mod is j mod N) and compares it
with the home rank of every ak2-sample line found in the LOGs (stderr files or run logs; a line
may carry a prefix such as "[c10] "). Prints one line per batch and exits 1 if any sample's
observed rank differs, any sample of a parallel batch has no home line, or a line's place field
differs from the manifest's.
"""
import collections, sys

n = int(sys.argv[1])
man, logs = sys.argv[2], sys.argv[3:]
batches = collections.OrderedDict()
for line in open(man):
    if not line.strip() or line.startswith("#"):
        continue
    f = line.rstrip("\n").split("\t")
    b, mode, name = f[0], f[2], f[4]
    w = int(f[5][len("weight="):]) if len(f) > 5 and f[5].startswith("weight=") else None
    batches.setdefault(b, []).append((name, mode, w))

want, place_of = {}, {}
for b, ss in batches.items():
    mode = ss[0][1]
    if mode == "striped":
        continue
    place = "lpt" if mode == "parallel:lpt" else "mod"
    if place == "lpt":
        order = sorted(range(len(ss)), key=lambda j: (-ss[j][2], j))
        load = [0] * n
        for j in order:
            r = min(range(n), key=lambda k: (load[k], k))
            want[ss[j][0]] = r
            load[r] += ss[j][2]
    else:
        for j, s in enumerate(ss):
            want[s[0]] = j % n
    for s in ss:
        place_of[s[0]] = place

got, gplace = {}, {}
for p in logs:
    for line in open(p, errors="replace"):
        i = line.find("ak2-sample\t")
        if i < 0:
            continue
        f = line[i:].rstrip("\n").split("\t")[1:]
        kv = dict(zip(f[0::2], f[1::2]))
        if kv.get("role") == "home":
            got[kv["name"]] = int(kv["rank"])
            gplace[kv["name"]] = kv.get("place")  # None: a line from before the place field

bad = 0
for b, ss in batches.items():
    names = [s[0] for s in ss if s[0] in want]
    if not names:
        continue
    wrong = [s for s in names if got.get(s) != want[s] or gplace.get(s) not in (place_of[s], None)]
    bad += len(wrong)
    loads = collections.Counter()
    for s, _, w in ss:
        if s in got and w is not None:
            loads[got[s]] += w
    imb = (max(loads.values()) / (sum(loads.values()) / n)) if loads and sum(loads.values()) else 0
    print(f"lpt_check: batch {b} ({place_of[names[0]]}): {len(names) - len(wrong)} of {len(names)} samples on the expected rank"
          + (f"; weight imbalance max/mean {imb:.2f}" if loads else "")
          + (f"; differs from j mod N: {'yes' if any(want[s[0]] != j % n for j, s in enumerate(ss)) else 'no'}"
             if place_of[names[0]] == "lpt" else "")
          + (f"; WRONG: {', '.join(f'{s} rank {got.get(s)} want {want[s]} place {gplace.get(s)}' for s in wrong[:5])}" if wrong else ""))
sys.exit(1 if bad else 0)
