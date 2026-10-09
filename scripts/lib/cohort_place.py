#!/usr/bin/env python3
"""A cohort manifest's sample placement, as cmd/aws-kraken2/place.go computes it (an independent
implementation: lpt_check.py compares the engine's observed placement with this one).

  cohort_place.py needs N RANK MANIFEST     the runs (sample names after the "<batch>-" prefix)
                                           whose inputs rank RANK reads: its home samples in every
                                           sample-parallel batch, and every sample of a striped
                                           batch (every node reads a striped sample's input)
  cohort_place.py table N MANIFEST         batch, sample, place, weight, home rank (tsv)

Placement: parallel / parallel:mod, sample j of the batch (manifest order) on rank j mod N;
parallel:lpt, heaviest weight first (ties in manifest order) to the rank with the least weight so
far (ties to the lowest rank); striped, every rank.
"""
import collections, sys


def read(man):
    batches = collections.OrderedDict()
    for line in open(man):
        if not line.strip() or line.startswith("#"):
            continue
        f = line.rstrip("\n").split("\t")
        w = int(f[5][len("weight="):]) if len(f) > 5 and f[5].startswith("weight=") else None
        batches.setdefault(f[0], []).append({"name": f[4], "mode": f[2], "weight": w})
    return batches


def place(batches, n):
    """{name: rank or None (striped)}, {name: place}"""
    home, how = {}, {}
    for ss in batches.values():
        mode = ss[0]["mode"]
        if mode == "striped":
            for s in ss:
                home[s["name"]], how[s["name"]] = None, "striped"
            continue
        if mode == "parallel:lpt":
            load = [0] * n
            for j in sorted(range(len(ss)), key=lambda j: (-ss[j]["weight"], j)):
                r = min(range(n), key=lambda k: (load[k], k))
                home[ss[j]["name"]], how[ss[j]["name"]] = r, "lpt"
                load[r] += ss[j]["weight"]
        else:
            for j, s in enumerate(ss):
                home[s["name"]], how[s["name"]] = j % n, "mod"
    return home, how


def run_of(name):
    return name.split("-", 1)[1] if "-" in name else name


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "needs":
        n, rank, man = int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
        home, _ = place(read(man), n)
        need = []
        for name, r in home.items():
            if r is None or r == rank:
                if run_of(name) not in need:
                    need.append(run_of(name))
        print("\n".join(need))
    elif cmd == "table":
        n, man = int(sys.argv[2]), sys.argv[3]
        b = read(man)
        home, how = place(b, n)
        print("batch\tsample\tplace\tweight\thome")
        for k, ss in b.items():
            for s in ss:
                print(f"{k}\t{s['name']}\t{how[s['name']]}\t{s['weight'] if s['weight'] is not None else '-'}\t"
                      f"{home[s['name']] if home[s['name']] is not None else 'all'}")
    else:
        sys.exit(f"usage: {sys.argv[0]} needs N RANK MANIFEST | table N MANIFEST")
