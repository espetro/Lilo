"""Record, summarize and calibrate recipe timings."""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from metrics import BEGIN, END, git_head, summarize, toggle

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "metrics.py")


class MetricsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.file = os.path.join(self.directory.name, "metrics.jsonl")
        self.env = dict(os.environ, LILO_METRICS_FILE=self.file, LILO_METRICS_TARGET="demo", MAKELEVEL="1")

    def wrapper(self, *args):
        return subprocess.Popen([sys.executable, SCRIPT, *args], env=self.env, cwd=self.directory.name)

    def records(self):
        with open(self.file, encoding="utf-8") as file:
            return [json.loads(line) for line in file]

    def test_records_success_and_failure_with_the_exit_status(self):
        self.assertEqual(self.wrapper("-c", "exit 0").wait(), 0)
        self.assertEqual(self.wrapper("-c", "exit 3").wait(), 3)
        ok, failed = self.records()
        self.assertEqual((ok["target"], ok["exit"], ok["phase"], ok["level"]), ("demo", 0, "recipe", 0))
        self.assertEqual(failed["exit"], 3)
        for field in ("ts", "dur_s", "worktree", "sha", "branch", "dirty", "cpus_perf", "ram_gb", "loadavg1",
                      "concurrent", "disk_free_gb", "agent", "pid", "overhead_ms"):
            self.assertIn(field, ok)

    def test_records_an_interrupted_recipe(self):
        process = self.wrapper("-c", "sleep 4")
        time.sleep(0.5)
        process.send_signal(signal.SIGTERM)
        self.assertEqual(process.wait(timeout=10), 143)
        self.assertEqual(self.records()[0]["exit"], 143)

    def test_records_a_killed_recipe_as_orphaned_on_the_next_run(self):
        process = self.wrapper("-c", "sleep 4")
        time.sleep(0.5)
        process.kill()
        process.wait()
        self.assertFalse(os.path.exists(self.file))
        self.assertEqual(self.wrapper("-c", "exit 0").wait(), 0)
        self.assertEqual([r["phase"] for r in self.records()], ["orphaned", "recipe"])
        self.assertIsNone(self.records()[0]["exit"])

    def test_the_metrics_targets_do_not_record_themselves(self):
        self.env["LILO_METRICS_TARGET"] = "metrics"
        self.assertEqual(self.wrapper("-c", "exit 0").wait(), 0)
        self.assertFalse(os.path.exists(self.file))

    def test_summary_counts_failures_and_interrupts_beside_the_timings(self):
        def record(exit, dur, phase="recipe"):
            return {"target": "swift-test", "phase": phase, "exit": exit, "dur_s": dur, "concurrent": 1, "overhead_ms": 5}
        rows = summarize([record(0, 10), record(0, 30), record(1, 2), record(143, 1), record(None, 5, "orphaned")])
        self.assertEqual(rows, [{
            "target": "swift-test", "runs": 5, "ok": 2, "failed": 1, "interrupted": 1, "orphaned": 1,
            "median_s": 20.0, "p95_s": 30, "max_concurrent": 1, "max_overhead_ms": 5,
        }])

    def test_on_and_off_edit_only_their_own_block(self):
        path = os.path.join(self.directory.name, "Makefile.local")
        with open(path, "w", encoding="utf-8") as file:
            file.write("export LILO_DEBUG_TEAM_ID := ABC\n")
        toggle(True, path)
        toggle(True, path)
        with open(path, encoding="utf-8") as file:
            text = file.read()
        self.assertEqual(text.count(BEGIN), 1)
        self.assertIn(END, text)
        toggle(False, path)
        with open(path, encoding="utf-8") as file:
            self.assertEqual(file.read(), "export LILO_DEBUG_TEAM_ID := ABC\n")

    def test_off_removes_a_makefile_local_it_created(self):
        path = os.path.join(self.directory.name, "Makefile.local")
        toggle(True, path)
        toggle(False, path)
        self.assertFalse(os.path.exists(path))

    def test_reads_head_from_a_worktree_without_running_git(self):
        common = os.path.join(self.directory.name, "main", ".git")
        gitdir = os.path.join(common, "worktrees", "wt")
        os.makedirs(os.path.join(common, "refs", "heads", "feat"))
        os.makedirs(gitdir)
        with open(os.path.join(common, "refs", "heads", "feat", "x"), "w", encoding="utf-8") as file:
            file.write("0123456789abcdef0123\n")
        with open(os.path.join(gitdir, "HEAD"), "w", encoding="utf-8") as file:
            file.write("ref: refs/heads/feat/x\n")
        with open(os.path.join(gitdir, "commondir"), "w", encoding="utf-8") as file:
            file.write("../..\n")
        tree = os.path.join(self.directory.name, "wt")
        os.makedirs(tree)
        with open(os.path.join(tree, ".git"), "w", encoding="utf-8") as file:
            file.write(f"gitdir: {gitdir}\n")
        self.assertEqual(git_head(tree), ("0123456789ab", "feat/x"))

    def test_calibration_keeps_one_record_under_the_budget(self):
        result = subprocess.run([sys.executable, SCRIPT, "calibrate"], env=self.env, cwd=self.directory.name, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calibration = self.records()[-1]
        self.assertEqual((calibration["phase"], calibration["exit"], calibration["budget_ms"]), ("calibration", 0, 30))


if __name__ == "__main__":
    unittest.main()
