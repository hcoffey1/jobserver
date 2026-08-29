#!/usr/bin/env python3
"""
Build the fallback-nursery A/B/C report from a copied-back results tree.

  conda run -n dataVis python scripts/regent_nursery/nursery_report.py \
      ./sweep_results_nursery_abc -o ./nursery_report

Produces, per workload:
  runtime_<workload>.png      median + min-max range of wall time, by ratio x arm
  alloc_<workload>_r<R>.png   per-region granted vs demand over time, one panel
                              per arm, with MAR on a twin axis
  numastat_<workload>_r<R>.png node-0/node-1 residency over time vs the fast-tier
                              budget, warmup transient shaded not hidden
and, across workloads:
  runtime_summary.csv   one row per (workload, ratio, arm): n, median, min, max
  cheat_check.csv       steady-state node-0 occupancy vs budget, per cell
  arm_provenance.csv    the commit each cell's lib was actually built from

STATISTICS.  n=3 per cell.  Everything here reports MEDIAN and MIN-MAX RANGE.
There are deliberately no violins, error bars implying a distribution, or
significance tests -- 3 points do not support them.

THE CHEAT TEST is not a scalar gate.  Large allocations at startup routinely
breach any fixed tolerance, so cheat_check.csv reports steady-state occupancy
with the initial transient excluded, and the numastat plots SHADE the excluded
window rather than dropping it -- a fix that "passes" only by lengthening its
transient must remain visible.
"""

import argparse
import csv
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from nursery_parse import (arm_grace, arm_label, arm_sort_key,  # noqa: E402
                           discover_cells, is_fix_arm, parse_numastat,
                           parse_rebalance, parse_time_file)

import matplotlib                                                    # noqa: E402
matplotlib.use("Agg")
import matplotlib.pyplot as plt                                      # noqa: E402

# Warmup excluded from the steady-state cheat statistic.  Not a tuned constant:
# it is the allocation-burst window CONTEXT.md names, and it is shaded on every
# numastat plot so the reader can see what was excluded and judge it.
DEFAULT_WARMUP_S = 0.0
# Steady state is taken as the final fraction of each run rather than everything
# after a fixed wall-clock warmup.  The allocation burst does not have a
# workload-independent length -- renaissance_naive-bayes settles by ~45s, npb-cpp
# is still descending at ~85s -- so any single constant either clips one
# workload's burst tail into the "steady" window (reporting a >100% cap breach
# that is really the transient) or throws away most of a short run.  A fraction
# scales with the run and needs no per-workload table.
DEFAULT_STEADY_FRAC = 0.5

_FIXED_COLORS = {
    "nursery_base": "#B45309",   # amber - the old allocator, always the control
    "nursery_fix":  "#1D4ED8",   # blue  - ranking/water-fill only, no filter
}
# Grace arms get greens ordered by grace value, so a longer window is a darker
# green and a multi-value grace sweep reads as a sequence rather than a jumble.
_GRACE_COLORS = ["#34D399", "#10B981", "#047857", "#065F46", "#022C22"]


def arm_color(arm, grace_ranks=None):
    if arm in _FIXED_COLORS:
        return _FIXED_COLORS[arm]
    g = arm_grace(arm)
    if g is not None and grace_ranks and g in grace_ranks:
        return _GRACE_COLORS[grace_ranks[g] % len(_GRACE_COLORS)]
    return "#047857" if g is not None else "#666666"


# Populated once in main() from the arms actually present, then read by the
# plotters (which receive summary rows, not cells, so cannot derive it).
GRACE_RANKS = {}


def grace_ranking(cells):
    """Map each distinct grace value present -> its rank, for colour ordering."""
    vals = sorted({arm_grace(c["arm"]) for c in cells
                   if arm_grace(c["arm"]) is not None})
    return {v: i for i, v in enumerate(vals)}

_RE_FASTMEM = re.compile(r"REGENT_FAST_MEMORY=(\d+)\s*([MGmg])")


