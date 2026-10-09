#!/usr/bin/env python3
"""make test: scripts/lib/fit26.py's fitting code on synthetic data with known parameters (synthetic
data is for unit tests only; CLAUDE.md Law 3). No record file is read."""
import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fit26  # noqa: E402

FAIL = []


def check(what, got, want, tol):
    ok = got == got and abs(got - want) <= tol
    print(f"fit26_test: {'ok  ' if ok else 'FAIL'} {what}: got {got!r}, want {want!r} (tol {tol})")
    if not ok:
        FAIL.append(what)


def truth(what, cond, got=""):
    print(f"fit26_test: {'ok  ' if cond else 'FAIL'} {what} {got!r}")
    if not cond:
        FAIL.append(what)


def cfg(N, vcpu, cohort=100, W=1.1e9, w_max=2.0e7, infl=2, nic=15.0, in_GB=100.0, c_used=None):
    ch = {"W": W, "w_max": w_max, "in_GB": in_GB}
    return fit26.cfg_for(N, vcpu, c_used if c_used is not None else vcpu, 1189e9, ch, cohort, infl, nic, 476.0)


# Synthetic designs: N and c vary independently, as the regressors of the registered form need.
DESIGN = [(n, v) for n in (1, 2, 4, 8, 16, 32) for v in (16, 48)]


def points(model, th, noise=0.0, seed=1):
    rng = random.Random(seed)
    out = []
    for N, v in DESIGN:
        c = cfg(N, v)
        out.append({"cfg": c, "T": model(th, c) + (rng.gauss(0, noise) if noise else 0.0)})
    return out


