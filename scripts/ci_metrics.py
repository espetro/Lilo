#!/usr/bin/env python3
"""Summarize how long Lilo's CI takes, from the last runs of a workflow on the GitHub Actions API.

    ci_metrics.py [--repo OWNER/NAME] [--workflow build.yml] [--runs 20] [--branch main] [--event push] [--macos xcode,macos] [--json]

Reads job and step started_at/completed_at, so it needs no workflow change. It goes through `gh api`
and, when gh has no working login, falls back to the unauthenticated API (60 requests an hour, enough
for 20 runs: one call lists the runs, one per run lists its jobs). Public data only; nothing is sent.
"""
import argparse
import json
import subprocess
import sys
import urllib.request
from datetime import datetime

PAGE = "per_page=100"


def get(path, repo):
    """One API call as JSON: gh api first, then plain HTTPS for a public repo when gh cannot sign in."""
    path = path.replace("{repo}", repo)
    try:
        result = subprocess.run(["gh", "api", path], capture_output=True, text=True)
        if result.returncode == 0:
            return json.loads(result.stdout)
    except OSError:
        pass
    with urllib.request.urlopen(urllib.request.Request(f"https://api.github.com/{path}", headers={"Accept": "application/vnd.github+json"}), timeout=30) as response:
        return json.load(response)


def parse(stamp):
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp() if stamp else None


def percentile(values, p):
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * p)] if ordered else 0.0


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    if not ordered:
        return 0.0
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def is_macos(job, prefixes):
    return any(label.lower().startswith(tuple(prefixes)) for label in job.get("labels", []))


def max_concurrent(intervals):
    events = sorted([(start, 1) for start, _ in intervals] + [(end, -1) for _, end in intervals], key=lambda e: (e[0], e[1]))
    current = peak = 0
    for _, step in events:
        current += step
        peak = max(peak, current)
    return peak


def analyze_run(run, jobs, macos_prefixes):
    created = parse(run["created_at"])
    ran = [j for j in jobs if j.get("conclusion") != "skipped" and j.get("started_at") and j.get("completed_at")]
    finished = [parse(j["completed_at"]) for j in ran]
    macos = [(parse(j["started_at"]), parse(j["completed_at"])) for j in ran if is_macos(j, macos_prefixes)]
    return {
        "id": run["id"],
        "conclusion": run["conclusion"],
        "attempt": run.get("run_attempt", 1),
        "makespan_s": max(finished) - created if finished else None,
        "first_signal_s": min(finished) - created if finished else None,
        "jobs": len(jobs),
        "skipped": sum(1 for j in jobs if j.get("conclusion") == "skipped"),
        "macos_slot_min": sum(end - start for start, end in macos) / 60,
        "macos_max_concurrent": max_concurrent(macos),
        "queue_s": [parse(j["started_at"]) - parse(j["created_at"]) for j in ran if j.get("created_at")],
    }


def job_rows(all_jobs):
    """Median and p95 seconds per job name, and per step name within it, over the runs that ran it."""
    durations, steps = {}, {}
    for jobs in all_jobs:
        for job in jobs:
            if job.get("conclusion") == "skipped" or not job.get("completed_at"):
                continue
            name = job["name"]
            durations.setdefault(name, []).append(parse(job["completed_at"]) - parse(job["started_at"]))
            for step in job.get("steps", []):
                if step.get("conclusion") == "skipped" or not step.get("completed_at"):
                    continue
                steps.setdefault((name, step["name"]), []).append(parse(step["completed_at"]) - parse(step["started_at"]))
    return durations, steps


