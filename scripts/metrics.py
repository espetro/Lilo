#!/usr/bin/env python3
"""Record how long Makefile recipes take, and summarize the records.

    metrics.py on | off          add or remove the opt-in SHELL hook in Makefile.local
    metrics.py summary [--since DAYS] [--target NAME]
    metrics.py calibrate         assert one record costs under 30 ms
    metrics.py -c COMMAND        what make runs once the hook is on: run COMMAND with bash, record it

One JSON line per recipe line in ~/.cache/lilo/metrics.jsonl (LILO_METRICS_FILE moves it), written on
success, failure and interrupt. A recipe that is killed outright (SIGKILL) cannot write its own line, so
the next run records it as phase "orphaned". Nothing is sent anywhere. Every field is documented in
docs/build-baseline.md.
"""
import json
import os
import signal
import subprocess
import sys
import time

BUDGET_MS = 30
BEGIN = "# >>> lilo metrics: `make metrics-off` removes this block"
END = "# <<< lilo metrics"
HOOK = "SHELL = $(if $@,$(CURDIR)/scripts/metrics.py,/bin/bash)\nexport LILO_METRICS_TARGET = $@"
# Targets that must not record themselves.
SKIPPED = ("metrics",)


def cache_dir():
    return os.path.join(os.path.expanduser("~"), ".cache", "lilo")


def metrics_file():
    return os.environ.get("LILO_METRICS_FILE") or os.path.join(cache_dir(), "metrics.jsonl")


def active_dir():
    return os.path.join(os.path.dirname(metrics_file()), "metrics-active")


def hardware():
    """Static facts, read once: a sysctl costs a process each."""
    path = os.path.join(os.path.dirname(metrics_file()), "metrics-hw.json")
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file)
    except (OSError, ValueError):
        pass

    def sysctl(name):
        try:
            return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()
        except OSError:
            return ""

    cpus = sysctl("hw.perflevel0.physicalcpu") or sysctl("hw.ncpu") or str(os.cpu_count() or 0)
    memory = sysctl("hw.memsize")
    facts = {"cpus_perf": int(cpus or 0), "ram_gb": round(int(memory or 0) / 2**30, 1)}
    write_atomically(path, json.dumps(facts))
    return facts


