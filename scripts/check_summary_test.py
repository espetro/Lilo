"""Run checks quietly and report one line each."""
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest

import check_summary

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check_summary.py")


class CheckSummaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.logs = os.path.join(self.directory.name, "logs")
        os.makedirs(self.logs)
        self.metrics = os.path.join(self.directory.name, "metrics.jsonl")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(("LILO_CHECK_", "LILO_METRICS"))}
        self.env["LILO_METRICS_FILE"] = self.metrics

    def run_check(self, name, shell, **env):
        return subprocess.run([sys.executable, SCRIPT, "run", name, self.logs, "--", "/bin/sh", "-c", shell],
                              env=dict(self.env, **env), cwd=self.directory.name).returncode

    def report(self, names, as_json=False):
        out = io.StringIO()
        code = check_summary.report(self.logs, names, as_json, out)
        return code, out.getvalue()

    def records(self):
        with open(self.metrics, encoding="utf-8") as file:
            return [json.loads(line) for line in file]

    def test_a_passing_check_is_one_line_and_its_log_is_not_printed(self):
        self.assertEqual(self.run_check("lint", "echo noisy; echo more"), 0)
        code, text = self.report(["lint"])
        lines = text.splitlines()
        self.assertEqual(code, 0)
        self.assertRegex(lines[0], r"^ok  lint \d+\.\ds$")
        self.assertEqual(lines[1], f"1 checks, 0 failed, {len(lines[0]) + 1} bytes printed above")
        self.assertNotIn("noisy", text)

    def test_a_failing_check_prints_its_full_log_after_the_lines_and_keeps_the_exit_status(self):
        self.assertEqual(self.run_check("lint", "echo fine"), 0)
        self.assertEqual(self.run_check("test", "echo first; echo second >&2; exit 3"), 3)
        code, text = self.report(["lint", "test"])
        self.assertEqual(code, 1)
        lines = text.splitlines()
        self.assertRegex(lines[0], r"^ok  lint ")
        self.assertRegex(lines[1], r"^FAIL test ")
        self.assertIn("== test ==\nfirst\nsecond\n", text)
        self.assertNotIn("fine", text)
        self.assertRegex(lines[-1], r"^2 checks, 1 failed, \d+ bytes printed above$")
        self.assertEqual(int(lines[-1].split()[4]), len(text.encode()) - len(lines[-1].encode()) - 1)

    def test_json_prints_one_object_per_check_with_a_tail_only_when_failed(self):
        self.run_check("lint", "echo fine")
        self.run_check("test", "seq 1 30; exit 1")
        code, text = self.report(["lint", "test"], as_json=True)
        ok, failed = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(code, 1)
        self.assertEqual((ok["check"], ok["ok"], ok["bytes"]), ("lint", True, 5))
        self.assertNotIn("log_tail", ok)
        self.assertEqual((failed["check"], failed["ok"]), ("test", False))
        self.assertEqual(failed["log_tail"].splitlines(), [str(n) for n in range(11, 31)])
        self.assertIsInstance(failed["dur_s"], float)

    def test_a_check_that_never_wrote_a_result_counts_as_failed(self):
        code, text = self.report(["killed"])
        self.assertEqual(code, 1)
        self.assertRegex(text, r"^FAIL killed ")

    def test_a_missing_command_fails_with_a_message_in_the_log(self):
        code = subprocess.run([sys.executable, SCRIPT, "run", "gone", self.logs, "--", "/nonexistent/tool"], env=self.env).returncode
        self.assertEqual(code, 127)
        self.assertIn("/nonexistent/tool", check_summary.read_log(self.logs, "gone"))

    def test_nothing_is_recorded_when_metrics_are_off(self):
        self.assertEqual(self.run_check("lint", "exit 0"), 0)
        self.assertFalse(os.path.exists(self.metrics))

    def test_records_each_check_beside_the_recipe_records(self):
        on = {"LILO_METRICS_DIRTY": "0"}
        self.run_check("lint", "exit 0", **on, LILO_CHECK_TIER="pre-push", LILO_CHECK_TRIGGER="hook", LILO_CHECK_SCOPE="ui-lint release-status")
        self.run_check("test", "exit 2", **on)
        passed, failed = self.records()
        self.assertEqual((passed["target"], passed["phase"], passed["exit"]), ("lint", "check", 0))
        self.assertEqual((passed["tier"], passed["trigger"], passed["scope"]), ("pre-push", "hook", "ui-lint release-status"))
        for field in ("ts", "dur_s", "worktree", "sha", "dirty", "loadavg1", "concurrent", "overhead_ms"):
            self.assertIn(field, passed)
        self.assertEqual((failed["target"], failed["exit"]), ("test", 2))
        for field in ("tier", "trigger", "scope", "rerun_of"):
            self.assertNotIn(field, failed)

    def test_a_run_after_a_failure_names_it_and_a_pass_resets_it(self):
        on = {"LILO_METRICS_DIRTY": "0"}
        self.run_check("test", "exit 1", **on)
        self.run_check("lint", "exit 1", **on)
        self.run_check("test", "exit 0", **on)
        self.run_check("test", "exit 0", **on)
        first, _, rerun, again = self.records()
        self.assertEqual(rerun["rerun_of"], first["ts"])
        self.assertNotIn("rerun_of", first)
        self.assertNotIn("rerun_of", again)

    def test_recording_stays_under_the_metrics_overhead_budget(self):
        on = {"LILO_METRICS_DIRTY": "0"}
        for _ in range(5):
            self.run_check("lint", "exit 0", **on)
        import metrics
        costs = sorted(record["overhead_ms"] for record in self.records())
        self.assertLess(costs[len(costs) // 2], metrics.BUDGET_MS)

    def test_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(check_summary.main(["run", "lint"]), 2)


if __name__ == "__main__":
    unittest.main()
