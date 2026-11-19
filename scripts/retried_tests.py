#!/usr/bin/env python3
"""Lists the tests that failed and then passed on a retry, as Markdown for a CI job summary.

Takes Xcode result bundles (.xcresult) and Playwright JSON reports, skipping those a failed build never wrote
or left unreadable; prints nothing when no test needed a retry. Each one is also a warning annotation on
stderr, which the run's checks list shows.

With --failing [--label TEXT] it instead prints the failed and the retried tests of one job, with the first line of
each failure (300 characters at most): the failing-tests.md artifact an agent reads in place of the job log. It
prints nothing when every test passed first time, and says so when no result file exists at all.
"""
import json
import os
import re
import subprocess
import sys


def xcode_results(bundle):
    """Returns (failed, retried) as lists of (name, first failure message) for an Xcode result bundle."""
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"::notice::{bundle} holds no test results: {result.stderr.strip()[:300]}", file=sys.stderr)
        return [], []
    tree = json.loads(result.stdout)
    failed, retried = [], []

    def failures(node):
        return [
            message.get("name", "") for message in node.get("children", [])
            if message.get("nodeType") == "Failure Message"
        ]

    def walk(node):
        runs = [child for child in node.get("children", []) if child.get("nodeType") == "Repetition"]
        if node.get("nodeType") == "Test Case":
            messages = failures(node) + [
                message for run in runs if run.get("result") == "Failed" for message in failures(run)
            ]
            entry = (node.get("nodeIdentifier") or node.get("name"), messages[0] if messages else "")
            if node.get("result") == "Failed":
                failed.append(entry)
            elif any(run.get("result") == "Failed" for run in runs):
                retried.append(entry)
        for child in node.get("children", []):
            walk(child)

    for node in tree.get("testNodes", []):
        walk(node)
    return failed, retried


def playwright_results(report_path):
    """Returns (failed, retried) as lists of (name, first error) for a Playwright JSON report."""
    with open(report_path, encoding="utf-8") as report:
        report = json.load(report)
    failed, retried = [], []

    def walk(suite, titles):
        for spec in suite.get("specs", []):
            for test in spec.get("tests", []):
                if test.get("status") not in ("flaky", "unexpected"):
                    continue
                errors = [result.get("error", {}).get("message", "") for result in test.get("results", []) if result.get("status") != "passed"]
                entry = (" > ".join(titles + [spec["title"]]), errors[0] if errors else "")
                (retried if test["status"] == "flaky" else failed).append(entry)
        for child in suite.get("suites", []):
            walk(child, titles + [child["title"]])

    for suite in report.get("suites", []):
        walk(suite, [suite["title"]])
    return failed, retried


def bullets(tests):
    lines = []
    for name, failure in tests:
        # The first line of the failure, without ANSI colors or backticks that would break the Markdown.
        first = re.sub(r"\x1b\[[0-9;]*m", "", failure).split("\n", 1)[0].replace("`", "'")
        lines.append(f"- `{name}`" + (f": {first[:300]}" if first else ""))
    return lines


def collect(paths):
    failed, retried = [], []
    for path in filter(os.path.exists, paths):
        more_failed, more_retried = xcode_results(path) if path.rstrip("/").endswith(".xcresult") else playwright_results(path)
        failed += more_failed
        retried += more_retried
    return failed, retried


def retried_report(retried):
    if not retried:
        return
    print("### Tests that passed only on a retry\n")
    print("They did not fail the run, but they are flaky: please fix them.\n")
    print("\n".join(bullets(retried)))
    for name, _ in retried:
        print(f"::warning title=Flaky test::{name} passed only on a retry", file=sys.stderr)


def failing_report(paths, label):
    failed, retried = collect(paths)
    title = f"# Failing tests ({label})" if label else "# Failing tests"
    if not any(map(os.path.exists, paths)):
        print(f"{title}\n\nNo test results were written: the build or the test launch failed, so read the job log.")
    elif failed or retried:
        print(title)
        if failed:
            print(f"\n## Failed ({len(failed)})\n")
            print("\n".join(bullets(failed)))
        if retried:
            print(f"\n## Passed only on a retry ({len(retried)})\n")
            print("\n".join(bullets(retried)))


def main(args):
    label = args[args.index("--label") + 1] if "--label" in args else ""
    paths = [arg for index, arg in enumerate(args) if not arg.startswith("--") and (index == 0 or args[index - 1] != "--label")]
    if "--failing" in args:
        failing_report(paths, label)
    else:
        retried_report(collect(paths)[1])


if __name__ == "__main__":
    main(sys.argv[1:])