# 1. Linear algebra.
A = [[4.0, 1.0, 0.5], [1.0, 3.0, 0.2], [0.5, 0.2, 2.0]]
Ai = fit26.inv(A)
I = [[sum(A[i][k] * Ai[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
check("inv: A A^-1 = I (max |off|)", max(abs(I[i][j] - (1.0 if i == j else 0.0)) for i in range(3) for j in range(3)), 0.0, 1e-12)
try:
    fit26.inv([[1.0, 2.0], [2.0, 4.0]])
    truth("inv: singular matrix raises", False)
except ValueError:
    truth("inv: singular matrix raises", True)
L = fit26.chol(A)
LLt = [[sum(L[i][k] * L[j][k] for k in range(3)) for j in range(3)] for i in range(3)]
check("chol: L L' = A", max(abs(LLt[i][j] - A[i][j]) for i in range(3) for j in range(3)), 0.0, 1e-12)

# 2. The registered end-to-end form: exact recovery with no noise.
TRUE = [200.0, 0.30, 9.0]       # K s, beta s/GB (B = 3.33 GB/s), rho s per Mpair per vCPU (r = 111k pairs/s)
f = fit26.E2E["R"][2]
pts = points(f, TRUE)
th, cov, rss, dof = fit26.lm(lambda t: [f(t, p["cfg"]) - p["T"] for p in pts], [100.0, 1.0, 1.0])
for k, (a, b) in enumerate(zip(th, TRUE)):
    check(f"R exact: param {k}", a, b, 1e-6 * max(1, abs(b)))
check("R exact: rss", rss, 0.0, 1e-12)
truth("R exact: dof = n - 3", dof == len(DESIGN) - 3, dof)

# 3. With noise: the estimate is within 3 se, and the 95% intervals cover at about the nominal rate.
NOISE = 5.0
hits, tot = 0, 0
for seed in range(1, 201):
    pts = points(f, TRUE, NOISE, seed)
    th, cov, rss, dof = fit26.lm(lambda t: [f(t, p["cfg"]) - p["T"] for p in pts], [100.0, 1.0, 1.0])
    for k in range(3):
        se = math.sqrt(cov[k][k])
        tot += 1
        hits += abs(th[k] - TRUE[k]) <= 2.447 * se   # t(0.975, 6 dof)
    if seed == 1:
        for k in range(3):
            truth(f"R noisy: param {k} within 3 se", abs(th[k] - TRUE[k]) <= 3 * math.sqrt(cov[k][k]), (th[k], math.sqrt(cov[k][k])))
check("R noisy: 95% interval coverage over 200 replicates", hits / tot, 0.95, 0.03)

# 4. LOO residuals of a linear fit equal e_i / (1 - h_ii) (hat matrix): the refit-based LOO is right.
pts = points(f, TRUE, NOISE, 7)
th, cov, rss, dof = fit26.lm(lambda t: [f(t, p["cfg"]) - p["T"] for p in pts], [100.0, 1.0, 1.0])
X = [[1.0, p["cfg"]["S_GB"] / p["cfg"]["N"], fit26.x_cls(p["cfg"], p["cfg"]["vcpu"])] for p in pts]
XtXi = fit26.inv([[sum(x[a] * x[b] for x in X) for b in range(3)] for a in range(3)])
worst = 0.0
for i, p in enumerate(pts):
    h = sum(X[i][a] * XtXi[a][b] * X[i][b] for a in range(3) for b in range(3))
    e = p["T"] - f(th, p["cfg"])
    sub = pts[:i] + pts[i + 1:]
    ff = fit26.fit_e2e("R", sub)
    worst = max(worst, abs((p["T"] - f(ff["theta"], p["cfg"])) - e / (1 - h)))
check("LOO by refit = e/(1-h) (max abs diff, s)", worst, 0.0, 1e-5)

# 5. An addition: t_sync, recovered exactly; the added parameter is resolved with noise.
fs = fit26.E2E["R+t_sync"][2]
TS = TRUE + [20.0]
pts = points(fs, TS)
ff = fit26.fit_e2e("R+t_sync", pts)
for k, (a, b) in enumerate(zip(ff["theta"], TS)):
    check(f"R+t_sync exact: param {k}", a, b, 1e-6 * max(1, abs(b)))
pts = points(fs, TS, NOISE, 3)
ff = fit26.fit_e2e("R+t_sync", pts)
truth("R+t_sync noisy: kappa resolved (|t| >= 2)", abs(ff["theta"][3]) >= 2 * math.sqrt(ff["cov"][3][3]), ff["theta"][3])

# 6. A collinear addition is reported as not identifiable: at one cohort size input/N is
#    proportional to S/N (as in the record).
pts = points(fit26.E2E["R+t_fetch"][2], TRUE + [0.5])
ff = fit26.fit_e2e("R+t_fetch", pts)
truth("R+t_fetch at one cohort size: cov is None (J'J singular)", ff["cov"] is None)

# 7. The max() form (t_input): exact recovery with the floor binding on part of the design.
fi = fit26.E2E["R+t_input"][2]
pts = points(fi, TRUE)
nb = sum(1 for p in pts if p["cfg"]["w_max"] / fit26.R_IN_E1 > TRUE[2] * fit26.x_cls(p["cfg"], p["cfg"]["vcpu"]))
truth("R+t_input design: the floor binds on some points but not all", 0 < nb < len(pts), nb)
ff = fit26.fit_e2e("R+t_input", pts)
for k, (a, b) in enumerate(zip(ff["theta"], TRUE)):
    check(f"R+t_input exact: param {k}", a, b, 1e-5 * max(1, abs(b)))

# 8. The per-term fits: synthetic phases from known terms; P-full recovers every parameter,
#    including r_input from the cohort-1 walls, and its T is the sum of the phases.
PT = {"t_boot": 60.0, "beta_nic": 1.2, "a_fetch": 10.0, "phi_fetch": 0.6, "t_pg": 2.0, "rho": 10.0, "gamma_net": 0.3,
      "tau_emit": 0.4, "r_input": 1.7, "kappa_sync": 20.0, "t_tail": 40.0}
spec = {s[0]: s for s in fit26.term_specs(True)}


def term(name, c):
    s = spec[name]
    return s[3]([PT[k] for k in s[1]], c)


syn = []
for N, v in DESIGN:
    for nic in (15.0, 25.0):
        c = cfg(N, v, nic=nic, infl=max(1, v // 8))
        c1 = cfg(N, v, cohort=1, W=1.05e7, w_max=1.05e7, infl=1, nic=nic, in_GB=1.0, c_used=min(v, 16))
        p = {"cfg": c, "cfg_c1": c1, "boot": term("t_boot", c), "load": term("load", c), "fetch": term("t_fetch", c),
             "lpt": term("classify", c), "c1": term("classify", c1), "skew": term("t_sync", c), "htail_max": 0.0, "htail_med": 0.0,
             "body_tail": term("t_tail", c)}
        p["T"] = p["boot"] + p["load"] + p["fetch"] + p["lpt"] + p["skew"] + p["body_tail"]
        syn.append(p)
pf = fit26.fit_terms(True, syn)
for i, k in enumerate(pf["params"]):
    check(f"P-full exact: {k}", pf["theta"][i], PT[k.split(".")[1]], 1e-4 * max(1, abs(PT[k.split('.')[1]])))
check("P-full: T = sum of the phases (max abs, s)", max(abs(pf["T"](pf["theta"], p["cfg"]) - p["T"]) for p in syn), 0.0, 1e-4)

# 9. Optimal N: T = a + b/N + k*log2 N has its minimum at N* = b*ln2/k; with b = 8k/ln2 it is 8.
k_ = 10.0
b_ = 8 * k_ / math.log(2)
cands = [{"N": n, "T": 50 + b_ / n + k_ * math.log2(n)} for n in range(1, 65)]
truth("argmin: interior optimum at N* = b ln2 / k = 8", fit26.argmin(cands, lambda c: c["T"])["N"] == 8,
      fit26.argmin(cands, lambda c: c["T"])["N"])
truth("argmin: ties go to the smaller N", fit26.argmin([{"N": 3}, {"N": 2}], lambda c: 1.0)["N"] == 2)
# The registered form: T falls monotonically in N (time optimum at the grid edge); N*p*T rises (cost optimum at the floor).
c0 = [{"N": n, "cfg": cfg(n, 16)} for n in range(4, 65)]
truth("registered: time optimum at the grid edge", fit26.argmin(c0, lambda c: f(TRUE, c["cfg"]))["N"] == 64)
truth("registered: cost (N p T) optimum at the smallest N", fit26.argmin(c0, lambda c: c["N"] * f(TRUE, c["cfg"]))["N"] == 4)

# 10. Parametric draws reproduce the covariance.
cv = [[4.0, 1.2], [1.2, 1.0]]
ds = fit26.draws([10.0, -3.0], cv, 4000, seed=5)
m0 = sum(d[0] for d in ds) / len(ds)
m1 = sum(d[1] for d in ds) / len(ds)
check("draws: mean 0", m0, 10.0, 0.1)
check("draws: var 0", sum((d[0] - m0) ** 2 for d in ds) / len(ds), 4.0, 0.25)
check("draws: cov 01", sum((d[0] - m0) * (d[1] - m1) for d in ds) / len(ds), 1.2, 0.1)
check("pred_se: linear f = a.theta has se sqrt(a' C a)", fit26.pred_se(lambda t: 2 * t[0] + t[1], [0.0, 0.0], cv),
      math.sqrt(4 * 4.0 + 4 * 1.2 + 1.0), 1e-6)

# 11. Memory feasibility = scripts/g3/mkspec.sh's rule (synthetic sizes).
truth("feasible: too small -> 0", fit26.feasible_inflight(64 * 1024, 16, 8, 1189e9) == 0)
mib = math.ceil((1.15 * 1189e9 / 16 + 8e9 + 2 * 7.5e9) / 1048576)
truth("feasible: exactly 2 in flight", fit26.feasible_inflight(mib, 48, 16, 1189e9) == 2, fit26.feasible_inflight(mib, 48, 16, 1189e9))
truth("feasible: capped at vCPUs/8", fit26.feasible_inflight(10 ** 7, 16, 16, 1189e9) == 2)

print(f"fit26_test: {'FAIL ' + str(len(FAIL)) + ': ' + ', '.join(FAIL) if FAIL else 'all passed'}")
sys.exit(1 if FAIL else 0)