def write_atomically(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = f"{path}.{os.getpid()}"
    with open(temporary, "w", encoding="utf-8") as file:
        file.write(text)
    os.replace(temporary, path)


def git_head(directory):
    """(sha, branch) read from the files, with no git process: a worktree's .git is a file."""
    try:
        dot_git = os.path.join(directory, ".git")
        git_dir = dot_git
        if os.path.isfile(dot_git):
            with open(dot_git, encoding="utf-8") as file:
                git_dir = os.path.join(directory, file.read().strip().removeprefix("gitdir: "))
        with open(os.path.join(git_dir, "HEAD"), encoding="utf-8") as file:
            head = file.read().strip()
        if not head.startswith("ref: "):
            return head[:12], ""
        ref = head[5:]
        common = git_dir
        if os.path.exists(os.path.join(git_dir, "commondir")):
            with open(os.path.join(git_dir, "commondir"), encoding="utf-8") as file:
                common = os.path.normpath(os.path.join(git_dir, file.read().strip()))
        for base in (git_dir, common):
            try:
                with open(os.path.join(base, ref), encoding="utf-8") as file:
                    return file.read().strip()[:12], ref.removeprefix("refs/heads/")
            except OSError:
                pass
        with open(os.path.join(common, "packed-refs"), encoding="utf-8") as file:
            for line in file:
                if line.rstrip().endswith(" " + ref):
                    return line[:12], ref.removeprefix("refs/heads/")
    except OSError:
        pass
    return "", ""


def is_dirty(directory):
    """Tracked files differ from HEAD: a git process (about 15 ms), so once per make run, not per recipe line."""
    if "LILO_METRICS_DIRTY" in os.environ:
        return os.environ["LILO_METRICS_DIRTY"] == "1"
    cached = os.path.join(active_dir(), f"dirty-{os.getppid()}")  # the parent is the make that runs every recipe line
    try:
        with open(cached, encoding="utf-8") as file:
            return file.read() == "1"
    except OSError:
        pass
    try:
        dirty = subprocess.run(["git", "-C", directory, "diff-index", "--quiet", "HEAD", "--"], capture_output=True).returncode != 0
    except OSError:
        return False
    try:
        write_atomically(cached, "1" if dirty else "0")
    except OSError:
        pass
    return dirty


def agent():
    if os.environ.get("LILO_AGENT"):
        return os.environ["LILO_AGENT"]
    return "claude-code" if os.environ.get("CLAUDECODE") else ""


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def other_active(worktree):
    """Recipes running right now in other worktrees (parallel recipes of one make are by design), with no process scan."""
    count = 0
    try:
        names = os.listdir(active_dir())
    except OSError:
        return 0
    for name in names:
        if not name.isdigit() or int(name) == os.getpid() or not alive(int(name)):
            continue
        try:
            with open(os.path.join(active_dir(), name), encoding="utf-8") as file:
                count += json.load(file).get("worktree") != worktree
        except (OSError, ValueError):
            pass
    return count


def sweep_orphans():
    """A recipe whose wrapper died without writing its line: record it, once."""
    try:
        names = os.listdir(active_dir())
    except OSError:
        return
    for name in names:
        pid = name.removeprefix("dirty-")
        if not pid.isdigit() or alive(int(pid)):
            continue
        path = os.path.join(active_dir(), name)
        if pid != name:
            os.unlink(path)  # a make that has ended
            continue
        try:
            with open(path, encoding="utf-8") as file:
                record = json.load(file)
            os.unlink(path)
        except (OSError, ValueError):
            continue
        record.update(phase="orphaned", exit=None, dur_s=round(time.time() - record["ts"], 3))
        append(record)


def append(record):
    path = metrics_file()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    line = (json.dumps(record, separators=(",", ":")) + "\n").encode()
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(descriptor, line)  # one write: concurrent worktrees never interleave lines
    finally:
        os.close(descriptor)


def start_record(target, phase):
    directory = os.getcwd()
    sha, branch = git_head(directory)
    return {
        "ts": round(time.time(), 3),
        "target": target,
        "phase": phase,
        "worktree": os.path.basename(directory),
        "sha": sha,
        "branch": branch,
        "dirty": is_dirty(directory),
        "agent": agent(),
        "pid": os.getpid(),
        **hardware(),
    }


def finish_record(record, started, code, overhead_before):
    mark = time.perf_counter()
    record["dur_s"] = round(mark - started, 3)
    record["exit"] = code
    record["loadavg1"] = round(os.getloadavg()[0], 2)
    record["concurrent"] = other_active(record["worktree"])
    record["disk_free_gb"] = round((lambda v: v.f_bavail * v.f_frsize)(os.statvfs(".")) / 2**30, 1)
    record["level"] = max(int(os.environ.get("MAKELEVEL", "1")) - 1, 0)
    record["overhead_ms"] = round((overhead_before + time.perf_counter() - mark) * 1000, 1)
    return record


def run(command):
    """Run COMMAND with bash and record it. Returns bash's exit status (128+N when a signal ended it)."""
    target = os.environ.get("LILO_METRICS_TARGET", "")
    # No target: a $(shell) that make expanded inside a recipe's context. The metrics targets stay out of their own records.
    if not target or target.startswith(SKIPPED):
        os.execv("/bin/bash", ["/bin/bash", "-c", command])
    begin = time.perf_counter()
    sweep_orphans()
    record = start_record(target, "recipe")
    marker = os.path.join(active_dir(), str(os.getpid()))
    try:
        write_atomically(marker, json.dumps(record))
    except OSError:
        marker = None
    environment = dict(os.environ, LILO_METRICS_DIRTY="1" if record["dirty"] else "0")
    del environment["LILO_METRICS_TARGET"]  # make sets it afresh per recipe; a sub-make's $(shell) must not inherit it
    child = None
    for name in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        # make signals its recipe's shell alone; pass it on, and stay alive to record the run as interrupted.
        signal.signal(name, lambda number, _frame: child.send_signal(number) if child and child.poll() is None else None)
    overhead = time.perf_counter() - begin
    started = time.perf_counter()
    child = subprocess.Popen(["/bin/bash", "-c", command], env=environment)
    code = child.wait()
    code = 128 - code if code < 0 else code
    try:
        append(finish_record(record, started, code, overhead))
    finally:
        if marker:
            try:
                os.unlink(marker)
            except OSError:
                pass
    return code


def load(path, since_days=None, target=None):
    records = []
    cutoff = time.time() - since_days * 86400 if since_days else 0
    try:
        with open(path, encoding="utf-8") as file:
            for line in file:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if record.get("ts", 0) >= cutoff and (not target or record.get("target") == target):
                    records.append(record)
    except OSError:
        pass
    return records


def percentile(values, p):
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * p)] if ordered else 0.0


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def summarize(records):
    """Per target: runs, median and p95 seconds, and the failure and interrupt counts beside them."""
    groups = {}
    for record in records:
        if record.get("phase") in ("recipe", "orphaned"):
            groups.setdefault(record["target"], []).append(record)
    rows = []
    for target, items in groups.items():
        done = [r for r in items if r["phase"] == "recipe"]
        times = [r["dur_s"] for r in done if r["exit"] == 0]
        rows.append({
            "target": target,
            "runs": len(items),
            "ok": len(times),
            "failed": sum(1 for r in done if r["exit"] not in (0, 130, 143)),
            "interrupted": sum(1 for r in done if r["exit"] in (130, 143)),
            "orphaned": len(items) - len(done),
            "median_s": median(times) if times else None,
            "p95_s": percentile(times, 0.95) if times else None,
            "max_concurrent": max((r.get("concurrent", 0) for r in items), default=0),
            "max_overhead_ms": max((r.get("overhead_ms", 0) for r in done), default=0),
        })
    return sorted(rows, key=lambda row: -(row["median_s"] or 0) * row["runs"])