def fast_mem_mb(cell_dir):
    """Fast-tier budget in MB, from the cell's meta.md.

    run_characterization.sh writes one `... -> REGENT_FAST_MEMORY=<size> ...`
    line per workload in meta.md's Workloads section.  Returns None if absent --
    callers then omit the budget line rather than drawing a wrong one.
    """
    meta = cell_dir / "meta.md"
    if not meta.exists():
        return None
    m = _RE_FASTMEM.search(meta.read_text(errors="replace"))
    if not m:
        return None
    val = float(m.group(1))
    return val * 1024 if m.group(2).upper() == "G" else val


_RE_ARMS_COMMIT = re.compile(r"\*\*ARMS commit:\*\*\s*(\S+)\s*\(branch ([^)]*)\)")


def arms_provenance(cell_dir):
    meta = cell_dir / "meta.md"
    if not meta.exists():
        return ("missing", "missing")
    m = _RE_ARMS_COMMIT.search(meta.read_text(errors="replace"))
    return (m.group(1), m.group(2).strip()) if m else ("unknown", "unknown")


def read_first(paths):
    for p in paths:
        try:
            return p.read_text(errors="replace")
        except OSError:
            continue
    return None


def load(root):
    """Collect every cell into a list of records."""
    cells = []
    for c in discover_cells(root):
        rec = dict(c)
        txt = read_first(c["time_files"])
        rec.update(parse_time_file(txt) if txt else {"wall_s": None,
                                                     "max_rss_kb": None})
        out = read_first(c["stdout_files"])
        rec["rebalance"] = parse_rebalance(out) if out else []
        nst = read_first(c["numastat_files"])
        rec["numastat"] = parse_numastat(nst) if nst else []
        rec["budget_mb"] = fast_mem_mb(c["dir"])
        rec["arms_commit"], rec["arms_branch"] = arms_provenance(c["dir"])
        cells.append(rec)
    return cells


def arm_sort(arm):
    return arm_sort_key(arm)


# ---------------------------------------------------------------- runtime ----
def runtime_summary(cells, outdir):
    by = defaultdict(list)
    for c in cells:
        if c["wall_s"] is not None:
            by[(c["workload"], c["ratio"], c["arm"])].append(c["wall_s"])

    rows = []
    for (w, r, a), vals in sorted(by.items(),
                                  key=lambda kv: (kv[0][0], kv[0][1],
                                                  arm_sort(kv[0][2]))):
        rows.append({
            "workload": w, "ratio": r, "arm": a,
            "n": len(vals),
            "median_s": round(statistics.median(vals), 3),
            "min_s": round(min(vals), 3),
            "max_s": round(max(vals), 3),
        })
    with open(outdir / "runtime_summary.csv", "w", newline="") as fh:
        wtr = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else
                             ["workload", "ratio", "arm", "n", "median_s",
                              "min_s", "max_s"])
        wtr.writeheader()
        wtr.writerows(rows)
    return rows


def plot_runtime(rows, outdir):
    by_w = defaultdict(list)
    for r in rows:
        by_w[r["workload"]].append(r)

    for w, rs in by_w.items():
        ratios = sorted({r["ratio"] for r in rs})
        arms = sorted({r["arm"] for r in rs}, key=arm_sort)
        fig, ax = plt.subplots(figsize=(1.9 * len(ratios) + 3.2, 4.2))
        width = 0.8 / max(len(arms), 1)
        for i, a in enumerate(arms):
            xs, meds, los, his = [], [], [], []
            for j, ratio in enumerate(ratios):
                m = [r for r in rs if r["arm"] == a and r["ratio"] == ratio]
                if not m:
                    continue
                m = m[0]
                xs.append(j + (i - (len(arms) - 1) / 2) * width)
                meds.append(m["median_s"])
                los.append(m["median_s"] - m["min_s"])
                his.append(m["max_s"] - m["median_s"])
            # Bars are the MEDIAN; whiskers are the observed MIN-MAX RANGE of
            # n=3, not a confidence interval.
            ax.bar(xs, meds, width=width * 0.92, color=arm_color(a, GRACE_RANKS),
                   label=arm_label(a), zorder=2)
            ax.errorbar(xs, meds, yerr=[los, his], fmt="none", ecolor="#111",
                        elinewidth=1.1, capsize=3, zorder=3)
        ax.set_xticks(range(len(ratios)))
        ax.set_xticklabels(["%g%s" % (r, "\n(null control)" if r > 1 else "")
                            for r in ratios])
        ax.set_xlabel("fast-tier ratio (fraction of peak RSS)")
        ax.set_ylabel("wall clock (s)")
        ax.set_title("%s — runtime by arm\nbars = median of n=3, whiskers = "
                     "observed min-max (not a CI)" % w, fontsize=10)
        ax.legend(fontsize=8)
        ax.grid(axis="y", alpha=0.3, zorder=0)
        fig.tight_layout()
        fig.savefig(outdir / ("runtime_%s.png" % w), dpi=130)
        plt.close(fig)


