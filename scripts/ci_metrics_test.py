"""Summarize a small recorded set of CI runs."""
import io
from contextlib import redirect_stdout
import unittest

from ci_metrics import max_concurrent, median, parse, print_summary, summarize

RUN = {"id": 1, "created_at": "2026-01-01T00:00:00Z", "conclusion": "success", "run_attempt": 1}


def job(name, created, started, completed, labels=("ubuntu-latest",), conclusion="success", steps=()):
    stamp = lambda seconds: None if seconds is None else f"2026-01-01T00:{seconds // 60:02d}:{seconds % 60:02d}Z"
    return {"name": name, "labels": list(labels), "conclusion": conclusion, "created_at": stamp(created),
            "started_at": stamp(started), "completed_at": stamp(completed), "steps": list(steps)}


JOBS = [
    job("Changed files", 0, 5, 20),
    job("App (macOS, 1/3)", 20, 30, 330, ("xcode-27",), steps=[
        {"name": "Run make swift-test", "conclusion": "success", "started_at": "2026-01-01T00:01:00Z", "completed_at": "2026-01-01T00:04:00Z"}]),
    job("App (macOS, 2/3)", 20, 40, 400, ("xcode-27",)),
    job("Docs", 20, None, None, conclusion="skipped"),
]


class CiMetricsTests(unittest.TestCase):
    def test_measures_signal_makespan_queue_slots_and_skips(self):
        summary = summarize([RUN], {1: JOBS}, ("xcode",))
        self.assertEqual(summary["first_signal_s"]["median"], 20)
        self.assertEqual(summary["makespan_s"]["median"], 400)
        self.assertEqual(summary["queue_s"]["median"], 10)
        self.assertEqual(summary["macos_max_concurrent"], 2)
        self.assertAlmostEqual(summary["macos_slot_min"]["median"], (300 + 360) / 60)
        self.assertEqual(summary["skip_rate"], 0.25)
        self.assertEqual(summary["jobs"]["App (macOS, 1/3)"]["median"], 300)
        self.assertEqual(summary["steps"]["App (macOS, 1/3) / Run make swift-test"]["median"], 180)

    def test_a_cancelled_run_does_not_count_toward_the_times(self):
        cancelled = dict(RUN, id=2, conclusion="cancelled")
        summary = summarize([RUN, cancelled], {1: JOBS, 2: JOBS[:1]}, ("xcode",))
        self.assertEqual((summary["runs"], summary["cancelled"], summary["makespan_s"]["median"]), (2, 1, 400))

    def test_helpers(self):
        self.assertEqual(median([4, 1, 3, 2]), 2.5)
        self.assertEqual(max_concurrent([(0, 10), (5, 15), (10, 20)]), 2)
        self.assertEqual(parse("2026-01-01T00:00:10Z") - parse("2026-01-01T00:00:00Z"), 10)

    def test_prints_the_summary(self):
        output = io.StringIO()
        with redirect_stdout(output):
            print_summary(summarize([RUN], {1: JOBS}, ("xcode",)))
        self.assertIn("Makespan: median 6.7 min", output.getvalue())
        self.assertIn("max concurrent macOS jobs: 2", output.getvalue())


if __name__ == "__main__":
    unittest.main()
