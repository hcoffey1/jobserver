"""
Parsers for the fallback-nursery A/B/C campaign (regent ADR-0015).

Kept separate from the plotting driver so the format-sensitive logic can be
exercised on fixtures without a matplotlib import.

THE FORMAT TRAP THIS FILE EXISTS TO CONTAIN
-------------------------------------------
ADR-0015 changed the `[Regent] Rebalance` per-cluster line, and changed the
MEANING of a field rather than only adding one:

  arm A (hjcoffey/regent):
    Cluster 0 | hot=12/900 | pebs=41 mar=20 | alloc=128 MB | footprint=1800 MB
                                                                       ^ TOTAL
  arm B/C (fallback_nursery):
    Cluster 0 | hot=12/900 counted=140/900 | pebs=41 mar=20 | alloc=128 MB | footprint=280/1800 MB
                                                                            ^COUNTED ^TOTAL

So a parser matching `footprint=(\\d+)` reads arm A's TOTAL and arm B/C's
COUNTED and reports a demand collapse that is pure parsing artifact.  Here the
single-valued form is always assigned to `total_footprint_mb` and
`counted_footprint_mb` is left None -- never conflated.

`total_footprint_mb` is therefore the only demand quantity defined in all three
arms, which is why it, not `counted`, is the cross-arm axis.
"""

import re
from datetime import datetime
from pathlib import Path

# --- [Regent] Rebalance --------------------------------------------------------
# The rebalancer injects its own `log_cluster` text between `mar=` and `| alloc=`,
# so every field is matched by name rather than by position.
_RE_HEADER = re.compile(
    r"\[Regent\]\s+Rebalance\s+\((?P<rebalancer>[^)]*)\):"
    r".*?adjusted_budget=(?P<budget>[\d.]+)MB"
    r".*?window=(?P<window>[\d.]+)s"
)
_RE_CLUSTER = re.compile(r"^\s*Cluster\s+(?P<cid>-?\d+)\s*\|")
_RE_HOT = re.compile(r"hot=(?P<hot>\d+)/(?P<tot>\d+)")
_RE_COUNTED = re.compile(r"counted=(?P<counted>\d+)/(?P<tot>\d+)")
_RE_MAR = re.compile(r"mar=(?P<mar>-?\d+)")
_RE_ALLOC = re.compile(r"alloc=(?P<alloc>-?\d+)\s*MB")
# Two-valued form FIRST so `footprint=280/1800` never matches the single-valued
# alternative and silently drops the total.
_RE_FOOTPRINT2 = re.compile(r"footprint=(?P<c>-?\d+)/(?P<t>-?\d+)\s*MB")
_RE_FOOTPRINT1 = re.compile(r"footprint=(?P<t>-?\d+)\s*MB")


def parse_rebalance(text):
    """Parse Rebalance ticks out of a cell's *_stdout.txt.

    Returns a list of row dicts:
      tick, elapsed_s, cluster_id, hot, total_profiles, counted_profiles,
      mar, alloc_mb, counted_footprint_mb, total_footprint_mb, budget_mb

    `elapsed_s` accumulates the per-tick `window=` values, giving a real time
    axis rather than a tick index (windows are not guaranteed uniform).
    `counted_*` are None for arm A, which has no such column at all -- callers
    must treat None as "not measured", never as zero.
    """
    rows = []
    tick = -1
    elapsed = 0.0
    budget = None
    for line in text.splitlines():
        h = _RE_HEADER.search(line)
        if h:
            tick += 1
            elapsed += float(h.group("window"))
            budget = float(h.group("budget"))
            continue
        if tick < 0:
            continue
        c = _RE_CLUSTER.match(line)
        if not c:
            continue
        # UNCONDITIONAL / PRIORITY lines are also "Cluster N |" but carry no
        # cooperative allocation fields; skip anything without alloc+footprint.
        m_alloc = _RE_ALLOC.search(line)
        m_f2 = _RE_FOOTPRINT2.search(line)
        m_f1 = None if m_f2 else _RE_FOOTPRINT1.search(line)
        if not m_alloc or not (m_f2 or m_f1):
            continue
        m_hot = _RE_HOT.search(line)
        m_cnt = _RE_COUNTED.search(line)
        m_mar = _RE_MAR.search(line)
        rows.append({
            "tick": tick,
            "elapsed_s": elapsed,
            "cluster_id": int(c.group("cid")),
            "hot": int(m_hot.group("hot")) if m_hot else None,
            "total_profiles": int(m_hot.group("tot")) if m_hot else None,
            "counted_profiles": int(m_cnt.group("counted")) if m_cnt else None,
            "mar": int(m_mar.group("mar")) if m_mar else None,
            "alloc_mb": float(m_alloc.group("alloc")),
            "counted_footprint_mb": float(m_f2.group("c")) if m_f2 else None,
            "total_footprint_mb": float((m_f2 or m_f1).group("t")),
            "budget_mb": budget,
        })
    return rows


# --- /usr/bin/time -v ----------------------------------------------------------
# The label itself contains colons -- "Elapsed (wall clock) time (h:mm:ss or
# m:ss): 2:03.45" -- so the value cannot be found by scanning to the first
# colon.  Match the whole line and take the final whitespace-free token: the
# lazy `.*?` combined with the `(\S+)\s*$` anchor lands on the last colon whose
# remainder is a single token, i.e. the value.
_RE_WALL = re.compile(r"^\s*Elapsed \(wall clock\) time.*?:\s*(\S+)\s*$", re.M)
_RE_MAXRSS = re.compile(r"Maximum resident set size \(kbytes\):\s*(\d+)")


