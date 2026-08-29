"""Fixture tests for nursery_parse.

The fixtures reproduce the exact ostream sequences in the regent source --
core/regent.cpp (Rebalance header + cluster line), rebalancer_dram_sens.cpp
(log_cluster), workloads/run.sh (numastat block), /usr/bin/time -v -- so a
format change on either side breaks a test here rather than silently producing
a plausible, wrong plot.

Run:  python3 scripts/regent_nursery/test_nursery_parse.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from nursery_parse import parse_rebalance, parse_time_file, parse_numastat  # noqa: E402

ARM_A = """[Regent] Rebalance (dram_sens): uncond=0MB adjusted_budget=1024.5MB window=2.01s
  Cluster 0 | hot=12/900 | pebs=41 mar=20 | intra=0.0031 inter=20 sens=0.062 | alloc=0 MB | footprint=1800 MB
  Cluster 1 | hot=300/400 | pebs=910 mar=452 | intra=0.021 inter=452 sens=9.5 | alloc=800 MB | footprint=800 MB
[Regent] Rebalance (dram_sens): uncond=0MB adjusted_budget=1024.5MB window=2.00s
  Cluster 0 | hot=15/905 | pebs=50 mar=25 | intra=0.0034 inter=25 sens=0.085 | alloc=0 MB | footprint=1810 MB
"""

ARM_C = """[Regent] Rebalance (dram_sens): uncond=0MB adjusted_budget=1024.5MB window=2.01s
  Cluster 0 | hot=12/900 counted=140/900 | pebs=41 mar=20 | intra=0.0197 inter=20 sens=0.39 | alloc=280 MB | footprint=280/1800 MB
  Cluster 1 | hot=300/400 counted=380/400 | pebs=910 mar=452 | intra=0.021 inter=452 sens=9.5 | alloc=744 MB | footprint=760/800 MB
"""

NOISE = """[Regent] Rebalance (dram_sens): uncond=64MB adjusted_budget=960MB window=2.0s
  Cluster 2 | UNCONDITIONAL=64 MB
  Cluster 3 | PRIORITY demand=128 MB alloc=100 MB
  Cluster 1 | hot=1/2 counted=2/2 | pebs=1 mar=1 | alloc=10 MB | footprint=20/30 MB
"""

NUMA = """=== Thu Aug 20 08:15:01 PM CDT 2026 ===

Per-node process memory usage (in MBs) for PID 1234 (graph500)
                           Node 0          Node 1           Total
                  --------------- --------------- ---------------
Heap                       100.00          200.00          300.00
----------------  --------------- --------------- ---------------
Total                     1024.00          512.00         1536.00

Per-node system memory usage (in MBs):
Total                    99999.00        88888.00       188887.00
=== Thu Aug 20 08:15:02 PM CDT 2026 ===

Per-node process memory usage (in MBs) for PID 1234 (graph500)
Total                     1000.00          600.00         1600.00
"""


def test_arm_a_single_valued_footprint_is_total():
    """Arm A prints one footprint value; it is the TOTAL, and counted is absent.

    Assigning it to counted (or defaulting counted to 0) is the bug this asserts
    against -- it would make arm A look like it had zero demand.
    """
    rows = parse_rebalance(ARM_A)
    assert rows[0]["total_footprint_mb"] == 1800.0
    assert rows[0]["counted_footprint_mb"] is None
    assert rows[0]["counted_profiles"] is None
    assert rows[0]["alloc_mb"] == 0.0
    assert rows[0]["mar"] == 20
    assert rows[0]["hot"] == 12 and rows[0]["total_profiles"] == 900


def test_arm_c_two_valued_footprint_splits_counted_and_total():
    rows = parse_rebalance(ARM_C)
    assert rows[0]["counted_footprint_mb"] == 280.0
    assert rows[0]["total_footprint_mb"] == 1800.0
    assert rows[0]["counted_profiles"] == 140


def test_cross_arm_axis_agrees():
    """The whole point: compared on total_footprint the arms are commensurate.

    A naive `footprint=(\\d+)` parser reads 1800 (A) vs 280 (C) and reports an
    84% demand collapse that never happened.
    """
    a = parse_rebalance(ARM_A)[0]
    c = parse_rebalance(ARM_C)[0]
    assert a["total_footprint_mb"] == c["total_footprint_mb"] == 1800.0


def test_elapsed_accumulates_window_seconds():
    rows = parse_rebalance(ARM_A)
    assert rows[2]["tick"] == 1
    assert abs(rows[2]["elapsed_s"] - 4.01) < 1e-9


def test_unconditional_and_priority_lines_skipped():
    rows = parse_rebalance(NOISE)
    assert len(rows) == 1 and rows[0]["cluster_id"] == 1


def test_wall_clock_both_spellings():
    """h:mm:ss must not parse as m:ss -- that would shrink a runtime 60x."""
    t = parse_time_file("\tElapsed (wall clock) time (h:mm:ss or m:ss): 2:03.45\n"
                        "\tMaximum resident set size (kbytes): 8192\n")
    assert abs(t["wall_s"] - 123.45) < 1e-9
    assert t["max_rss_kb"] == 8192
    t = parse_time_file("\tElapsed (wall clock) time (h:mm:ss or m:ss): 1:02:03\n")
    assert abs(t["wall_s"] - 3723.0) < 1e-9


def test_numastat_uses_per_process_total_only():
    """run.sh appends `numastat -p PID` AND `numastat -mn`; only the first
    Total per block is the process's."""
    s = parse_numastat(NUMA)
    assert len(s) == 2
    assert s[0]["node0_mb"] == 1024.0 and s[0]["node1_mb"] == 512.0
    assert s[1]["node0_mb"] == 1000.0
    assert s[1]["t"] == 1.0


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if not name.startswith("test_") or not callable(fn):
            continue
        try:
            fn()
            print("PASS  %s" % name)
        except AssertionError as e:
            failed += 1
            print("FAIL  %s: %s" % (name, e))
    print("\n%s" % ("all passed" if not failed else "%d FAILED" % failed))
    sys.exit(1 if failed else 0)
