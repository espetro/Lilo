"""Check that scripts/lockf.py holds its lock for the whole command."""
import os
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lockf.py")

# Tries to take the lock. It succeeds when no one holds it.
PROBE = """
import fcntl, os, sys
descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o666)
try:
    fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
sys.exit(1)
"""


class LockfTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.lock = os.path.join(self.directory.name, "test.lock")

    def tearDown(self):
        self.directory.cleanup()

    def run_locked(self, *arguments, timeout=30):
        return subprocess.run(
            [sys.executable, SCRIPT, *arguments], capture_output=True, text=True, timeout=timeout, check=False
        )

    def test_runs_the_command_and_passes_its_exit_code(self):
        result = self.run_locked(self.lock, sys.executable, "-c", "print('ran')")
        self.assertEqual(result.returncode, 0)
        self.assertIn("ran", result.stdout)

        failure = self.run_locked(self.lock, sys.executable, "-c", "raise SystemExit(7)")
        self.assertEqual(failure.returncode, 7)

    def test_holds_the_lock_while_the_command_runs(self):
        # The lock must survive the exec that runs the command: Python opens descriptors
        # close-on-exec, so a missing os.set_inheritable would release it right away.
        holder = subprocess.Popen(
            [sys.executable, SCRIPT, self.lock, sys.executable, "-c", "import time; time.sleep(1.5)"]
        )
        try:
            time.sleep(0.5)
            self.assertEqual(subprocess.run([sys.executable, "-c", PROBE, self.lock]).returncode, 0)
        finally:
            holder.wait(timeout=30)

    def test_second_process_waits_for_the_lock(self):
        holder = subprocess.Popen(
            [sys.executable, SCRIPT, self.lock, sys.executable, "-c", "import time; time.sleep(1)"]
        )
        try:
            time.sleep(0.4)
            waiter = self.run_locked(self.lock, sys.executable, "-c", "print('waited')")
            self.assertEqual(waiter.returncode, 0)
            self.assertIn("waited", waiter.stdout)
        finally:
            holder.wait(timeout=30)

    def test_nonblocking_fails_while_the_lock_is_taken(self):
        holder = subprocess.Popen(
            [sys.executable, SCRIPT, self.lock, sys.executable, "-c", "import time; time.sleep(1.5)"]
        )
        try:
            time.sleep(0.4)
            result = self.run_locked("-n", self.lock, sys.executable, "-c", "print('ran')")
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("ran", result.stdout)
        finally:
            holder.wait(timeout=30)

    def test_timeout_gives_up(self):
        holder = subprocess.Popen(
            [sys.executable, SCRIPT, self.lock, sys.executable, "-c", "import time; time.sleep(1.5)"]
        )
        try:
            time.sleep(0.4)
            started = time.monotonic()
            result = self.run_locked("-w", "1", self.lock, sys.executable, "-c", "print('ran')")
            self.assertEqual(result.returncode, 1)
            self.assertLess(time.monotonic() - started, 2.5)
        finally:
            holder.wait(timeout=30)

    def test_reports_a_missing_command(self):
        result = self.run_locked(self.lock, "lilo-no-such-command")
        self.assertEqual(result.returncode, 127)


if __name__ == "__main__":
    unittest.main()