def parse_time_file(text):
    """Return {'wall_s': float, 'max_rss_kb': int} from `/usr/bin/time -v`.

    Wall clock is emitted as either `h:mm:ss` or `m:ss(.ss)`, so the hour group
    is optional -- a runtime crossing an hour boundary would otherwise parse as
    minutes and silently shrink by 60x.
    """
    out = {"wall_s": None, "max_rss_kb": None}
    m = _RE_WALL.search(text)
    if m:
        parts = m.group(1).split(":")
        try:
            if len(parts) == 3:      # h:mm:ss
                out["wall_s"] = (float(parts[0]) * 3600 + float(parts[1]) * 60
                                 + float(parts[2]))
            elif len(parts) == 2:    # m:ss(.ss)
                out["wall_s"] = float(parts[0]) * 60 + float(parts[1])
        except ValueError:
            out["wall_s"] = None
    m = _RE_MAXRSS.search(text)
    if m:
        out["max_rss_kb"] = int(m.group(1))
    return out


# --- numastat ------------------------------------------------------------------
# workloads/run.sh appends, once a second:
#     === <date> ===
#     <numastat -p PID>      <- per-PROCESS, MB, ends in a "Total" row
#     <numastat -mn>         <- system-wide, also contains "Total" rows
# Only the FIRST Total in each block is the per-process one we want.
_RE_BLOCK = re.compile(r"^=== (.+) ===\s*$")
_RE_TOTAL = re.compile(r"^Total\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*$")


def parse_numastat(text):
    """Return per-second [{t, node0_mb, node1_mb, total_mb}] for the workload PID.

    `t` is seconds since the first sample.  Blocks where the process had already
    exited (numastat prints no per-process table) are skipped rather than
    recorded as zero -- a zero there would look like the allocator released
    everything at the end.
    """
    samples = []
    t0 = None
    cur_ts = None
    seen_total = False
    for line in text.splitlines():
        b = _RE_BLOCK.match(line)
        if b:
            cur_ts = b.group(1).strip()
            seen_total = False
            continue
        if seen_total or cur_ts is None:
            continue
        m = _RE_TOTAL.match(line)
        if not m:
            continue
        seen_total = True
        ts = None
        for fmt in ("%a %b %d %I:%M:%S %p %Z %Y", "%a %b %d %H:%M:%S %Z %Y",
                    "%a %d %b %Y %I:%M:%S %p %Z"):
            try:
                ts = datetime.strptime(cur_ts, fmt)
                break
            except ValueError:
                continue
        if ts is None:
            t = float(len(samples))          # fall back to sample index
        else:
            if t0 is None:
                t0 = ts
            t = (ts - t0).total_seconds()
        samples.append({
            "t": t,
            "node0_mb": float(m.group(1)),
            "node1_mb": float(m.group(2)),
            "total_mb": float(m.group(3)),
        })
    return samples


# --- cell discovery -------------------------------------------------------------
_RE_CELL = re.compile(
    r"(?P<arm>nursery_[a-z0-9_]+)/peak_rss_(?P<ratio>[\d.]+)/iter(?P<iter>\d+)_"
)

_RE_GRACE_ARM = re.compile(r"^nursery_fix_grace(\d+)$")


def arm_grace(arm):
    """Grace value in ticks (== seconds) for a grace arm, else None.

    The value lives in the arm NAME, so it is recoverable from the results path
    alone -- no need to know which env vars a campaign was dispatched with.
    """
    m = _RE_GRACE_ARM.match(arm)
    return int(m.group(1)) if m else None


def arm_label(arm):
    if arm == "nursery_base":
        return "control (pre-ADR-0015)"
    if arm == "nursery_fix":
        return "fix, grace off"
    g = arm_grace(arm)
    return "fix, grace=%ds" % g if g is not None else arm


def arm_sort_key(arm):
    """control first, then grace-off, then grace arms ascending by value."""
    if arm == "nursery_base":
        return (0, 0)
    if arm == "nursery_fix":
        return (1, 0)
    g = arm_grace(arm)
    return (2, g) if g is not None else (3, 0)


def is_fix_arm(arm):
    """Any arm built from the fallback_nursery tree (i.e. not the control)."""
    return arm != "nursery_base" and arm.startswith("nursery_")


def discover_cells(root):
    """Yield one dict per completed cell under a copied-back results tree.

    Layout: <root>/<workload>/<arm>/peak_rss_<ratio>/iter<N>_<ts>/<wdir>/...
    Files are located by suffix glob rather than by reconstructing the
    <suite>_<workload>_<policy>_<DRAMSIZE>_iter<N> basename, which depends on
    runtime values (policy label, DRAMSIZE) this side cannot reliably rebuild.
    """
    root = Path(root)
    for iter_dir in sorted(root.glob("*/nursery_*/peak_rss_*/iter*_*")):
        if not iter_dir.is_dir():
            continue
        m = _RE_CELL.search(str(iter_dir) + "/")
        if not m:
            continue
        rel = iter_dir.relative_to(root)
        yield {
            "workload": rel.parts[0],
            "arm": m.group("arm"),
            "ratio": float(m.group("ratio")),
            "iter": int(m.group("iter")),
            "dir": iter_dir,
            "time_files": sorted(iter_dir.rglob("*_time.txt")),
            "stdout_files": sorted(iter_dir.rglob("*_stdout.txt")),
            "numastat_files": sorted(iter_dir.rglob("numastat*_iter*.txt")),
        }
