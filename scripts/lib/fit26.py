#!/usr/bin/env python3
"""The #26 fit (WP-10 of the #25 ladder): the registered T(N) and cost model, fitted first exactly as
registered, then each addition as a separate fit, with residuals, held-out checks and the predicted
time-optimal and cost-optimal N per cohort size and instance family. From the record only.

  fit26.py   -> results/g3/fit26/{manifest.json, fit26.md, points.tsv, params.tsv, residuals.tsv,
                                  heldout.tsv, predictions.tsv, optimal.tsv}

Registered (#26, verbatim on #25):
  T(N) = t_boot + S/(N*B) + W/(N*c*r) + t_probe + t_gather + t_tail
  Cost ~= p*[N*(t_boot + t_tail) + S/B + W/(c*r)]

Stdlib only (no numpy): Levenberg-Marquardt with a numeric Jacobian, covariance s^2 (J'J)^-1,
leave-one-out refits, parametric draws for the uncertainty of the optimal N. Unit-tested on
synthetic data in scripts/lib/fit26_test.py (make test).
"""
import csv, datetime as dt, glob, hashlib, json, math, os, random, subprocess

G = "results/g3"
OUT = os.path.join(G, "fit26")
COHORTS = (1, 10, 100, 1000)
N_GRID = tuple(range(1, 65))          # the design's N range is 1..64 (#25)
R_IN_E1 = 1.84e6                      # E1's per-stream input rate (results/g3/20261008-021537-cb0cea7-7e51-n8/tables/summary.md)
T_SAMPLE = 16                         # threads per sample in flight (campaign default, points.tsv threads)
HELD_OUT = "runs/g3-e4-c8g.12xlarge-n32.json"   # the designated held-out point: the only N=32 point
FIX = "904c2a5"                       # the #44 fix (clean-room HitCounts)
DRAWS = 200
SEED = 26


# ---------------------------------------------------------------------------------------------
# Numerics (stdlib).

def inv(A):
    """Gauss-Jordan inverse with partial pivoting; raises ValueError on a singular matrix."""
    n = len(A)
    M = [list(map(float, row)) + [1.0 if i == j else 0.0 for j in range(n)] for i, row in enumerate(A)]
    scale = max((abs(x) for row in A for x in row), default=1.0) or 1.0
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) <= 1e-13 * scale:
            raise ValueError("singular matrix")
        M[c], M[p] = M[p], M[c]
        pv = M[c][c]
        M[c] = [x / pv for x in M[c]]
        for r in range(n):
            if r != c and M[r][c] != 0.0:
                f = M[r][c]
                M[r] = [a - f * b for a, b in zip(M[r], M[c])]
    return [row[n:] for row in M]


def matvec(A, v):
    return [sum(a * b for a, b in zip(row, v)) for row in A]


def chol(A):
    """Lower Cholesky factor; a tiny diagonal jitter is added if A is only semi-definite."""
    n = len(A)
    for jit in (0.0, 1e-12, 1e-9, 1e-6):
        L = [[0.0] * n for _ in range(n)]
        ok = True
        for i in range(n):
            for j in range(i + 1):
                s = A[i][j] + (jit * abs(A[i][i]) if i == j else 0.0) - sum(L[i][k] * L[j][k] for k in range(j))
                if i == j:
                    if s <= 0:
                        ok = False
                        break
                    L[i][i] = math.sqrt(s)
                else:
                    L[i][j] = s / L[j][j]
            if not ok:
                break
        if ok:
            return L
    raise ValueError("covariance not positive definite")


def jac(resid, th, r0):
    J = [[0.0] * len(th) for _ in r0]
    for j in range(len(th)):
        h = 1e-6 * max(abs(th[j]), 1e-3)
        tp, tm = list(th), list(th)
        tp[j] += h
        tm[j] -= h
        rp, rm = resid(tp), resid(tm)
        for i in range(len(r0)):
            J[i][j] = (rp[i] - rm[i]) / (2 * h)
    return J


def lm(resid, th0, iters=300):
    """Levenberg-Marquardt on resid(theta) -> [pred - obs]. Returns (theta, cov or None, rss, dof)."""
    th = list(map(float, th0))
    r = resid(th)
    rss = sum(x * x for x in r)
    lam = 1e-3
    for _ in range(iters):
        J = jac(resid, th, r)
        JTJ = [[sum(J[k][a] * J[k][b] for k in range(len(r))) for b in range(len(th))] for a in range(len(th))]
        g = [sum(J[k][a] * r[k] for k in range(len(r))) for a in range(len(th))]
        improved = False
        for _ in range(30):
            A = [[JTJ[a][b] + (lam * max(JTJ[a][a], 1e-30) if a == b else 0.0) for b in range(len(th))] for a in range(len(th))]
            try:
                step = matvec(inv(A), [-x for x in g])
            except ValueError:
                lam *= 10
                continue
            tn = [a + b for a, b in zip(th, step)]
            rn = resid(tn)
            rssn = sum(x * x for x in rn)
            if rssn <= rss:
                done = rss - rssn <= 1e-14 * max(rss, 1e-300) or max(abs(s) / max(abs(t), 1e-12) for s, t in zip(step, tn)) < 1e-12
                th, r, rss = tn, rn, rssn
                lam = max(lam / 10, 1e-12)
                improved = True
                break
            lam *= 10
        if not improved or done:
            break
    J = jac(resid, th, r)
    dof = len(r) - len(th)
    cov = None
    if dof > 0:
        JTJ = [[sum(J[k][a] * J[k][b] for k in range(len(r))) for b in range(len(th))] for a in range(len(th))]
        try:
            s2 = rss / dof
            cov = [[s2 * x for x in row] for row in inv(JTJ)]
        except ValueError:
            cov = None
    return th, cov, rss, dof


def grad(f, th):
    out = []
    for j in range(len(th)):
        h = 1e-6 * max(abs(th[j]), 1e-3)
        tp, tm = list(th), list(th)
        tp[j] += h
        tm[j] -= h
        out.append((f(tp) - f(tm)) / (2 * h))
    return out


def pred_se(f, th, cov):
    """Delta-method standard error of f(theta)."""
    if cov is None:
        return float("nan")
    g = grad(f, th)
    v = sum(g[a] * cov[a][b] * g[b] for a in range(len(g)) for b in range(len(g)))
    return math.sqrt(max(v, 0.0))


