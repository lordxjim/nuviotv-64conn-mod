#!/usr/bin/env python3
"""compare-tests.py — verdict for the patch test jobs.

Compares JUnit XML results of the patched run against the unpatched baseline
run and fails only when the patched tree fails tests that the baseline passes
(true regressions). Pre-existing upstream failures (same tests failing on both
sides) are tolerated and reported.

Usage: python3 compare-tests.py <patched-xml-dir> <baseline-xml-dir>
"""
import glob
import os
import sys
import xml.etree.ElementTree as ET


def collect(xml_dir):
    """Return (set_of_failed_ids, set_of_total_ids, list_of_xml_files)."""
    failed, total, files = set(), set(), []
    for path in sorted(glob.glob(os.path.join(xml_dir, "**", "*.xml"), recursive=True)):
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            continue  # partial write from a killed fork; skip
        files.append(path)
        for tc in root.iter("testcase"):
            tid = f"{tc.get('classname')}::{tc.get('name')}"
            total.add(tid)
            if tc.find("failure") is not None or tc.find("error") is not None:
                failed.add(tid)
    return failed, total, files


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    patched_dir, baseline_dir = sys.argv[1], sys.argv[2]

    p_fail, p_total, p_files = collect(patched_dir)
    b_fail, b_total, b_files = collect(baseline_dir)

    print(f"patched : {len(p_files)} xml, {len(p_total)} tests, {len(p_fail)} failed")
    print(f"baseline: {len(b_files)} xml, {len(b_total)} tests, {len(b_fail)} failed")

    if not p_files:
        print("\nVERDICT: FAIL — no patched test results. Open the 'Unit tests (patched)' job and check which step is red:")
        print("  - red 'Apply 256-connection patch'      → upstream moved past the patch's authored base (re-run with upstream_ref=5b38442d7)")
        print("  - red 'Compile test sources (patched)'  → the patch breaks test compilation; the Kotlin error is in that step's log")
        print("  - job green but 0 xml                   → gradle could not download dependencies (e.g. Maven Central 429); see the test step log")
        return 1
    if not b_files:
        print("\nVERDICT: FAIL — no baseline test results (baseline build broke; inspect job log)")
        return 1

    regressions = sorted(p_fail - b_fail)
    pre_existing = sorted(p_fail & b_fail)
    fixed = sorted(b_fail - p_fail)

    if pre_existing:
        print(f"\npre-existing upstream failures (fail on BOTH sides, tolerated): {len(pre_existing)}")
        for t in pre_existing:
            print(f"  ~ {t}")
    if fixed:
        print(f"\nfixed by the patch (fail only on baseline): {len(fixed)}")
        for t in fixed:
            print(f"  + {t}")

    if regressions:
        print(f"\nREGRESSIONS — fail ONLY with the patch (must fix): {len(regressions)}")
        for t in regressions:
            print(f"  ! {t}")
        print("\nVERDICT: FAIL — patch introduces test regressions")
        return 1

    print(f"\nVERDICT: PASS — no patch regressions ({len(p_total)} tests compared)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
