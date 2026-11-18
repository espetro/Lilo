#!/usr/bin/env python3
"""Run a command while holding an exclusive lock on a file.

    scripts/lockf.py LOCKFILE COMMAND [ARGS...]
    scripts/lockf.py -n LOCKFILE COMMAND [ARGS...]

One command for every machine: macOS has lockf(1) but Linux has flock(1), and this uses only the
Python standard library, so a host rule that says "flock /tmp/tsc.lock <command>" works on both.

The lock is a lockf(3) byte-range lock: it interoperates with macOS lockf(1), not with flock(2).
The kernel releases it when the process dies or the command exits, and a failed run never leaves
a stale lock behind.
"""
import errno
import fcntl
import os
import sys
import time

USAGE = "usage: lockf.py [-n] [-w SECONDS] LOCKFILE COMMAND [ARGS...]"


def main(argv):
    nonblock = False
    timeout = None
    while argv and argv[0].startswith("-") and len(argv[0]) > 1:
        option = argv.pop(0)
        if option == "-n":
            nonblock = True
        elif option == "-w":
            timeout = int(argv.pop(0))
        elif option in ("-s", "-x", "-u", "-c"):
            pass  # flock(1) compatibility: the lock is always exclusive, -c joins the rest
        else:
            print(USAGE, file=sys.stderr)
            return 2
    if len(argv) < 2:
        print(USAGE, file=sys.stderr)
        return 2

    lockfile, command = argv[0], argv[1:]
    try:
        descriptor = os.open(lockfile, os.O_RDWR | os.O_CREAT, 0o666)
    except OSError as error:
        print(f"lockf.py: cannot open {lockfile}: {error.strerror}", file=sys.stderr)
        return 1

    # Python opens descriptors close-on-exec, so without this the lock would be released by the
    # exec below and two commands would run at once.
    os.set_inheritable(descriptor, True)
    deadline = None if timeout is None else time.monotonic() + timeout
    while True:
        try:
            fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError as error:
            if error.errno not in (errno.EACCES, errno.EAGAIN):
                print(f"lockf.py: cannot lock {lockfile}: {error.strerror}", file=sys.stderr)
                return 1
            if nonblock:
                print(f"lockf.py: {lockfile} is locked by another process", file=sys.stderr)
                return 1
            if deadline is not None and time.monotonic() >= deadline:
                print(f"lockf.py: {lockfile} is still locked after {timeout}s", file=sys.stderr)
                return 1
            time.sleep(0.1)

    try:
        os.execvp(command[0], command)
    except OSError as error:
        print(f"lockf.py: cannot run {command[0]}: {error.strerror}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