def draws(th, cov, n, seed=SEED):
    if cov is None:
        return []
    L = chol(cov)
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        z = [rng.gauss(0, 1) for _ in th]
        out.append([t + sum(L[i][k] * z[k] for k in range(i + 1)) for i, t in enumerate(th)])
    return out


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return float("nan")
    k = (len(xs) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


# ---------------------------------------------------------------------------------------------
# Models. A configuration cfg is a dict: N, vcpu, c_used, S_GB, W, w_max, n_lane, x_net, in_GB.
# Units: S_GB in GB (1e9 B); W, w_max in pairs; x_net in seconds (routed bytes at the NIC's
# peak rate); nic_GBps the type's peak NIC rate in GB/s; in_GB the cohort's input GB. beta in s/GB
# (B = 1/beta GB/s per node); beta_nic in s per GB at the NIC's rate (eta = 1/beta_nic, B = eta x
# NIC); rho in s per Mpair per vCPU (r = 1e6/rho pairs/s per vCPU).

def x_cls(cfg, c):
    return cfg["W"] / (cfg["N"] * c) / 1e6


def t_reg(th, cfg):
    K, beta, rho = th[:3]
    return K + beta * cfg["S_GB"] / cfg["N"] + rho * x_cls(cfg, cfg["vcpu"])


E2E = {
    # name: (params, units, T(theta, cfg), what)
    "R": (["K", "beta", "rho"], ["s", "s/GB", "s/(Mpair/vCPU)"], t_reg,
          "registered, end to end: T = K + beta*S/N + rho*W/(N*c), K = t_boot + t_probe + t_gather + t_tail (only their sum is identifiable from T)"),
    "R+t_input": (["K", "beta", "rho"], ["s", "s/GB", "s/(Mpair/vCPU)"],
                  lambda th, cfg: th[0] + th[1] * cfg["S_GB"] / cfg["N"] + max(th[2] * x_cls(cfg, cfg["vcpu"]), cfg["w_max"] / R_IN_E1),
                  "registered + t_input: the classify term becomes max(W/(N*c*r), w_max/r_input), r_input = 1.84 Mpairs/s per stream fixed at E1's measurement (#25 E1 addition)"),
    "R+t_emit": (["K", "beta", "rho", "tau_emit"], ["s", "s/GB", "s/(Mpair/vCPU)", "s/sample"],
                 lambda th, cfg: t_reg(th, cfg) + th[3] * cfg["n_lane"],
                 "registered + t_emit = tau_emit * samples per lane, n_lane = ceil(cohort / (N * in flight))"),
    "R+t_net": (["K", "beta", "rho", "gamma_net"], ["s", "s/GB", "s/(Mpair/vCPU)", "1"],
                lambda th, cfg: t_reg(th, cfg) + th[3] * cfg["x_net"],
                "registered + t_net = gamma_net * W*b_route*(N-1)/N^2 / NIC peak rate (routed lookup bytes per node at line rate; gamma 1 = serial, 0 = hidden)"),
    "R+t_fetch": (["K", "beta", "rho", "phi_fetch"], ["s", "s/GB", "s/(Mpair/vCPU)", "s/GB"],
                  lambda th, cfg: t_reg(th, cfg) + th[3] * cfg["in_GB"] / cfg["N"],
                  "registered + t_fetch = phi_fetch * (cohort input GB / N) (each node fetches its own inputs; the registered form has no input fetch)"),
    "R+t_sync": (["K", "beta", "rho", "kappa_sync"], ["s", "s/GB", "s/(Mpair/vCPU)", "s/doubling"],
                 lambda th, cfg: t_reg(th, cfg) + th[3] * math.log2(cfg["N"]),
                 "registered + t_sync = kappa_sync * log2(N) (rendezvous, start skew and the max-over-N of per-node tails; the registered form has no term that grows with N)"),
    "R+c_used": (["K", "beta", "rho"], ["s", "s/GB", "s/(Mpair/vCPU)"],
                 lambda th, cfg: th[0] + th[1] * cfg["S_GB"] / cfg["N"] + th[2] * x_cls(cfg, cfg["c_used"]),
                 "registered with c = threads in use, min(vCPUs, in flight x T16), in place of vCPUs (a redefinition of a registered symbol, reported as an addition)"),
    "R+B_nic": (["K", "beta_nic", "rho"], ["s", "s/(GB/(GB/s))", "s/(Mpair/vCPU)"],
                lambda th, cfg: th[0] + th[1] * cfg["S_GB"] / cfg["N"] / cfg["nic_GBps"] + th[2] * x_cls(cfg, cfg["vcpu"]),
                "registered with B = eta x the type's peak NIC rate in place of one constant B (a redefinition of a registered symbol, reported as an addition)"),
}
E2E_ORDER = ["R", "R+t_input", "R+t_emit", "R+t_net", "R+t_fetch", "R+t_sync", "R+c_used", "R+B_nic"]
E2E_START = {"K": 150.0, "beta": 0.3, "beta_nic": 1.0, "rho": 10.0, "tau_emit": 0.5, "gamma_net": 0.5, "phi_fetch": 1.0, "kappa_sync": 10.0}

# Regressors, for the extrapolation flags: a prediction is extrapolated where any regressor its fit
# uses lies outside the range that regressor spans over the fit's observations.
REG = {
    "S/N": lambda c: c["S_GB"] / c["N"],
    "S/(N*NIC)": lambda c: c["S_GB"] / c["N"] / c["nic_GBps"],
    "W/(N*c)": lambda c: x_cls(c, c["vcpu"]),
    "W/(N*c_used)": lambda c: x_cls(c, c["c_used"]),
    "w_max": lambda c: c["w_max"],
    "n_lane": lambda c: c["n_lane"],
    "x_net": lambda c: c["x_net"],
    "input/N": lambda c: c["in_GB"] / c["N"],
    "log2 N": lambda c: math.log2(c["N"]),
}
FIT_REG = {"R": ["S/N", "W/(N*c)"], "R+t_input": ["S/N", "W/(N*c)", "w_max"], "R+t_emit": ["S/N", "W/(N*c)", "n_lane"],
           "R+t_net": ["S/N", "W/(N*c)", "x_net"], "R+t_fetch": ["S/N", "W/(N*c)", "input/N"],
           "R+t_sync": ["S/N", "W/(N*c)", "log2 N"], "R+c_used": ["S/N", "W/(N*c_used)"], "R+B_nic": ["S/(N*NIC)", "W/(N*c)"],
           "P-reg": ["S/N", "W/(N*c)"],
           "P-full": ["S/(N*NIC)", "input/N", "W/(N*c_used)", "x_net", "n_lane", "w_max", "log2 N"]}
CLASSIFY_REG = {"W/(N*c_used)", "x_net", "n_lane", "w_max"}   # P-full fits these on the cohort-1 walls as well
NONNEG = {"K", "beta", "beta_nic", "rho", "tau_emit", "gamma_net", "phi_fetch", "kappa_sync", "t_boot", "t_tail", "r_input",
          "a_fetch", "t_pg"}   # physical sign: a negative value is flagged


def fit_e2e(name, pts):
    params, _, f, _ = E2E[name]
    th, cov, rss, dof = lm(lambda th: [f(th, p["cfg"]) - p["T"] for p in pts], [E2E_START[k] for k in params])
    return {"theta": th, "cov": cov, "rss": rss, "dof": dof, "n": len(pts), "T": lambda th_, cfg: f(th_, cfg)}


# Per-term fits: every term against its own measured phase; T is then their sum. The phases of
# T_with_harness decompose exactly (docs/cohort.md, "T, defined"):
#   T_wh = (boot + setup + manifest) + fetch + load + LPT wall + skew_rendezvous + body tail + harness tail max
# P-reg maps the registered terms only (t_boot, S/(N*B), W/(N*c*r) + t_probe + t_gather, t_tail =
# body tail + harness tail max); fetch and skew are not in the registered form and stay in the residual.
# P-full adds every addition: B_nic, t_fetch, t_input (fitted from the c1 walls), t_emit, t_net,
# c_used, and t_sync = skew + (harness tail max - median); t_tail = body tail + harness tail median.

def term_specs(full):
    sp = [("t_boot", ["t_boot"], ["s"], lambda th, o: th[0], lambda p: [(p["boot"], p["cfg"])], [20.0])]
    if not full:
        sp.append(("load", ["beta"], ["s/GB"], lambda th, o: th[0] * o["S_GB"] / o["N"], lambda p: [(p["load"], p["cfg"])], [0.3]))
        sp.append(("classify", ["t_pg", "rho"], ["s", "s/(Mpair/vCPU)"],
                   lambda th, o: th[0] + th[1] * x_cls(o, o["vcpu"]), lambda p: [(p["lpt"], p["cfg"])], [1.0, 10.0]))
        sp.append(("t_tail", ["t_tail"], ["s"], lambda th, o: th[0], lambda p: [(p["body_tail"] + p["htail_max"], p["cfg"])], [50.0]))
        return sp
    sp.append(("load", ["beta_nic"], ["s/(GB/(GB/s))"], lambda th, o: th[0] * o["S_GB"] / o["N"] / o["nic_GBps"],
               lambda p: [(p["load"], p["cfg"])], [1.0]))
    sp.append(("t_fetch", ["a_fetch", "phi_fetch"], ["s", "s/GB"], lambda th, o: th[0] + th[1] * o["in_GB"] / o["N"],
               lambda p: [(p["fetch"], p["cfg"])], [5.0, 1.0]))
    sp.append(("classify", ["t_pg", "rho", "gamma_net", "tau_emit", "r_input"],
               ["s", "s/(Mpair/vCPU)", "1", "s/sample", "Mpairs/s"],
               lambda th, o: max(th[0] + th[1] * x_cls(o, o["c_used"]) + th[2] * o["x_net"] + th[3] * o["n_lane"],
                                 o["w_max"] / 1e6 / th[4]),
               lambda p: [(p["lpt"], p["cfg"]), (p["c1"], p["cfg_c1"])], [1.0, 10.0, 0.3, 0.3, 1.8]))
    sp.append(("t_sync", ["kappa_sync"], ["s/doubling"], lambda th, o: th[0] * math.log2(o["N"]),
               lambda p: [(p["skew"] + p["htail_max"] - p["htail_med"], p["cfg"])], [10.0]))
    sp.append(("t_tail", ["t_tail"], ["s"], lambda th, o: th[0], lambda p: [(p["body_tail"] + p["htail_med"], p["cfg"])], [40.0]))
    return sp


def fit_terms(full, pts):
    """Fit each term to its phase; return the concatenated theta, block-diagonal cov, and T."""
    sp = term_specs(full)
    th_all, blocks, terms = [], [], []
    for name, params, units, f, obs_of, th0 in sp:
        obs = [o for p in pts for o in obs_of(p)]
        th, cov, rss, dof = lm(lambda th, f=f, obs=obs: [f(th, cfg) - y for y, cfg in obs], th0)
        terms.append({"term": name, "params": params, "units": units, "theta": th, "cov": cov, "rss": rss, "dof": dof,
                      "n": len(obs), "f": f, "off": len(th_all)})
        th_all += th
        blocks.append(cov if cov is not None else [[0.0] * len(th) for _ in th])
    n = len(th_all)
    cov = [[0.0] * n for _ in range(n)]
    for t, b in zip(terms, blocks):
        for i in range(len(t["theta"])):
            for j in range(len(t["theta"])):
                cov[t["off"] + i][t["off"] + j] = b[i][j]
    if any(t["cov"] is None for t in terms):
        cov = None

    def T(th, cfg, terms=terms):
        return sum(t["f"](th[t["off"]:t["off"] + len(t["theta"])], cfg) for t in terms)
    return {"theta": th_all, "cov": cov, "terms": terms, "T": T,
            "params": [f"{t['term']}.{p}" for t in terms for p in t["params"]],
            "units": [u for t in terms for u in t["units"]]}


def p_reg_parts(fit, cfg):
    """t_boot, t_tail and t_probe + t_gather from a P-reg fit (for the registered cost formula)."""
    th = fit["theta"]
    d = {t["term"]: th[t["off"]:t["off"] + len(t["theta"])] for t in fit["terms"]}
    return d["t_boot"][0], d["t_tail"][0], d["classify"][0], d["load"][0], d["classify"][1]


# ---------------------------------------------------------------------------------------------
# Optimal N.

def feasible_inflight(mem_mib, vcpu, N, S_bytes):
    """The mkspec.sh rule: memory holds 1.15 x the shard + 8 GB + 7.5 GB per sample in flight.
    In flight defaults to vCPUs / 8 (at least 1), reduced to what memory holds; 0 = infeasible."""
    room = mem_mib * 1048576 - 1.15 * S_bytes / N - 8e9
    if room < 7.5e9:
        return 0
    return min(max(vcpu // 8, 1), int(room // 7.5e9))


def argmin(cands, key):
    best = None
    for c in cands:
        v = key(c)
        if v == v and (best is None or v < best[0] - 1e-12 or (abs(v - best[0]) <= 1e-12 and c["N"] < best[1]["N"])):
            best = (v, c)
    return best[1] if best else None


# ---------------------------------------------------------------------------------------------
# The record.

def tsv(p):
    return list(csv.DictReader(open(p), delimiter="\t"))


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True).stdout.strip()


def prefix(commit):
    if not commit:
        return "unknown"
    rc = subprocess.run(["git", "merge-base", "--is-ancestor", FIX, commit], capture_output=True).returncode
    return "no" if rc == 0 else ("yes" if rc == 1 else "unknown")


class Record:
    def __init__(self):
        self.inputs = set()

    def open(self, p):
        self.inputs.add(p)
        return p

    def tsv(self, p):
        return tsv(self.open(p))

    def json(self, p):
        return json.load(open(self.open(p)))


def build(rec):
    S = int(rec.json("results/g0a/20261006-005556-fe849b2/out/head-hash.k2d.json")["ContentLength"])
    runs = rec.tsv("results/cohort/PRJNA398089/runs.tsv")
    runs.sort(key=lambda r: int(r["rank"]))
    itypes = rec.json("results/instance-types/us-west-2.json")["types"]
    coh = {}
    for c in COHORTS:
        sel = runs[:c]
        coh[c] = {"W": sum(int(r["read_count"]) for r in sel), "w_max": max(int(r["read_count"]) for r in sel),
                  "in_GB": sum(int(r["bytes_1"]) + int(r["bytes_2"]) for r in sel) / 1e9, "n": len(sel)}
    util = {r["run"]: r for r in rec.tsv("results/util-backfill/util-backfill.tsv") if r["scope"] == "fleet"}
    dirs = {}
    for cj in sorted(glob.glob(os.path.join(G, "2026*", "cohort.json"))):
        d = os.path.dirname(cj)
        if os.path.exists(os.path.join(d, "tables", "point.tsv")):
            dirs[json.load(open(cj))["spec"]] = d
    broute = []
    pts = []
    for p in rec.tsv(os.path.join(G, "campaign", "points.tsv")):
        d = dirs[p["spec"]]
        cj = rec.json(os.path.join(d, "cohort.json"))
        pt = rec.tsv(os.path.join(d, "tables", "point.tsv"))[0]
        bt = rec.tsv(os.path.join(d, "tables", "batches.tsv"))
        rt = rec.tsv(os.path.join(d, "tables", "rates.tsv"))[0]
        N, C = int(p["N"]), int(p["cohort"])
        b0 = [b for b in bt if b["batch"] == "0"][0]
        assert int(b0["pairs"]) == coh[C]["W"], (p["spec"], b0["pairs"], coh[C]["W"])
        for k in ("lpt_wall_s", "T_with_harness_s", "load_s", "boot_s"):
            assert pt[k] == p[k], (p["spec"], k)
        if N > 1:
            broute.append(float(rt["routed_lookup_bytes_per_pair_per_node"]) * N * N / (N - 1))
        vcpu = int(p["vcpus_per_node"])
        infl = int(p["inflight"])
        it = itypes[p["type"]]
        assert int(it["vcpus"]) == vcpu
        c1 = float(p["c1_striped_wall_s_median"]) if p["c1_striped_wall_s_median"] not in ("-", "") else float(p["c1_home_wall_s_median"])
        pts.append({
            "spec": p["spec"], "dir": d, "cohort_id": os.path.basename(d), "type": p["type"], "family": p["type"].split(".")[0],
            "N": N, "cohort": C, "inflight": infl, "threads": int(p["threads"]), "vcpu": vcpu,
            "price_h": float(p["price_per_h"]), "mem_mib": int(it["memory_mib"]), "nic_gbps": float(it["peak_gbps"]),
            "pre_fix": p["engine_pre_fix"], "pre_fix_git": prefix(cj.get("commit", "")), "commit": cj.get("commit", ""),
            "T": float(p["T_with_harness_s"]), "T_engine": float(p["T_engine_s"]),
            "boot": float(p["boot_s"]) + float(p["setup_s"]) + float(p["manifest_s"]), "fetch": float(p["fetch_s"]),
            "load": float(p["load_s"]), "lpt": float(p["lpt_wall_s"]), "lpt_spread": float(p["lpt_spread"]),
            "skew": float(p["skew_rendezvous_s"]), "body_tail": float(p["body_tail_s"]),
            "htail_max": float(p["harness_tail_s_max"]), "htail_med": float(p["harness_tail_s_median"]),
            "c1": c1, "c1_kind": "striped" if p["c1_striped_wall_s_median"] not in ("-", "") else "home",
            "derived_usd_run": N * float(p["price_per_h"]) * float(p["T_with_harness_s"]) / 3600,
            "billed_usd_run": float(p["cost_usd_members"]),
            "U_cpu_lb": (util.get(os.path.basename(d)) or {}).get("U_cpu_lb", ""),
        })
    b_route = sum(broute) / len(broute)
    for q in pts:
        q["cfg"] = cfg_for(q["N"], q["vcpu"], min(q["vcpu"], q["inflight"] * q["threads"]), S, coh[q["cohort"]], q["cohort"],
                           q["inflight"], q["nic_gbps"], b_route)
        # c1: one sample at one in flight, striped over the N nodes (home on N = 1).
        q["cfg_c1"] = cfg_for(q["N"], q["vcpu"], min(q["vcpu"], q["threads"]), S, coh[1], 1, 1, q["nic_gbps"], b_route)
        decomp = q["boot"] + q["fetch"] + q["load"] + q["lpt"] + q["skew"] + q["body_tail"] + q["htail_max"]
        assert abs(decomp - q["T"]) <= 3.0, (q["spec"], decomp, q["T"])   # phases are rounded to 1 s in point.tsv
        q["decomp_gap"] = q["T"] - decomp
    return {"S": S, "coh": coh, "itypes": itypes, "pts": pts, "b_route": b_route, "broute_all": broute}


def cfg_for(N, vcpu, c_used, S, ch, cohort, infl, nic_gbps, b_route):
    return {"N": N, "vcpu": vcpu, "c_used": c_used, "S_GB": S / 1e9, "W": ch["W"], "w_max": ch["w_max"],
            "n_lane": math.ceil(cohort / (N * infl)), "in_GB": ch["in_GB"],
            "nic_GBps": nic_gbps / 8, "x_net": ch["W"] * b_route * (N - 1) / (N * N) / (nic_gbps * 1.25e8)}


# E1 (cohort 10, 8 x x8g.4xlarge, j mod N placement): a cohort-size check of the classify term.
E1 = "results/g3/20261008-021537-cb0cea7-7e51-n8"


def e1_rows(rec):
    bt = rec.tsv(os.path.join(E1, "tables", "batches.tsv"))
    cj = rec.json(os.path.join(E1, "cohort.json"))
    return [b for b in bt if b["mode"] == "parallel" and b["s3client"] == "sdk" and b["threads"] == "16"], cj


# ---------------------------------------------------------------------------------------------

def main():
    rec = Record()
    D = build(rec)
    pts, S, coh, itypes, b_route = D["pts"], D["S"], D["coh"], D["itypes"], D["b_route"]
    os.makedirs(OUT, exist_ok=True)
    head_sha = git("rev-parse", "HEAD")
    dirty = git("status", "--porcelain", "--untracked-files=no", "--", "scripts")

    def w(name, head, rows):
        with open(os.path.join(OUT, name), "w", newline="") as fh:
            x = csv.writer(fh, delimiter="\t", lineterminator="\n")
            x.writerow(head)
            x.writerows(rows)

    def g(v, f="{:.4g}"):
        return "-" if v is None or (isinstance(v, float) and v != v) else f.format(v)

    # ---- fits ----------------------------------------------------------------------------
    FITS = {}
    for name in E2E_ORDER:
        params, units, f, what = E2E[name]
        fit = fit_e2e(name, pts)
        fit.update({"name": name, "kind": "end to end", "params": params, "units": units, "what": what,
                    "refit": (lambda sub, name=name: fit_e2e(name, sub))})
        FITS[name] = fit
    for name, full in (("P-reg", False), ("P-full", True)):
        fit = fit_terms(full, pts)
        fit.update({"name": name, "kind": "per term", "refit": (lambda sub, full=full: fit_terms(full, sub)),
                    "what": ("registered, per term: each registered term fitted to its own phase (t_boot = boot+setup+manifest; "
                             "S/(N*B) = load; W/(N*c*r) + t_probe + t_gather = the LPT batch wall; t_tail = body tail + "
                             "harness tail max); T = their sum, so the input fetch and the rendezvous skew (not in the "
                             "registered form) are in the residual") if not full else
                    ("every addition, per term: t_boot; load = beta_nic*S/(N*NIC peak) (B_nic); t_fetch = a + phi*input GB/N; classify = max(t_pg + "
                     "rho*W/(N*c_used) + gamma_net*x_net + tau_emit*n_lane, w_max/r_input), fitted on the cohort-100 LPT "
                     "walls and the cohort-1 walls; t_sync = kappa*log2 N on skew + (harness tail max - median); t_tail = "
                     "body tail + harness tail median. The phases sum exactly to T")})
        FITS[name] = fit
    ORDER = E2E_ORDER + ["P-reg", "P-full"]

    # Residuals, LOO and the designated held-out point.
    res_rows, ho_rows, stats = [], [], {}
    for name in ORDER:
        fit = FITS[name]
        Tf = fit["T"]
        loo = []
        for i, p in enumerate(pts):
            sub = pts[:i] + pts[i + 1:]
            try:
                ff = fit["refit"](sub)
                loo.append(ff["T"](ff["theta"], p["cfg"]))
            except (ValueError, ZeroDivisionError):
                loo.append(float("nan"))
        fit["loo"] = loo
        rs, ls = [], []
        for p, lp in zip(pts, loo):
            pr = Tf(fit["theta"], p["cfg"])
            se = pred_se(lambda th: Tf(th, p["cfg"]), fit["theta"], fit["cov"])
            rs.append(p["T"] - pr)
            ls.append(p["T"] - lp)
            res_rows.append([name, p["spec"], p["type"], p["N"], p["pre_fix"], f"{p['T']:.0f}", f"{pr:.1f}", g(se, "{:.1f}"),
                             f"{p['T'] - pr:+.1f}", f"{100 * (p['T'] - pr) / p['T']:+.1f}", g(lp, "{:.1f}"), g(p["T"] - lp, "{:+.1f}"),
                             "yes" if p["spec"] == HELD_OUT else ""])
        n = len(pts)
        k = len(fit["theta"])
        rss = sum(x * x for x in rs)
        tss = sum((p["T"] - sum(q["T"] for q in pts) / n) ** 2 for p in pts)
        stats[name] = {"rmse": math.sqrt(rss / n), "s": math.sqrt(rss / (n - k)) if n > k else float("nan"),
                       "loo_rmse": math.sqrt(sum(x * x for x in ls if x == x) / max(1, sum(1 for x in ls if x == x))),
                       "R2": 1 - rss / tss, "maxabs": max(abs(x) for x in rs), "k": k, "n": n,
                       "maxabs_pct": max(abs(x) / p["T"] for x, p in zip(rs, pts)) * 100}
        ho = [p for p in pts if p["spec"] == HELD_OUT][0]
        sub = [p for p in pts if p["spec"] != HELD_OUT]
        ff = fit["refit"](sub)
        pr = ff["T"](ff["theta"], ho["cfg"])
        se = pred_se(lambda th: ff["T"](th, ho["cfg"]), ff["theta"], ff["cov"])
        z = (ho["T"] - pr) / se if se == se and se > 0 else float("nan")
        cost_o, cost_p = ho["derived_usd_run"], ho["N"] * ho["price_h"] * pr / 3600
        stats[name]["ho"] = (pr, se, z)
        ho_rows.append([name, "designated held-out point (fit on the other 8 points)", ho["spec"], f"T_with_harness {ho['T']:.0f} s",
                        f"{pr:.1f}", g(se, "{:.1f}"), f"{ho['T'] - pr:+.1f}", g(z, "{:+.2f}"),
                        f"$/sample derived {cost_o / ho['cohort']:.5f}, predicted {cost_p / ho['cohort']:.5f}",
                        "extrapolated in N (N=32 beyond the other points' N <= 16)"])

    # Cohort-size checks of the classify term (no end-to-end point exists at cohort 1 or 10):
    # every point's cohort-1 wall, and E1's cohort-10 batch walls.
    e1b, e1cj = e1_rows(rec)
    e1_pre = prefix(e1cj.get("commit", ""))
    e1_type = e1cj["instance_type"]
    e1_N = int(e1cj["nodes"])
    e1_v = int(itypes[e1_type]["vcpus"])

    def cls_term(name, th, cfg):
        if name in E2E:
            if name == "R+t_input":
                return max(th[2] * x_cls(cfg, cfg["vcpu"]), cfg["w_max"] / R_IN_E1)
            if name == "R+c_used":
                return th[2] * x_cls(cfg, cfg["c_used"])
            return th[2] * x_cls(cfg, cfg["vcpu"])          # t_probe + t_gather are not separable from K
        t = [t for t in FITS[name]["terms"] if t["term"] == "classify"][0]
        return t["f"](th[t["off"]:t["off"] + len(t["theta"])], cfg)
    cs_stats = {}
    for name in ORDER:
        fit = FITS[name]
        errs = []
        for p in pts:
            v = cls_term(name, fit["theta"], p["cfg_c1"])
            errs.append(p["c1"] - v)
            ho_rows.append([name, f"cohort-1 classify phase ({p['c1_kind']}, median of 3)", p["spec"], f"{p['c1']:.2f} s", f"{v:.2f}", "-",
                            f"{p['c1'] - v:+.2f}", "-", "", "cohort 1 is outside the fit's cohort (100); P-full uses these walls in its "
                            "classify fit, so for P-full this row is in-sample"])
        for b in e1b:
            cfg = cfg_for(e1_N, e1_v, min(e1_v, int(b["inflight"]) * 16), S, coh[10], 10, int(b["inflight"]),
                          float(itypes[e1_type]["peak_gbps"]), b_route)
            v = cls_term(name, fit["theta"], cfg)
            imb = float(b["imbalance"])
            ho_rows.append([name, f"E1 cohort-10 batch {b['batch']} (j mod N, in flight {b['inflight']})", E1, f"{float(b['wall_s']):.2f} s",
                            f"{v:.2f}", "-", f"{float(b['wall_s']) - v:+.2f}", "-", f"x {imb:.2f} rank imbalance: {v * imb:.2f}",
                            f"cohort 10 is outside the fit's cohort; E1 placed j mod N with a {imb:.2f}x rank imbalance (batches.tsv), "
                            f"which the registered W/N does not model; engine pre-fix: {e1_pre}"])
        cs_stats[name] = {"c1_rmse": math.sqrt(sum(e * e for e in errs) / len(errs)), "c1_bias": sum(errs) / len(errs)}

    # ---- predictions and optima -------------------------------------------------------------
    types = sorted({p["type"] for p in pts})
    tinfo = {}
    for t in types:
        q = [p for p in pts if p["type"] == t]
        tinfo[t] = {"price_h": q[0]["price_h"], "vcpu": q[0]["vcpu"], "mem_mib": q[0]["mem_mib"], "nic": q[0]["nic_gbps"],
                    "family": q[0]["family"], "N_meas": sorted({p["N"] for p in q})}
    fam_N = {}
    for p in pts:
        fam_N.setdefault(p["family"], set()).add(p["N"])
    fams = sorted(fam_N)
    cands = []
    for t in types:
        ti = tinfo[t]
        for c in COHORTS:
            for N in N_GRID:
                infl = feasible_inflight(ti["mem_mib"], ti["vcpu"], N, S)
                if infl == 0:
                    continue
                cfg = cfg_for(N, ti["vcpu"], min(ti["vcpu"], infl * T_SAMPLE), S, coh[c], c, infl, ti["nic"], b_route)
                lo, hi = min(fam_N[ti["family"]]), max(fam_N[ti["family"]])
                fl = []
                if c != 100:
                    fl.append(f"cohort {c}: no end-to-end point (all are cohort 100)")
                if N < lo or N > hi:
                    fl.append(f"N outside the family's measured N {lo}-{hi}")
                if N not in ti["N_meas"]:
                    fl.append(f"{t} measured only at N={','.join(map(str, ti['N_meas']))}")
                cands.append({"type": t, "family": ti["family"], "cohort": c, "N": N, "inflight": infl, "cfg": cfg,
                              "price_h": ti["price_h"], "flags": fl})
    # Each fit's regressor ranges over its own observations.
    RANGE = {}
    for name in ORDER:
        rr = {}
        for k in FIT_REG[name]:
            cf = [p["cfg"] for p in pts] + ([p["cfg_c1"] for p in pts] if name == "P-full" and k in CLASSIFY_REG else [])
            vs = [REG[k](c) for c in cf]
            rr[k] = (min(vs), max(vs))
        RANGE[name] = rr

    def reg_flags(name, cfg):
        out = []
        for k, (lo, hi) in RANGE[name].items():
            v = REG[k](cfg)
            if v < lo * (1 - 1e-9) - 1e-12 or v > hi * (1 + 1e-9) + 1e-12:
                out.append(f"{k} = {v:.4g} outside the fitted {lo:.4g}-{hi:.4g}")
        return out
    pred_rows, opt_rows, OPT = [], [], {}
    for name in ORDER:
        fit = FITS[name]
        Tf, th = fit["T"], fit["theta"]
        if fit["cov"] is None:
            continue      # not identifiable: no predictions (section 2 says why)
        for cd in cands:
            cd[name] = Tf(th, cd["cfg"])
            cd["rf_" + name] = reg_flags(name, cd["cfg"])
        dr = draws(th, fit["cov"], DRAWS)
        for cd in cands:
            cfg = cd["cfg"]
            T = cd[name]
            se = pred_se(lambda t_: Tf(t_, cfg), th, fit["cov"])
            run = cd["N"] * cd["price_h"] * T / 3600
            reg = "-"
            if name == "R":
                reg = f"{cd['price_h'] / 3600 * (cd['N'] * th[0] + th[1] * cfg['S_GB'] + th[2] * cfg['W'] / cfg['vcpu'] / 1e6) / cd['cohort']:.6f}"
            elif name == "P-reg":
                tb, tt, tpg, beta, rho = p_reg_parts(fit, cfg)
                reg = f"{cd['price_h'] / 3600 * (cd['N'] * (tb + tt) + beta * cfg['S_GB'] + rho * cfg['W'] / cfg['vcpu'] / 1e6) / cd['cohort']:.6f}"
            pred_rows.append([name, cd["family"], cd["type"], cd["cohort"], cd["N"], cd["inflight"], cfg["c_used"], f"{T:.1f}", g(se, "{:.1f}"),
                              f"{run:.4f}", f"{run / cd['cohort']:.6f}", reg,
                              "extrapolated" if cd["rf_" + name] or cd["cohort"] != 100 else "within data",
                              "; ".join(cd["rf_" + name] + cd["flags"]) or "-"])
        for fam in fams:
            for c in COHORTS:
                cc = [cd for cd in cands if cd["family"] == fam and cd["cohort"] == c]
                if not cc:
                    continue
                for obj in ("time", "cost"):
                    key = (lambda cd: cd[name]) if obj == "time" else (lambda cd: cd["N"] * cd["price_h"] * cd[name])
                    b = argmin(cc, key)
                    Ns, same = [], 0
                    for d_ in dr:
                        kk = (lambda cd: Tf(d_, cd["cfg"])) if obj == "time" else (lambda cd: cd["N"] * cd["price_h"] * Tf(d_, cd["cfg"]))
                        bd = argmin(cc, kk)
                        if bd:
                            Ns.append(bd["N"])
                            same += bd["type"] == b["type"]
                    rng = f"{pct(Ns, 0.16):.0f}-{pct(Ns, 0.84):.0f}" if Ns else "-"
                    edge = []
                    if b["N"] == max(N_GRID):
                        edge.append(f"at the grid edge (N={max(N_GRID)}): T keeps falling, no interior optimum")
                    nmin = min(cd["N"] for cd in cc if cd["type"] == b["type"])
                    if b["N"] == nmin and obj == "cost":
                        edge.append(f"at {b['type']}'s memory floor (smallest feasible N={nmin})")
                    ex = b["rf_" + name] + [x for x in b["flags"] if x.startswith("cohort")] + edge
                    fl = b["rf_" + name] + b["flags"] + edge
                    OPT[(name, fam, c, obj)] = {"N": b["N"], "type": b["type"], "T": b[name],
                                                "usd": b["N"] * b["price_h"] * b[name] / 3600 / c, "rng": rng,
                                                "same": same / len(dr) if dr else float("nan"), "flags": fl, "ex": ex,
                                                "infl": b["inflight"], "rf": b["rf_" + name], "edge": edge}
                    opt_rows.append([name, fam, c, obj, b["type"], b["N"], b["inflight"], f"{b[name]:.1f}",
                                     f"{b['N'] * b['price_h'] * b[name] / 3600 / c:.6f}", rng,
                                     g(same / len(dr) if dr else float("nan"), "{:.2f}"),
                                     "extrapolated" if b["rf_" + name] or c != 100 or any("grid edge" in x for x in edge) else "within data",
                                     "; ".join(fl) or "-"])

    # ---- tables ----------------------------------------------------------------------------
    w("points.tsv", ["spec", "cohort_id", "type", "family", "N", "cohort", "inflight", "threads", "vcpus", "c_used", "price_per_h",
                     "engine_pre_fix", "T_with_harness_s", "T_engine_s", "t_boot_s", "fetch_s", "load_s", "lpt_wall_s", "skew_rendezvous_s",
                     "body_tail_s", "harness_tail_max_s", "harness_tail_median_s", "phase_sum_gap_s", "c1_wall_s", "c1_kind",
                     "S_over_N_GB", "W_pairs", "W_over_Nc_Mpairs", "w_max_pairs", "n_lane", "x_net_s", "input_GB_per_node",
                     "derived_usd_run", "billed_usd_run_all_batches", "U_cpu_lb"],
      [[p["spec"], p["cohort_id"], p["type"], p["family"], p["N"], p["cohort"], p["inflight"], p["threads"], p["vcpu"], p["cfg"]["c_used"],
        p["price_h"], p["pre_fix"], p["T"], p["T_engine"], p["boot"], p["fetch"], p["load"], p["lpt"], p["skew"], p["body_tail"],
        p["htail_max"], p["htail_med"], f"{p['decomp_gap']:+.1f}", p["c1"], p["c1_kind"], f"{p['cfg']['S_GB'] / p['N']:.2f}", p["cfg"]["W"],
        f"{x_cls(p['cfg'], p['vcpu']):.4f}", p["cfg"]["w_max"], p["cfg"]["n_lane"], f"{p['cfg']['x_net']:.2f}",
        f"{p['cfg']['in_GB'] / p['N']:.2f}", f"{p['derived_usd_run']:.4f}", f"{p['billed_usd_run']:.4f}", p["U_cpu_lb"]] for p in pts])

    def derived(pn, v, se):
        if pn.endswith("beta_nic"):
            return "eta", (1 / v if v > 0 else float("nan")), (se / v / v if v > 0 and se == se else float("nan")), "x peak NIC rate"
        if pn.endswith("beta"):
            return "B", (1 / v if v > 0 else float("nan")), (se / v / v if v > 0 and se == se else float("nan")), "GB/s per node"
        if pn.endswith("rho"):
            return "r", (1e6 / v if v > 0 else float("nan")), (1e6 * se / v / v if v > 0 and se == se else float("nan")), "pairs/s per vCPU"
        return None
    par_rows = []
    for name in ORDER:
        fit = FITS[name]
        pnames = fit["params"]
        units = fit["units"]
        for i, (pn, u) in enumerate(zip(pnames, units)):
            v = fit["theta"][i]
            if name in E2E:
                se = math.sqrt(fit["cov"][i][i]) if fit["cov"] else float("nan")
                dof, n = fit["dof"], fit["n"]
            else:
                t = [t for t in fit["terms"] if fit["params"][i].startswith(t["term"] + ".")][0]
                se = math.sqrt(fit["cov"][i][i]) if fit["cov"] else float("nan")
                dof, n = t["dof"], t["n"]
            dv = derived(pn, v, se)
            sign = "unphysical (negative)" if pn.split(".")[-1] in NONNEG and v < 0 else ""
            ident = "" if fit["cov"] is not None else "not identifiable (J'J singular)"
            par_rows.append([name, pn, u, f"{v:.6g}", g(se, "{:.3g}"), g(abs(v) / se if se == se and se > 0 else float("nan"), "{:.2f}"),
                             n, dof, dv[0] if dv else "", g(dv[1], "{:.6g}") if dv else "", g(dv[2], "{:.3g}") if dv else "", dv[3] if dv else "",
                             "; ".join(x for x in (sign, ident) if x)])
    w("params.tsv", ["fit", "param", "unit", "value", "se", "abs_t", "n_obs", "dof", "derived", "derived_value", "derived_se", "derived_unit",
                     "note"], par_rows)
    w("residuals.tsv", ["fit", "spec", "type", "N", "engine_pre_fix", "T_obs_s", "T_pred_s", "T_pred_se_s", "resid_s", "resid_pct",
                        "loo_pred_s", "loo_resid_s", "designated_held_out"], res_rows)
    w("heldout.tsv", ["fit", "check", "point", "observed", "predicted", "predicted_se", "obs_minus_pred", "z", "note", "caveat"], ho_rows)
    w("predictions.tsv", ["fit", "family", "type", "cohort", "N", "inflight", "c_used", "T_pred_s", "T_pred_se_s", "usd_run_NpT",
                          "usd_per_sample_NpT", "usd_per_sample_registered_formula", "status", "extrapolation_flags"], pred_rows)
    w("optimal.tsv", ["fit", "family", "cohort", "objective", "type", "N", "inflight", "T_pred_s", "usd_per_sample", "N_68pct_draws",
                      "draws_same_type", "status", "flags"], opt_rows)

    # ---- report ------------------------------------------------------------------------------
    md = []
    m = md.append
    m("# The #26 fit: registered T(N) and cost, then each addition (generated by scripts/lib/fit26.py)\n")
    m(f"Generated at {head_sha}{' (scripts dirty)' if dirty else ''} on {dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}. "
      "Do not edit: rerun `make g3-fit`. Every input and its sha256 is in manifest.json.\n")
    npre = sum(p["pre_fix"] == "yes" for p in pts)
    m(f"**Pre-fix.** {npre} of {len(pts)} points were measured with the pre-fix engine (engine_pre_fix = yes in points.tsv: "
      f"the commit does not descend from the #44 fix {FIX}; checked again here with git: "
      f"{', '.join(sorted({p['pre_fix_git'] for p in pts}))}). So is E1 ({e1_pre}). The #44 speed check (probe (d), a laptop "
      "against Standard-8) puts post-fix classify at 1.0252x pre-fix; it is not applied here. Every parameter, residual and "
      "predicted N below is a pre-fix result until the points are regenerated.\n")
    m("## Data and the registered symbols\n")
    m(f"- Points: the {len(pts)} cohort-100 campaign points (E2-E4) in results/g3/campaign/points.tsv, each checked against its "
      "cohort's tables/point.tsv and batches.tsv. Families with data: " +
      ", ".join(f"{f} (N = {', '.join(map(str, sorted(fam_N[f])))})" for f in fams) + ". Only x8g has 3 or more N; r8g and c9g "
      "have one point each, so their family rates rest on the pooled fit.")
    m("- **T** (the fitted observable) = T_with_harness: first launch to the last member's termination (Scott's end-to-end ruling, "
      "#25 2026-10-09). The phases decompose it exactly (docs/cohort.md, \"T, defined\"); points.tsv phase_sum_gap_s is the "
      "rounding gap.")
    m(f"- **S** = hash.k2d, {S} bytes (results/g0a/20261006-005556-fe849b2/out/head-hash.k2d.json). **N** = nodes. "
      "**B** = per-node load rate. **W** = the cohort's pairs (batch 0, runs.tsv's first 100 runs). **c** = vCPUs per node, "
      "as registered. **r** = pairs/s per vCPU. **p** = the truffle on-demand price per node-hour at launch (points.tsv).")
    m("- The registered constants t_boot, t_probe, t_gather and t_tail do not depend on N or W, so an end-to-end fit can "
      "identify only their sum K. The per-term fits separate t_boot and t_tail; t_probe + t_gather stays one intercept of the "
      "classify phase (t_pg).")
    m(f"- t_net uses b_route = {b_route:.1f} bytes per pair, the mean over the N > 1 points of rates.tsv's "
      "routed_lookup_bytes_per_pair_per_node x N^2/(N-1) (range " +
      f"{min(D['broute_all']):.1f}-{max(D['broute_all']):.1f}), at each type's peak NIC rate "
      "(results/instance-types/us-west-2.json).")
    m("- Cost: **N*p*T** (every node billed for the fleet's wall, the derived $ of points.tsv) is the cost used for the optima. "
      "The registered formula p*[N*(t_boot + t_tail) + S/B + W/(c*r)] is evaluated beside it for R and P-reg "
      "(predictions.tsv). Neither is effective cost: the utilisation backfill (results/util-backfill/) gives lower bounds "
      "only, and U_cpu_lb is shown per point for context.")
    m("- Uncertainty: s^2 (J'J)^-1 from the fit; predictions by the delta method; the optimal N's 68% range from "
      f"{DRAWS} parametric draws (seed {SEED}). Held-out: leave-one-out for every point, plus the designated held-out point "
      f"{HELD_OUT} (the only N=32 point), fitted on the other 8.\n")
    m("## Points\n")
    m("| point | N | vCPU | c used | in flight | T (s) | t_boot | fetch | load | LPT wall | skew | tails (body+harness max) | c1 wall | U_cpu_lb | pre-fix |")
    m("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for p in pts:
        m(f"| {p['type']} N={p['N']} | {p['N']} | {p['vcpu']} | {p['cfg']['c_used']} | {p['inflight']} | {p['T']:.0f} | {p['boot']:.0f} | "
          f"{p['fetch']:.0f} | {p['load']:.1f} | {p['lpt']:.2f} | {p['skew']:.0f} | {p['body_tail'] + p['htail_max']:.0f} | {p['c1']:.2f} | "
          f"{g(float(p['U_cpu_lb']) if p['U_cpu_lb'] else float('nan'), '{:.3f}')} | {p['pre_fix']} |")
    m("")

    def ptable(name):
        rows = [r for r in par_rows if r[0] == name]
        m("| param | value | se | abs t | derived | n obs | dof | note |")
        m("|---|---|---|---|---|---|---|---|")
        for r in rows:
            m(f"| {r[1]} ({r[2]}) | {r[3]} | {r[4]} | {r[5]} | {(r[8] + ' = ' + r[9] + ' +- ' + r[10] + ' ' + r[11]) if r[8] else ''} | {r[6]} | {r[7]} | {r[12]} |")
        m("")

    def rtable(name):
        m("| point | T obs | T pred +- se | resid | resid % | LOO pred | LOO resid |")
        m("|---|---|---|---|---|---|---|")
        for r in [r for r in res_rows if r[0] == name]:
            m(f"| {r[2]} N={r[3]}{' (held out)' if r[12] else ''} | {r[5]} | {r[6]} +- {r[7]} | {r[8]} | {r[9]} | {r[10]} | {r[11]} |")
        s = stats[name]
        if name not in E2E:
            terms = FITS[name]["terms"]
            m("\nPer-term residuals, observed phase - fitted term (s), in-sample; their sum is the T residual up to the "
              "unmodelled phases" + (" (fetch and skew, not in the registered form)" if name == "P-reg" else "") + ":\n")
            m("| point | " + " | ".join(t["term"] for t in terms) + " |")
            m("|---|" + "---|" * len(terms))
            spec = dict((t[0], t[4]) for t in term_specs(name == "P-full"))
            for p in pts:
                cells = []
                for t in terms:
                    obs = spec[t["term"]](p)
                    cells.append(", ".join(f"{y - t['f'](t['theta'], cfg):+.1f}" for y, cfg in obs))
                m(f"| {p['type']} N={p['N']} | " + " | ".join(cells) + " |")
            m("\n(classify cells: the cohort-100 LPT wall, then the cohort-1 wall where the fit uses it.) "
              f"T is not fitted directly here, so there is no T dof; rmse {s['rmse']:.1f} s, R^2 {s['R2']:.3f}, max |resid| "
              f"{s['maxabs']:.0f} s ({s['maxabs_pct']:.0f}%), LOO rmse {s['loo_rmse']:.1f} s (every term refitted without the point). "
              f"Held-out {HELD_OUT}: predicted {s['ho'][0]:.0f} +- {g(s['ho'][1], '{:.0f}')} s against "
              f"{[p for p in pts if p['spec'] == HELD_OUT][0]['T']:.0f} s (z = {g(s['ho'][2], '{:+.2f}')}). Cohort-1 classify "
              f"check: rmse {cs_stats[name]['c1_rmse']:.2f} s, mean obs - pred {cs_stats[name]['c1_bias']:+.2f} s.\n")
            return
        m(f"\nrmse {s['rmse']:.1f} s (s = {g(s['s'], '{:.1f}')} s with {s['n'] - s['k']} dof), R^2 {s['R2']:.3f}, max |resid| "
          f"{s['maxabs']:.0f} s ({s['maxabs_pct']:.0f}%), LOO rmse {s['loo_rmse']:.1f} s. Held-out {HELD_OUT}: predicted "
          f"{s['ho'][0]:.0f} +- {g(s['ho'][1], '{:.0f}')} s against {[p for p in pts if p['spec'] == HELD_OUT][0]['T']:.0f} s "
          f"(z = {g(s['ho'][2], '{:+.2f}')}). Cohort-1 classify check: rmse {cs_stats[name]['c1_rmse']:.2f} s, mean "
          f"obs - pred {cs_stats[name]['c1_bias']:+.2f} s.\n")

    m("## 1. The registered form, exactly as registered (fit R, end to end)\n")
    m(E2E["R"][3] + ".\n")
    ptable("R")
    rtable("R")
    R = FITS["R"]
    m("## 1b. The registered form, per term (fit P-reg)\n")
    m(FITS["P-reg"]["what"] + ".\n")
    ptable("P-reg")
    rtable("P-reg")

    # Defects, from the fits.
    m("## Defects in the registered form\n")
    th = R["theta"]
    mono = all(OPT[("R", f, c, "time")]["N"] == max(N_GRID) or "grid edge" in "; ".join(OPT[("R", f, c, "time")]["flags"])
               for f in fams for c in COHORTS if ("R", f, c, "time") in OPT)
    floor = all(any("memory floor" in x for x in OPT[("R", f, c, "cost")]["flags"]) for f in fams for c in COHORTS if ("R", f, c, "cost") in OPT)
    xg = sorted([p for p in pts if p["family"] == "x8g"], key=lambda p: p["N"])
    turn = [(a, b) for a, b in zip(xg, xg[1:]) if b["T"] > a["T"]]
    pr_t = p_reg_parts(FITS["P-reg"], pts[0]["cfg"])
    ld = {p["type"] + f" N={p['N']}": S / 1e9 / p["N"] / p["load"] for p in pts}
    defects = [
        ("No N-optimum in time", f"every N-dependent term falls as 1/N, so T(N) is monotone decreasing for B, r > 0: the time-optimal "
         f"N is the grid edge (N={max(N_GRID)}) in {'every' if mono else 'most'} family x cohort cell of fit R. The registered "
         "H-width knee (6-8 at cohort 1, ~20 at cohort 100) cannot come out of this form. Measured: " +
         ("; ".join(f"x8g T rises from N={a['N']} ({a['T']:.0f} s) to N={b['N']} ({b['T']:.0f} s)" for a, b in turn) or "no rise on x8g") +
         f", and c8g N=16 -> 32 is {[p for p in pts if p['type'] == 'c8g.12xlarge' and p['N'] == 16][0]['T']:.0f} -> "
         f"{[p for p in pts if p['type'] == 'c8g.12xlarge' and p['N'] == 32][0]['T']:.0f} s."),
        ("No N-optimum in cost", "the registered cost is linear increasing in N (N*(t_boot + t_tail)) plus N-free terms, so the "
         f"cost-optimal N is always the smallest N whose memory holds the shard{' (every cell of fit R)' if floor else ''}."),
        ("Constants not identifiable", "t_boot, t_probe, t_gather and t_tail enter T only as a sum; T data alone cannot separate "
         f"them (fit R's K = {th[0]:.0f} s). Per term, t_probe + t_gather is still one intercept (P-reg t_pg = {pr_t[2]:.2f} s)."),
        ("Cost formula is not N*p*T", "p*N*T(N) = p*[N*(t_boot + t_probe + t_gather + t_tail) + S/B + W/(c*r)]: the registered "
         "cost drops N*(t_probe + t_gather) (it would be N*p*T if they were 0), and it bills the fleet for the sum of per-node "
         "times while T takes per-term maxima over nodes (points.tsv derived_T); with P-reg's t_pg the formula is lower than "
         "N*p*T by N*p*t_pg (predictions.tsv, both columns)."),
        ("No input fetch", "every node fetches its own inputs before classifying (fetch_s "
         f"{min(p['fetch'] for p in pts):.0f}-{max(p['fetch'] for p in pts):.0f} s here); the registered form has no such term, "
         "so it sits in K and in the residual."),
        ("No term that grows with N", "rendezvous + start skew and the max-over-N of per-node tails grow with N (skew "
         + ", ".join(f"N={p['N']}: {p['skew']:.0f}" for p in xg) + " s on x8g; harness tail max "
         + ", ".join(f"N={p['N']}: {p['htail_max']:.0f}" for p in xg) + " s); the registered T has none."),
        ("B is one constant", "the measured per-node load rate depends on the node's NIC, not only on N: "
         + ", ".join(f"{k} {v:.2f}" for k, v in ld.items()) + " GB/s (S/N / load_s)."),
        ("c is vCPUs, but the engine used min(vCPUs, in flight x T16) threads", "E3's c8g/c9g.12xlarge at N=16 ran 1 in flight x T16 "
         "on 48 vCPUs (memory allowed 1), so W/(N*c*r) with c = vCPUs predicts 3x too little classify time there (fit R's "
         "residuals; U_cpu_lb " + ", ".join(f"{p['type']} N={p['N']} {float(p['U_cpu_lb']):.3f}" for p in pts
                                            if p["cfg"]["c_used"] < p["vcpu"] and p["U_cpu_lb"]) + " in points.tsv)."),
        ("W/N assumes perfect balance and no per-sample floor", "a sample is classified by its home node at the per-stream input "
         "rate (E1: 1.84 Mpairs/s), so the classify phase is at least w_max/r_input (11.3 s at cohort 100, 5.7 s at cohort 1); the "
         "cohort-1 check shows the registered term predicts " +
         f"{sum(cls_term('R', R['theta'], p['cfg_c1']) for p in pts) / len(pts):.2f} s on average where "
         f"{sum(p['c1'] for p in pts) / len(pts):.2f} s was measured."),
    ]
    for i, (a, b) in enumerate(defects, 1):
        m(f"{i}. **{a}.** {b}")
    m("")

    m("## 2. Additions, each as a separate fit\n")
    m("Each row adds one term (or redefines c) to the registered end-to-end form and refits all of its parameters on the same 9 "
      "points. 'Resolved' means |value|/se >= 2 for the added parameter. The fit is shown without the additions in section 1.\n")
    m("| fit | what | added param = value +- se | resolved | rmse | LOO rmse | R^2 | held-out N=32 pred (obs) | c1 check rmse |")
    m("|---|---|---|---|---|---|---|---|---|")
    hoT = [p for p in pts if p["spec"] == HELD_OUT][0]["T"]
    for name in E2E_ORDER:
        fit = FITS[name]
        s = stats[name]
        if name == "R":
            add = "-"
            res = "-"
        elif name in ("R+t_input", "R+c_used"):
            add = "(no added parameter)"
            res = "-"
        elif name == "R+B_nic":
            v, se = fit["theta"][1], math.sqrt(fit["cov"][1][1]) if fit["cov"] else float("nan")
            add = f"eta = 1/beta_nic = {1 / v:.3g} +- {g(se / v / v, '{:.2g}')} (B in place of the constant)"
            res = "yes" if se == se and abs(v) >= 2 * se else "no"
        else:
            v, se = fit["theta"][3], math.sqrt(fit["cov"][3][3]) if fit["cov"] else float("nan")
            add = f"{fit['params'][3]} = {v:.4g} +- {g(se, '{:.3g}')} {fit['units'][3]}"
            res = "yes" if se == se and abs(v) >= 2 * se else f"no (|t| = {g(abs(v) / se if se == se and se else float('nan'), '{:.2f}')})"
            if fit["cov"] is None:
                res = ("not identifiable: J'J is singular" + (" (at one cohort size input GB/N is proportional to S/N, so "
                       "phi_fetch and beta cannot be separated)" if name == "R+t_fetch" else ""))
            elif v < 0 and fit["params"][3] in NONNEG:
                res += "; unphysical sign"
        m(f"| {name} | {E2E[name][3]} | {add} | {res} | {s['rmse']:.1f} | {s['loo_rmse']:.1f} | {s['R2']:.3f} | "
          f"{s['ho'][0]:.0f} +- {g(s['ho'][1], '{:.0f}')} ({hoT:.0f}) | {cs_stats[name]['c1_rmse']:.2f} |")
    m("")
    for name in E2E_ORDER[1:]:
        m(f"### {name}\n")
        ptable(name)
        rtable(name)
    m("## 3. Every addition together, per term (fit P-full)\n")
    m(FITS["P-full"]["what"] + ".\n")
    ptable("P-full")
    rtable("P-full")

    m("## 4. Predicted time-optimal and cost-optimal N\n")
    m(f"Grid N = 1..{max(N_GRID)} for each measured type (its truffle price; memory feasibility by the mkspec rule, in flight = "
      "vCPUs/8 reduced to what memory holds, c used = min(vCPUs, in flight x T16)); per family, the best type and N. Cost = "
      "N*p*T per sample. Range = the 16th-84th percentile of the optimal N over the parametric draws; 'same type' = the "
      "fraction of draws that pick the same type. Every cell at cohort 1, 10 or 1000 is extrapolated in cohort size (all "
      "end-to-end points are cohort 100); cohort 1000 is beyond any measured W. Flags per cell are in optimal.tsv.\n")
    for name in ("R", "P-reg") + tuple(n for n in E2E_ORDER[1:]) + ("P-full",):
        m(f"### {name}\n")
        if FITS[name]["cov"] is None:
            m("Not identifiable on these points (section 2): no predictions.\n")
            continue
        m("| family | cohort | time-optimal: type N (68% N) | T s | $/sample | cost-optimal: type N (68% N) | T s | $/sample | extrapolated |")
        m("|---|---|---|---|---|---|---|---|---|")
        for f in fams:
            for c in COHORTS:
                a, b = OPT.get((name, f, c, "time")), OPT.get((name, f, c, "cost"))
                if not a:
                    continue
                ex = [f"cohort {c}"] if c != 100 else []
                for lab, o in (("time", a), ("cost", b)):
                    fl = [x.split(" = ")[0] if " outside the fitted " in x else x for x in o["rf"] + o["edge"]
                          if " outside the fitted " in x or "grid edge" in x]
                    if fl:
                        ex.append(f"{lab}: " + ", ".join(fl))
                m(f"| {f} | {c} | {a['type']} N={a['N']} ({a['rng']}) | {a['T']:.0f} | {a['usd']:.5f} | {b['type']} N={b['N']} "
                  f"({b['rng']}) | {b['T']:.0f} | {b['usd']:.5f} | {'; '.join(ex) or 'no'} |")
        m("")

    m("## Caveats\n")
    m("- Every point is cohort 100 and ran three LPT/mod batches plus six cohort-1 repeats; T_with_harness ends at the last "
      "member's termination after all of them only through the tails, and the batch-0 critical path is what T measures "
      "(docs/cohort.md). The billed $ covers every batch (points.tsv billed_usd_run_all_batches) and is not the fitted cost.")
    m("- E2's fleets are memory-equal, not vCPU-equal, so N and c move together on x8g (fleet vCPUs 96, 96, 128, 128, 128); "
      "the x8g N-trend is a node-size trend as well.")
    m("- The c8g N=16 vs 32 pair differs in in-flight (1 vs 6) as well as N (summary.md); only c_used and P-full model that.")
    m("- t_input in R+t_input uses E1's r_input as a constant (E1 is pre-fix too); P-full fits r_input from the cohort-1 walls, "
      "so its cohort-1 check is in-sample.")
    m("- With 9 points, a 4-parameter end-to-end fit has 5 dof; additions that are not resolved are reported, not dropped.")
    m("- NIC rates are the peak (burst) rates of describe-instance-types; burstable types (x8g.2xlarge/4xlarge, r8g.4xlarge: "
      "baseline 3.75-7.5 Gbit/s) can fall to baseline on long transfers, which no point here measured.")
    m("- 'Extrapolated' (section 4, optimal.tsv, predictions.tsv status) = a regressor of that fit outside the range it spans over "
      "the fit's observations, a cohort size other than 100, or an optimum at the grid edge. A type measured at one N and "
      "predicted at another is listed in the flags, not counted as extrapolation when its regressors are inside the range.")
    m("- The optimal-N ranges cover parameter uncertainty only, not model error: compare each fit's LOO rmse.")
    m("- Upstream is not fitted here: #26's form is the engine's.")
    open(os.path.join(OUT, "fit26.md"), "w").write("\n".join(md) + "\n")

    # ---- manifest --------------------------------------------------------------------------
    me = os.path.relpath(os.path.abspath(__file__))
    ins = sorted(rec.inputs)
    man = {
        "what": "the #26 fit (WP-10 of the #25 ladder): the registered T(N) and cost model, then each addition as a separate fit",
        "generated_by": me, "generated_by_sha256": sha256(me), "commit": head_sha, "scripts_dirty": bool(dirty),
        "generated_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "registered": {"T": "T(N) = t_boot + S/(N*B) + W/(N*c*r) + t_probe + t_gather + t_tail",
                       "cost": "Cost ~= p*[N*(t_boot + t_tail) + S/B + W/(c*r)]", "where": "#26; verbatim on #25 (2026-10-07)"},
        "observable": "T_with_harness_s (points.tsv): first launch to the last member's termination",
        "points": [{"spec": p["spec"], "cohort": p["cohort_id"], "commit": p["commit"], "engine_pre_fix": p["pre_fix"]} for p in pts],
        "engine_pre_fix": {"fix": FIX, "points_pre_fix": npre, "points": len(pts), "e1": e1_pre},
        "fits": {n: {"kind": FITS[n]["kind"], "what": FITS[n]["what"], "params": FITS[n]["params"],
                     "theta": FITS[n]["theta"], "rmse_s": stats[n]["rmse"], "loo_rmse_s": stats[n]["loo_rmse"]} for n in ORDER},
        "constants": {"S_bytes": S, "b_route_bytes_per_pair": b_route, "r_input_e1_pairs_per_s": R_IN_E1, "threads_per_sample": T_SAMPLE,
                      "N_grid": [min(N_GRID), max(N_GRID)], "draws": DRAWS, "seed": SEED, "held_out": HELD_OUT,
                      "memory_rule": "mem >= 1.15 x hash.k2d/N + 8 GB + 7.5 GB x in flight (scripts/g3/mkspec.sh)"},
        "inputs": [{"path": p, "sha256": sha256(p)} for p in ins],
        "outputs": ["fit26.md", "points.tsv", "params.tsv", "residuals.tsv", "heldout.tsv", "predictions.tsv", "optimal.tsv"],
    }
    json.dump(man, open(os.path.join(OUT, "manifest.json"), "w"), indent=1)
    open(os.path.join(OUT, "manifest.json"), "a").write("\n")
    print(f"fit26: {len(pts)} points, {len(ORDER)} fits, {len(ins)} inputs -> {OUT}/; " +
          ", ".join(f"{n} rmse {stats[n]['rmse']:.0f} s (LOO {stats[n]['loo_rmse']:.0f})" for n in ORDER))


if __name__ == "__main__":
    main()
