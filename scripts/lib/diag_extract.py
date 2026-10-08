#!/usr/bin/env python3
"""#44: the reads whose --output lines differ between upstream and us, and nothing else.

  diag_extract.py UP.out OURS.out READS_1.fq.gz READS_2.fq.gz OUTDIR

Walks both outputs in lockstep (one line per read pair, in read order) and writes to OUTDIR:
diff.tsv (record index, read id, upstream line, our line), up_sel.txt and ours_sel.txt (those
lines alone, in order), and sel_1.fq / sel_2.fq (those read pairs, verbatim). Prints the count.
Exits 1 if the outputs have different lengths or a record's read ids disagree.
"""
import gzip, os, sys

up, ours, f1, f2, out = sys.argv[1:6]
os.makedirs(out, exist_ok=True)
diff = []
with open(up) as a, open(ours) as b:
    i = 0
    while True:
        la, lb = a.readline(), b.readline()
        if not la and not lb:
            break
        if not la or not lb:
            sys.exit(f"diag_extract: outputs differ in length at record {i}")
        if la != lb:
            ida, idb = la.split("\t")[1], lb.split("\t")[1]
            if ida != idb:
                sys.exit(f"diag_extract: record {i}: read ids {ida} vs {idb}")
            diff.append((i, ida, la.rstrip("\n"), lb.rstrip("\n")))
        i += 1
want = {d[0] for d in diff}
with open(os.path.join(out, "diff.tsv"), "w") as fh:
    fh.write("record\tid\tupstream_line\tour_line\n")
    for d in diff:
        fh.write("\t".join(str(x) for x in d) + "\n")
with open(os.path.join(out, "up_sel.txt"), "w") as fh:
    fh.writelines(d[2] + "\n" for d in diff)
with open(os.path.join(out, "ours_sel.txt"), "w") as fh:
    fh.writelines(d[3] + "\n" for d in diff)
for src, dst in ((f1, "sel_1.fq"), (f2, "sel_2.fq")):
    with gzip.open(src, "rt") as fi, open(os.path.join(out, dst), "w") as fo:
        rec = 0
        while True:
            r = [fi.readline() for _ in range(4)]
            if not r[0]:
                break
            if rec in want:
                fo.writelines(r)
            rec += 1
print(f"diag_extract: {i} records, {len(diff)} differ")