def summarize(runs, jobs_by_run, macos_prefixes):
    per_run = [analyze_run(run, jobs_by_run[run["id"]], macos_prefixes) for run in runs]
    durations, steps = job_rows(list(jobs_by_run.values()))
    # A cancelled run stopped early (a newer push replaced it): its times say nothing about how long CI takes.
    measured = [r for r in per_run if r["makespan_s"] is not None and r["conclusion"] in ("success", "failure")]
    total_jobs = sum(r["jobs"] for r in per_run)
    return {
        "runs": len(per_run),
        "failed": sum(1 for r in per_run if r["conclusion"] == "failure"),
        "cancelled": sum(1 for r in per_run if r["conclusion"] == "cancelled"),
        "retried": sum(1 for r in per_run if r["attempt"] > 1),
        "makespan_s": {"median": median([r["makespan_s"] for r in measured]), "p95": percentile([r["makespan_s"] for r in measured], 0.95)},
        "first_signal_s": {"median": median([r["first_signal_s"] for r in measured]), "p95": percentile([r["first_signal_s"] for r in measured], 0.95)},
        "skip_rate": sum(r["skipped"] for r in per_run) / total_jobs if total_jobs else 0.0,
        "macos_slot_min": {"median": median([r["macos_slot_min"] for r in measured]), "p95": percentile([r["macos_slot_min"] for r in measured], 0.95)},
        "macos_max_concurrent": max((r["macos_max_concurrent"] for r in per_run), default=0),
        "queue_s": {"median": median([q for r in per_run for q in r["queue_s"]]), "p95": percentile([q for r in per_run for q in r["queue_s"]], 0.95)},
        "jobs": {name: {"runs": len(v), "median": median(v), "p95": percentile(v, 0.95)} for name, v in sorted(durations.items())},
        "steps": {f"{job} / {step}": {"runs": len(v), "median": median(v), "p95": percentile(v, 0.95)}
                  for (job, step), v in sorted(steps.items()) if median(v) >= 20},
    }


def minutes(seconds):
    return f"{seconds / 60:.1f} min"


def print_summary(summary, out=None):
    out = out or sys.stdout
    pair = lambda d: f"median {minutes(d['median'])}, p95 {minutes(d['p95'])}"
    print(f"Runs: {summary['runs']} ({summary['failed']} failed, {summary['cancelled']} cancelled, {summary['retried']} re-run)", file=out)
    print(f"Time to first signal: {pair(summary['first_signal_s'])}", file=out)
    print(f"Makespan: {pair(summary['makespan_s'])}", file=out)
    print(f"Queue before a job starts: median {summary['queue_s']['median']:.0f} s, p95 {summary['queue_s']['p95']:.0f} s", file=out)
    print(f"macOS slot-minutes per run: median {summary['macos_slot_min']['median']:.1f}, p95 {summary['macos_slot_min']['p95']:.1f}; max concurrent macOS jobs: {summary['macos_max_concurrent']}", file=out)
    print(f"Skip rate: {summary['skip_rate']:.0%} of jobs (a skipped job is a check that did not run, not a pass)", file=out)
    print("\nJob durations", file=out)
    for name, row in summary["jobs"].items():
        print(f"  {name[:56]:<56} runs {row['runs']:>3}  median {minutes(row['median']):>9}  p95 {minutes(row['p95']):>9}", file=out)
    print("\nSteps of 20 s or more (median)", file=out)
    for name, row in summary["steps"].items():
        print(f"  {name[:90]:<90} {minutes(row['median']):>9}", file=out)


def collect(repo, workflow, count, branch, event):
    query = f"{PAGE}&status=completed" + (f"&branch={branch}" if branch else "") + (f"&event={event}" if event else "")
    runs = get(f"repos/{{repo}}/actions/workflows/{workflow}/runs?{query}", repo)["workflow_runs"][:count]
    return runs, {run["id"]: get(f"repos/{{repo}}/actions/runs/{run['id']}/jobs?{PAGE}", repo)["jobs"] for run in runs}


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", default="Alexays/Lilo")
    parser.add_argument("--workflow", default="build.yml")
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--branch", default="main")
    parser.add_argument("--event", default="push")
    parser.add_argument("--macos", default="xcode,macos", help="comma-separated runner label prefixes counted as macOS slots")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    runs, jobs = collect(args.repo, args.workflow, args.runs, args.branch, args.event)
    summary = summarize(runs, jobs, tuple(args.macos.lower().split(",")))
    if args.json:
        json.dump(summary, sys.stdout, indent=2)
        print()
    else:
        print_summary(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
