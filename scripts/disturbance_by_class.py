#!/usr/bin/env python3
"""Attribute what scripts/disturbance_sampler.swift saw to the test classes of a serial xcodebuild run.

  disturbance_by_class.py XCODEBUILD.log SAMPLES.jsonl

xcodebuild prints "Test Suite 'X' started at <local time>" only with -parallel-testing-enabled NO; each sample inside
a class's window counts for that class. Prints one row per class that disturbed anything, worst first.
"""
import json
import re
import sys
from collections import defaultdict
from datetime import datetime

SUITE = re.compile(r"Test Suite '(\w+)' (started|passed|failed) at (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)")


def windows(log):
    open_at, spans = {}, []
    for line in log:
        m = SUITE.search(line)
        if not m or m.group(1) in ("All tests", "Selected tests") or m.group(1).endswith(".xctest"):
            continue
        t = datetime.fromisoformat(m.group(3)).timestamp()
        if m.group(2) == "started":
            open_at[m.group(1)] = t
        elif m.group(1) in open_at:
            spans.append((m.group(1), open_at.pop(m.group(1)), t))
    return spans


def main(log_path, samples_path):
    with open(log_path) as f:
        spans = windows(f)
    samples = []
    with open(samples_path) as f:
        samples = [json.loads(line) for line in f]
    rows = []
    for name, begin, end in spans:
        inside = [s for s in samples if "visible" in s and begin <= s["wall"] <= end]
        visible, ghosts = set(), set()
        for s in inside:
            visible.update(w[0] for w in s["shown"])
            ghosts.update(w[0] for w in s["ghosts"])
        acts = [s for s in samples if s.get("event") == "activate" and begin <= s["wall"] <= end and "tests" in s["app"]]
        rows.append({
            "class": name, "s": round(end - begin, 1),
            "visible": len(visible), "visibleS": round(sum(1 for s in inside if s["visible"]) * 0.2, 1),
            "ghosts": len(ghosts), "focus": len(acts),
            "jumps": sum(1 for s in inside if s["jump"]), "synthetic": sum(1 for s in inside if s["synthetic"]),
            "peakWin": max((s["hostWindows"] for s in inside), default=0),
            "cores": round(max((s["testCores"] for s in inside), default=0), 1),
            "spinMax": round(max((s["spinMs"] for s in inside), default=0), 1),
        })
    rows.sort(key=lambda r: (-(r["focus"] * 20 + r["synthetic"] * 20 + r["visible"] * 5 + r["ghosts"] * 2), -r["s"]))
    cols = ["class", "s", "visible", "visibleS", "ghosts", "focus", "jumps", "synthetic", "peakWin", "cores", "spinMax"]
    print(" ".join(f"{c:>9}" if c != "class" else f"{c:<44}" for c in cols))
    for r in rows:
        print(" ".join(f"{r[c]:>9}" if c != "class" else f"{r[c]:<44}" for c in cols))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