# ------------------------------------------------------- granted vs demand ----
def plot_alloc(cells, outdir):
    """Per-region granted (alloc) vs demand (total footprint) over time.

    total_footprint is the cross-arm axis -- the only demand quantity arm A
    defines.  counted_footprint is overlaid as a dashed line for arms B/C only,
    so the gap between the two shows exactly what the grace filter pruned.
    """
    groups = defaultdict(list)
    for c in cells:
        if c["rebalance"]:
            groups[(c["workload"], c["ratio"])].append(c)

    for (w, ratio), cs in sorted(groups.items()):
        # iter1 only: the timelines are near-duplicates across iterations and
        # overplotting three of them hides the structure.
        cs = [c for c in cs if c["iter"] == 1] or cs
        cs.sort(key=lambda c: arm_sort(c["arm"]))
        if not cs:
            continue
        fig, axes = plt.subplots(1, len(cs), figsize=(5.0 * len(cs), 4.4),
                                 sharey=True, squeeze=False)
        for ax, c in zip(axes[0], cs):
            rows = c["rebalance"]
            cids = sorted({r["cluster_id"] for r in rows})
            cmap = plt.get_cmap("tab10")
            for k, cid in enumerate(cids):
                rs = [r for r in rows if r["cluster_id"] == cid]
                t = [r["elapsed_s"] for r in rs]
                col = cmap(k % 10)
                # The rebalancer's snapshots carry the fallback as cluster -1
                # (REBALANCER_FALLBACK_CLUSTER_ID); region 0 is the region id it
                # routes to.  Real clusters are >= 1, so anything <= 0 is the
                # fallback and must be named as such -- it is the whole subject
                # of this campaign and cannot read as just another cluster.
                lbl = "FALLBACK (cluster %d)" % cid if cid <= 0 else "cluster %d" % cid
                ax.plot(t, [r["alloc_mb"] for r in rs], color=col, lw=1.8,
                        label="%s: granted" % lbl)
                ax.plot(t, [r["total_footprint_mb"] for r in rs], color=col,
                        lw=1.0, alpha=0.55, ls=":",
                        label="%s: demand (total)" % lbl)
                cf = [r["counted_footprint_mb"] for r in rs]
                if any(v is not None for v in cf):
                    ax.plot(t, [v if v is not None else float("nan") for v in cf],
                            color=col, lw=1.0, ls="--", alpha=0.9,
                            label="%s: demand (counted)" % lbl)
            if c["budget_mb"]:
                ax.axhline(c["budget_mb"], color="#111", lw=1.0, ls="-.",
                           label="fast-tier budget")
            ax.set_title(arm_label(c["arm"]), fontsize=10)
            ax.set_xlabel("elapsed (s)")
            ax.grid(alpha=0.3)
        axes[0][0].set_ylabel("MB")
        axes[0][-1].legend(fontsize=6, loc="upper right")
        fig.suptitle("%s @ ratio %g — granted vs demand per region"
                     "   (dotted = total footprint, dashed = counted; arm A has "
                     "no counted column)" % (w, ratio), fontsize=10)
        fig.tight_layout(rect=[0, 0, 1, 0.93])
        fig.savefig(outdir / ("alloc_%s_r%g.png" % (w, ratio)), dpi=130)
        plt.close(fig)