def print_summary(rows, out=None):
    out = out or sys.stdout
    if not rows:
        print("No records yet. Run `make metrics-on`, then use make as usual.", file=out)
        return
    print(f"{'target':<28}{'runs':>5}{'ok':>5}{'fail':>5}{'intr':>5}{'orph':>5}{'median s':>10}{'p95 s':>9}{'conc':>5}", file=out)
    for row in rows:
        median = f"{row['median_s']:.1f}" if row["median_s"] is not None else "-"
        p95 = f"{row['p95_s']:.1f}" if row["p95_s"] is not None else "-"
        print(f"{row['target'][:27]:<28}{row['runs']:>5}{row['ok']:>5}{row['failed']:>5}{row['interrupted']:>5}{row['orphaned']:>5}"
              f"{median:>10}{p95:>9}{row['max_concurrent']:>5}", file=out)
    print("\nFailures and interrupts are counted beside the timings: a median over successes alone flatters.", file=out)
    print("A target at level 0 contains the targets it runs through $(MAKE); do not add the rows up.", file=out)


def calibrate(runs=20):
    """Build and write `runs` records into a scratch file, time each, and record the median as a calibration line."""
    real = os.environ.get("LILO_METRICS_FILE")
    scratch = os.path.join(cache_dir(), "metrics-calibration.jsonl")
    os.environ["LILO_METRICS_FILE"] = scratch
    costs = []
    hardware()  # read once per machine, not part of a record's steady cost
    try:
        for _ in range(runs):
            begin = time.perf_counter()
            record = start_record("calibration", "calibration")
            os.environ["LILO_METRICS_DIRTY"] = "1" if record["dirty"] else "0"  # as run() does for what it starts
            append(finish_record(record, begin, 0, 0))
            costs.append((time.perf_counter() - begin) * 1000)
        os.unlink(scratch)
    finally:
        if real is None:
            del os.environ["LILO_METRICS_FILE"]
        else:
            os.environ["LILO_METRICS_FILE"] = real
    typical, worst = median(costs), max(costs)
    ok = typical < BUDGET_MS  # the median: one scheduler hiccup on a loaded Mac is not the cost of a record
    append({"ts": round(time.time(), 3), "target": "calibration", "phase": "calibration", "dur_s": round(typical / 1000, 4),
            "exit": 0 if ok else 1, "pid": os.getpid(), "worst_ms": round(worst, 1), "budget_ms": BUDGET_MS})
    print(f"record cost: median {typical:.1f} ms, worst {worst:.1f} ms, budget {BUDGET_MS} ms: {'ok' if ok else 'OVER BUDGET'}")
    return 0 if ok else 1


def toggle(on, path="Makefile.local"):
    try:
        with open(path, encoding="utf-8") as file:
            text = file.read()
    except OSError:
        text = ""
    start = text.find(BEGIN)
    if start >= 0:
        finish = text.find(END, start)
        text = (text[:start].rstrip("\n") + "\n" + text[finish + len(END):].lstrip("\n")) if finish >= 0 else text[:start]
        text = text.strip("\n") + "\n" if text.strip() else ""
    if on:
        text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + f"{BEGIN}\n{HOOK}\n{END}\n"
    elif not text.strip():
        if os.path.exists(path):
            os.unlink(path)
        return
    with open(path, "w", encoding="utf-8") as file:
        file.write(text)


def main(argv):
    if len(argv) >= 2 and argv[0] == "-c":
        return run(argv[1])
    command = argv[0] if argv else "summary"
    if command in ("on", "off"):
        toggle(command == "on")
        print(f"Metrics {'enabled' if command == 'on' else 'disabled'} in Makefile.local; records go to {metrics_file()}.")
        return 0
    if command == "calibrate":
        return calibrate()
    if command == "summary":
        options = dict(zip(argv[1::2], argv[2::2]))
        since = float(options["--since"]) if "--since" in options else None
        print_summary(summarize(load(metrics_file(), since, options.get("--target"))))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
