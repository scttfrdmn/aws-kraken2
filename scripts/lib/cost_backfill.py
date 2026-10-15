#!/usr/bin/env python3
"""make cost-backfill DIRS="results/g3/<cohort> ..." [WRITE=1] (docs/run.md, "Cost").

Fills a member's cost_usd that run.sh left null because the truffle price lookup at launch gave
none (the AWS Pricing API throttles a cohort's members; c10 stage 5, conductor
20261015-173735-aade01c), from the member's own record: its cost_limit_check price, the pinned
truffle's on-demand price for the same type, taken just before launch. Nothing is imputed from
another run. A member is filled only when all of these hold:
  - cost_usd and truffle_price_usd_per_hour are null and billed_seconds is a number;
  - cost_limit_check.price_usd_per_hour is a positive number;
  - cost_limit_check.instance_type equals instance.type.
It then sets truffle_price_usd_per_hour, cost_usd = max(billed_seconds, 60) x price / 3600 (run.sh's
rule, rounded to 1e-6), truffle_price_source and cost_backfill {at, by, from}.

In cohort.json, each member row takes its manifest's cost_usd. A row run-multi.sh recorded as
{manifest: "missing", rc != 0} (run.sh refused before it made a run dir: nothing launched) gets
cost_usd 0 with cost_basis "refused before launch: nothing billed". The cohort's cost_usd is the sum
when every row has one, as run-multi.sh computes it, and cost_backfill records what changed.

Prints one line per change. Without --write it changes nothing. Exits 1 if a cohort still has a
null cost afterwards (or would have, without --write), 2 on bad input.
"""
import datetime
import json
import os
import sys

FROM = "cost_limit_check (truffle just before launch; the lookup at launch gave none)"


def load(p):
    with open(p) as f:
        return json.load(f)


def save(p, d):
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
    os.replace(tmp, p)


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def fill_member(m):
    """The cost to fill in manifest m, or None with the reason it cannot be."""
    if m.get("cost_usd") is not None:
        return None, "has cost_usd"
    if m.get("truffle_price_usd_per_hour") is not None:
        return None, "has a price but no cost_usd (not this case)"
    if not num(m.get("billed_seconds")):
        return None, "no billed_seconds"
    cl = m.get("cost_limit_check") or {}
    p = cl.get("price_usd_per_hour")
    if not num(p) or p <= 0:
        return None, "no cost_limit_check price"
    if cl.get("instance_type") != (m.get("instance") or {}).get("type"):
        return None, "cost_limit_check priced %r, the instance is %r" % (cl.get("instance_type"), (m.get("instance") or {}).get("type"))
    return (p, round(max(m["billed_seconds"], 60) * p / 3600 * 1e6) / 1e6), None


def main(argv):
    write = "--write" in argv
    dirs = [a for a in argv if a != "--write"]
    if not dirs:
        print("cost_backfill: no cohort dirs", file=sys.stderr)
        return 2
    at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    by = "scripts/lib/cost_backfill.py"
    left = 0
    for d in dirs:
        cp = os.path.join(d, "cohort.json")
        if not os.path.isfile(cp):
            print("cost_backfill: %s: no cohort.json" % d, file=sys.stderr)
            return 2
        cj = load(cp)
        changed = []
        for row in cj.get("members") or []:
            k = row.get("rank")
            mp = os.path.join("%s-r%d" % (d, k), "manifest.json")
            if os.path.isfile(mp):
                m = load(mp)
                got, why = fill_member(m)
                if got:
                    p, c = got
                    print("cost_backfill: %s r%d: cost_usd null -> %s (%s s x $%s/h, %s)" % (d, k, c, m["billed_seconds"], p, FROM))
                    m["truffle_price_usd_per_hour"] = p
                    m["cost_usd"] = c
                    m["truffle_price_source"] = FROM
                    m["cost_backfill"] = {"at": at, "by": by, "from": "cost_limit_check.price_usd_per_hour"}
                    if write:
                        save(mp, m)
                    changed.append(k)
                elif m.get("cost_usd") is None:
                    print("cost_backfill: %s r%d: cost_usd stays null: %s" % (d, k, why))
                if row.get("cost_usd") != m.get("cost_usd"):
                    row["cost_usd"] = m.get("cost_usd")
            elif row.get("manifest") == "missing" and str(row.get("rc")) not in ("0", "", "None"):
                if row.get("cost_usd") != 0:
                    print("cost_backfill: %s r%d: refused before launch (rc %s, no run dir): cost_usd 0" % (d, k, row.get("rc")))
                    row["cost_usd"] = 0
                    row["cost_basis"] = "refused before launch: nothing billed"
                    changed.append(k)
        costs = [r.get("cost_usd") for r in cj.get("members") or []]
        total = round(sum(costs) * 1e6) / 1e6 if costs and all(num(c) for c in costs) else None
        if changed:
            print("cost_backfill: %s: cohort cost_usd %s -> %s" % (d, cj.get("cost_usd"), total))
            cj["cost_backfill"] = {"at": at, "by": by, "ranks": changed, "cost_usd_before": cj.get("cost_usd")}
            cj["cost_usd"] = total
            if write:
                save(cp, cj)
        if cj.get("cost_usd") is None:
            left += 1
            print("cost_backfill: %s: cohort cost_usd still null" % d)
    if not write:
        print("cost_backfill: dry run (WRITE=1 writes)")
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