# ------------------------------------------------------------- numastat ------
def plot_numastat(cells, outdir, warmup_s, frac):
    groups = defaultdict(list)
    for c in cells:
        if c["numastat"]:
            groups[(c["workload"], c["ratio"])].append(c)

    for (w, ratio), cs in sorted(groups.items()):
        cs = [c for c in cs if c["iter"] == 1] or cs
        cs.sort(key=lambda c: arm_sort(c["arm"]))
        fig, ax = plt.subplots(figsize=(8.6, 4.4))
        for c in cs:
            t = [s["t"] for s in c["numastat"]]
            n0 = [s["node0_mb"] for s in c["numastat"]]
            col = arm_color(c["arm"], GRACE_RANKS)
            ax.plot(t, n0, color=col, lw=1.6,
                    label="%s — node 0 (fast)" % arm_label(c["arm"]))
            n1 = [s["node1_mb"] for s in c["numastat"]]
            ax.plot(t, n1, color=col, lw=1.0, alpha=0.45, ls=":",
                    label="%s — node 1 (slow)" % arm_label(c["arm"]))
        budgets = {c["budget_mb"] for c in cs if c["budget_mb"]}
        for b in budgets:
            ax.axhline(b, color="#111", lw=1.2, ls="-.",
                       label="REGENT_FAST_MEMORY = %.0f MB" % b)
        # Shade, do not drop, the excluded warmup: a fix that only "passes" the
        # steady-state check by having a longer allocation transient must stay
        # visible to the reader.
        shade_to = max(steady_start(c, warmup_s, frac) for c in cs)
        ax.axvspan(0, shade_to, color="#999", alpha=0.16, zorder=0)
        # Blended transform: x in data units (so the label tracks the shaded
        # window), y in axes fraction (so it sits just under the top frame
        # regardless of the data range).
        ax.text(shade_to, 0.97, "  excluded from\n  steady-state check",
                transform=ax.get_xaxis_transform(), fontsize=7, va="top",
                color="#444")
        ax.set_xlabel("elapsed (s)")
        ax.set_ylabel("resident (MB)")
        ax.set_title("%s @ ratio %g — NUMA residency by arm" % (w, ratio),
                     fontsize=10)
        ax.legend(fontsize=6.5)
        ax.grid(alpha=0.3)
        fig.tight_layout()
        fig.savefig(outdir / ("numastat_%s_r%g.png" % (w, ratio)), dpi=130)
        plt.close(fig)


def steady_start(cell, warmup_s, frac):
    """First timestamp counted as steady state for this cell.

    max(absolute warmup, fraction of the run).  Returned per cell so a long and
    a short workload are each measured over their own tail.
    """
    if not cell["numastat"]:
        return warmup_s
    t_max = max(s["t"] for s in cell["numastat"])
    return max(warmup_s, frac * t_max)


def cheat_check(cells, outdir, warmup_s, frac):
    rows = []
    for c in sorted(cells, key=lambda c: (c["workload"], c["ratio"],
                                          arm_sort(c["arm"]), c["iter"])):
        t0 = steady_start(c, warmup_s, frac)
        ss = [s for s in c["numastat"] if s["t"] >= t0]
        if not ss:
            continue
        peak = max(s["node0_mb"] for s in ss)
        mean = sum(s["node0_mb"] for s in ss) / len(ss)
        b = c["budget_mb"]
        rows.append({
            "workload": c["workload"], "ratio": c["ratio"], "arm": c["arm"],
            "iter": c["iter"],
            "steady_from_s": round(t0, 1),
            "budget_mb": round(b, 1) if b else "",
            "steady_peak_node0_mb": round(peak, 1),
            "steady_mean_node0_mb": round(mean, 1),
            "peak_over_budget_pct": round(100.0 * (peak - b) / b, 2) if b else "",
            "transient_peak_node0_mb": round(
                max([s["node0_mb"] for s in c["numastat"]
                     if s["t"] < t0] or [0]), 1),
        })
    fields = ["workload", "ratio", "arm", "iter", "steady_from_s", "budget_mb",
              "steady_peak_node0_mb", "steady_mean_node0_mb",
              "peak_over_budget_pct", "transient_peak_node0_mb"]
    with open(outdir / "cheat_check.csv", "w", newline="") as fh:
        wtr = csv.DictWriter(fh, fieldnames=fields)
        wtr.writeheader()
        wtr.writerows(rows)
    return rows


