"""Report the failed and retried tests of recorded Xcode and Playwright results."""
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
from unittest import mock

import retried_tests


def case(name, result, children=()):
    return {"nodeType": "Test Case", "name": name, "nodeIdentifier": f"Suite/{name}", "result": result, "children": list(children)}


def message(text):
    return {"nodeType": "Failure Message", "name": text}


def repetition(result, children=()):
    return {"nodeType": "Repetition", "result": result, "children": list(children)}


XCODE_TREE = {"testNodes": [{"nodeType": "Test Suite", "name": "Suite", "children": [
    case("passes()", "Passed"),
    case("fails()", "Failed", [message("XCTAssertEqual failed\nsecond line"), repetition("Failed")]),
    case("failsAfterRetry()", "Failed", [repetition("Failed", [message("first run broke")]), repetition("Failed", [message("second run broke")])]),
    case("flaky()", "Passed", [repetition("Failed", [message("only the first run: `boom`")]), repetition("Passed")]),
]}]}

PLAYWRIGHT_REPORT = {"suites": [{"title": "file.spec.ts", "suites": [{"title": "group", "specs": [
    {"title": "ok", "tests": [{"status": "expected", "results": [{"status": "passed"}]}]},
    {"title": "broken", "tests": [{"status": "unexpected", "results": [{"status": "failed", "error": {"message": "\x1b[31mexpected 1\x1b[0m\ndetail"}}]}]},
    {"title": "flaky", "tests": [{"status": "flaky", "results": [{"status": "failed", "error": {"message": "timeout"}}, {"status": "passed"}]}]},
]}]}]}


def run(function, *args):
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        function(*args)
    return out.getvalue(), err.getvalue()


class RetriedTestsTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def write_report(self):
        path = os.path.join(self.dir.name, "report.json")
        with open(path, "w", encoding="utf-8") as file:
            json.dump(PLAYWRIGHT_REPORT, file)
        return path

    def make_bundle(self):
        path = os.path.join(self.dir.name, "swift-test.xcresult")
        os.mkdir(path)
        return path

    def xcode(self, returncode=0):
        completed = SimpleNamespace(returncode=returncode, stdout=json.dumps(XCODE_TREE), stderr="no bundle")
        return mock.patch.object(retried_tests.subprocess, "run", return_value=completed)

    def test_xcode_separates_failed_from_retried(self):
        with self.xcode():
            failed, retried = retried_tests.xcode_results("any.xcresult")
        self.assertEqual(failed, [("Suite/fails()", "XCTAssertEqual failed\nsecond line"), ("Suite/failsAfterRetry()", "first run broke")])
        self.assertEqual(retried, [("Suite/flaky()", "only the first run: `boom`")])

    def test_xcode_without_results_is_empty(self):
        with self.xcode(returncode=1):
            _, err = run(lambda: self.assertEqual(retried_tests.xcode_results("any.xcresult"), ([], [])))
        self.assertIn("holds no test results", err)

    def test_playwright_separates_failed_from_retried(self):
        failed, retried = retried_tests.playwright_results(self.write_report())
        self.assertEqual(failed, [("file.spec.ts > group > broken", "\x1b[31mexpected 1\x1b[0m\ndetail")])
        self.assertEqual(retried, [("file.spec.ts > group > flaky", "timeout")])

    def test_default_mode_lists_only_retried_tests(self):
        out, err = run(retried_tests.main, [self.write_report()])
        self.assertIn("Tests that passed only on a retry", out)
        self.assertIn("`file.spec.ts > group > flaky`: timeout", out)
        self.assertNotIn("broken", out)
        self.assertIn("::warning title=Flaky test::file.spec.ts > group > flaky", err)

    def test_default_mode_is_silent_without_retries(self):
        out, err = run(retried_tests.main, [os.path.join(self.dir.name, "missing.json")])
        self.assertEqual((out, err), ("", ""))

    def test_failing_mode_lists_both_with_label_and_clean_first_line(self):
        out, _ = run(retried_tests.main, ["--failing", "--label", "shard 2/3", self.write_report()])
        self.assertTrue(out.startswith("# Failing tests (shard 2/3)\n"))
        self.assertIn("## Failed (1)", out)
        self.assertIn("- `file.spec.ts > group > broken`: expected 1\n", out)
        self.assertNotIn("detail", out)
        self.assertNotIn("\x1b", out)
        self.assertIn("## Passed only on a retry (1)", out)

    def test_failing_mode_truncates_the_first_line_to_300_characters(self):
        long = {"suites": [{"title": "s", "specs": [{"title": "t", "tests": [{"status": "unexpected", "results": [{"status": "failed", "error": {"message": "x" * 500}}]}]}]}]}
        path = os.path.join(self.dir.name, "long.json")
        with open(path, "w", encoding="utf-8") as file:
            json.dump(long, file)
        out, _ = run(retried_tests.main, ["--failing", path])
        self.assertIn("`: " + "x" * 300 + "\n", out + "\n")
        self.assertNotIn("x" * 301, out)

    def test_failing_mode_reads_xcode_bundles(self):
        bundle = self.make_bundle()
        with self.xcode():
            out, _ = run(retried_tests.main, ["--failing", "--label", "shard 1/3", bundle])
        self.assertIn("## Failed (2)", out)
        self.assertIn("- `Suite/fails()`: XCTAssertEqual failed\n", out)
        self.assertIn("- `Suite/flaky()`: only the first run: 'boom'", out)

    def test_failing_mode_is_silent_when_everything_passed(self):
        path = os.path.join(self.dir.name, "pass.json")
        with open(path, "w", encoding="utf-8") as file:
            json.dump({"suites": []}, file)
        self.assertEqual(run(retried_tests.main, ["--failing", path]), ("", ""))

    def test_failing_mode_says_when_no_result_was_written(self):
        out, _ = run(retried_tests.main, ["--failing", "--label", "shard 3/3", os.path.join(self.dir.name, "build/*.xcresult")])
        self.assertIn("# Failing tests (shard 3/3)", out)
        self.assertIn("No test results were written", out)


if __name__ == "__main__":
    unittest.main()
