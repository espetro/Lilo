#!/usr/bin/env python3
"""Tests the probe's pure parts (percentiles, token estimate, payload summarising), without a bridge or Lilo."""

import importlib.util
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("probe", HERE / "probe.py")
probe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(probe)


class PercentileTests(unittest.TestCase):
    def test_empty_is_none(self):
        self.assertIsNone(probe.percentile([], 50))

    def test_single_value(self):
        self.assertEqual(probe.percentile([0.42], 50), 0.42)
        self.assertEqual(probe.percentile([0.42], 90), 0.42)

    def test_nearest_rank(self):
        values = [0.1, 0.2, 0.3, 0.4, 0.5]
        self.assertEqual(probe.percentile(values, 50), 0.3)
        self.assertEqual(probe.percentile(values, 90), 0.5)
        self.assertEqual(probe.percentile(values, 100), 0.5)
        self.assertEqual(probe.percentile(values, 0), 0.1)

    def test_unsorted_input(self):
        self.assertEqual(probe.percentile([5, 1, 3], 50), 3)


class TokenEstimateTests(unittest.TestCase):
    def test_chars_over_four(self):
        self.assertEqual(probe.est_tokens("x" * 400), 100)
        self.assertEqual(probe.est_tokens(""), 0)
        self.assertEqual(probe.est_tokens("abc"), 0)


class SummaryTests(unittest.TestCase):
    def test_ms_summary_skips_failures(self):
        stats = probe.ms_summary([(0.010, 100, False), (0.020, 200, False), (90.0, 0, True)])
        self.assertEqual(stats["p50_ms"], 10.0)
        self.assertEqual(stats["p90_ms"], 20.0)
        self.assertEqual(stats["max_ms"], 20.0)
        self.assertEqual(stats["errors"], 1)

    def test_ms_summary_all_failed(self):
        stats = probe.ms_summary([(1.0, 0, True)])
        self.assertEqual(stats["p50_ms"], 0.0)
        self.assertEqual(stats["errors"], 1)

    def test_tools_summary_sizes_and_sorts(self):
        result = {"tools": [
            {"name": "small", "description": "tiny"},
            {"name": "big", "description": "x" * 400},
            {"name": "mid", "description": "y" * 40},
        ]}
        raw = '{"tools":[]}'
        summary = probe.tools_summary(result, raw)
        self.assertEqual(summary["bytes"], len(raw.encode()))
        self.assertEqual(summary["est_tokens"], len(raw) // 4)
        self.assertEqual([t["name"] for t in summary["tools"]], ["big", "mid", "small"])
        self.assertEqual(summary["tools"][0]["description_chars"], 400)

    def test_tools_summary_empty(self):
        summary = probe.tools_summary({}, "{}")
        self.assertEqual(summary["tools"], [])


if __name__ == "__main__":
    unittest.main()