def provenance(cells, outdir):
    """Per-cell record of which commit each arm's lib was built from.

    This is the audit for the shared-lib-cache trap: if nursery_base cells and
    nursery_fix cells report the SAME commit, the arms were not different code
    and the campaign is void.
    """
    rows = [{"workload": c["workload"], "arm": c["arm"], "ratio": c["ratio"],
             "iter": c["iter"], "arms_commit": c["arms_commit"],
             "arms_branch": c["arms_branch"]}
            for c in sorted(cells, key=lambda c: (c["workload"],
                                                  arm_sort(c["arm"]),
                                                  c["ratio"], c["iter"]))]
    with open(outdir / "arm_provenance.csv", "w", newline="") as fh:
        wtr = csv.DictWriter(fh, fieldnames=["workload", "arm", "ratio", "iter",
                                             "arms_commit", "arms_branch"])
        wtr.writeheader()
        wtr.writerows(rows)

    # Normalise before comparing.  Commit strings reach this file at two
    # different lengths -- `git rev-parse --short` gives 9 chars, the
    # .arm_version stamp gives 12 -- so a raw set intersection silently fails to
    # match df5cb39b1 against df5cb39b159b and reports "no collision" for two
    # arms sitting on the SAME commit.  That is the audit failing open, the one
    # way it must never fail.
    def norm(c):
        return c[:9] if c not in ("unknown", "missing") else c

    by_arm = defaultdict(set)
    for r in rows:
        by_arm[r["arm"]].add(norm(r["arms_commit"]))
    base = by_arm.get("nursery_base", set())
    fix = set()
    for a, commits in by_arm.items():
        if is_fix_arm(a):
            fix |= commits
    shared = (base & fix) - {"unknown", "missing"}
    if shared:
        print("  !! ARM PROVENANCE COLLISION: base and fix arms both report "
              "commit(s) %s" % ", ".join(sorted(shared)), file=sys.stderr)
        print("     The arms were built from the SAME source -- most likely a "
              "shared LIB_CACHE_DIR. Results are void.", file=sys.stderr)
        return False
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results_root", help="copied-back tree, e.g. ./sweep_results_nursery_abc")
    ap.add_argument("-o", "--outdir", default="./nursery_report")
    ap.add_argument("--warmup", type=float, default=DEFAULT_WARMUP_S,
                    help="absolute seconds excluded from the steady-state check; "
                         "a floor under --steady-frac (default: %(default)s)")
    ap.add_argument("--steady-frac", type=float, default=DEFAULT_STEADY_FRAC,
                    help="measure steady state over the final fraction of each "
                         "run (default: %(default)s). Always shaded on the plots.")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    cells = load(args.results_root)
    global GRACE_RANKS
    GRACE_RANKS = grace_ranking(cells)
    if not cells:
        print("No cells found under %s" % args.results_root, file=sys.stderr)
        print("Expected <root>/<workload>/nursery_*/peak_rss_*/iter*_*/",
              file=sys.stderr)
        return 1
    print("Loaded %d cells across %d workload(s)"
          % (len(cells), len({c['workload'] for c in cells})))

    clean = provenance(cells, outdir)
    rows = runtime_summary(cells, outdir)
    plot_runtime(rows, outdir)
    plot_alloc(cells, outdir)
    plot_numastat(cells, outdir, args.warmup, args.steady_frac)
    cc = cheat_check(cells, outdir, args.warmup, args.steady_frac)

    over = [r for r in cc if r["peak_over_budget_pct"] != ""
            and r["peak_over_budget_pct"] > 0]
    print("Wrote %s" % outdir)
    print("  runtime_summary.csv  %d (workload,ratio,arm) groups" % len(rows))
    print("  cheat_check.csv      %d cells, %d with steady-state node-0 above "
          "budget" % (len(cc), len(over)))
    if over:
        print("  (inspect the numastat plots before calling these violations -- "
              "see the module docstring)")
    if not clean:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
