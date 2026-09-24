import json
import os
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cleanup  # noqa: E402


def sleeper(cwd, ignore_term=False):
    """Start a detached sleep in cwd, reparented to pid 1 like a real dev stack."""
    script = "sleep 300 >/dev/null 2>&1 & echo $!"
    if ignore_term:
        script = 'trap "" TERM; ' + script
    return int(subprocess.check_output(["sh", "-c", script], cwd=cwd))


def reap(*pids):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def gone(pid):
    return cleanup.wait_for_exit([pid], timeout=5) == []


def git(*args, cwd):
    subprocess.run(
        ["git", *args],
        cwd=cwd,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def event_for(checkout, repo_root, linked=True):
    return json.dumps(
        {
            "workspace_id": "w1",
            "worktree": {
                "repo_name": repo_root.name,
                "repo_root": str(repo_root),
                "checkout_path": str(checkout),
                "is_linked_worktree": linked,
            },
        }
    )


class PidsInsideTest(unittest.TestCase):
    def test_matches_checkout_and_descendants_only(self):
        entries = [
            (1, "/"),
            (10, "/wt/foo"),
            (11, "/wt/foo/apps/server"),
            (12, "/wt/foo-bar"),
            (13, "/wt/foo-bar/apps"),
            (14, "/wt"),
            (15, "/wt/fo"),
        ]
        self.assertEqual(cleanup.pids_inside("/wt/foo", entries), [10, 11])
        self.assertEqual(cleanup.pids_inside("/wt/foo/", entries), [10, 11])

    def test_skips_protected_pids(self):
        entries = [(10, "/wt/foo"), (11, "/wt/foo/apps")]
        self.assertEqual(cleanup.pids_inside("/wt/foo", entries, {10}), [11])

    def test_protected_pids_include_self_and_parent(self):
        protected = cleanup.protected_pids()
        self.assertIn(os.getpid(), protected)
        self.assertIn(os.getppid(), protected)
        self.assertNotIn(0, protected)


class StopProcessesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="worktree-cleanup-test-")
        self.root = Path(self.tmp.name)
        self.checkout = self.root / "foo"
        (self.checkout / "apps").mkdir(parents=True)
        (self.root / "foo-bar").mkdir()
        self.grace = mock.patch.object(cleanup, "TERM_GRACE_SECONDS", 1.0)
        self.grace.start()

    def tearDown(self):
        self.grace.stop()
        self.tmp.cleanup()

    def test_stops_processes_inside_and_leaves_the_rest(self):
        inside = sleeper(self.checkout)
        nested = sleeper(self.checkout / "apps")
        sibling = sleeper(self.root / "foo-bar")
        outside = sleeper(self.root)
        try:
            self.assertEqual(cleanup.stop_processes(self.checkout), [])
            self.assertTrue(gone(inside))
            self.assertTrue(gone(nested))
            self.assertTrue(cleanup.alive(sibling))
            self.assertTrue(cleanup.alive(outside))
        finally:
            reap(inside, nested, sibling, outside)

    def test_kills_processes_that_ignore_sigterm(self):
        stubborn = sleeper(self.checkout, ignore_term=True)
        try:
            self.assertEqual(cleanup.stop_processes(self.checkout), [])
            self.assertTrue(gone(stubborn))
        finally:
            reap(stubborn)

    def test_reports_survivors(self):
        inside = sleeper(self.checkout)
        try:
            with mock.patch.object(cleanup, "send"):
                self.assertEqual(cleanup.stop_processes(self.checkout), [inside])
            self.assertTrue(cleanup.alive(inside))
        finally:
            reap(inside)


class MainTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="worktree-cleanup-test-")
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git("init", "-q", "-b", "master", cwd=self.repo)
        git(
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "init",
            cwd=self.repo,
        )
        self.worktrees = self.root / "worktrees"
        self.checkout = self.worktrees / "repo" / "young-thing"
        git("worktree", "add", "-q", str(self.checkout), cwd=self.repo)
        self.stack = mock.patch.multiple(
            cleanup,
            WORKTREES_DIR=self.worktrees,
            TERM_GRACE_SECONDS=1.0,
            notify=mock.DEFAULT,
        )
        self.notify = self.stack.start()["notify"]
        self.env = mock.patch.dict(
            os.environ, {"HERDR_PLUGIN_EVENT_JSON": event_for(self.checkout, self.repo)}
        )
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.stack.stop()
        self.tmp.cleanup()

    def test_stops_stack_then_removes_worktree(self):
        inside = sleeper(self.checkout)
        sibling = sleeper(self.checkout.parent)
        try:
            self.assertEqual(cleanup.main(), 0)
            self.assertTrue(gone(inside))
            self.assertTrue(cleanup.alive(sibling))
            self.assertFalse(self.checkout.exists())
            self.notify.assert_called_once_with("Worktree removed", str(self.checkout))
        finally:
            reap(inside, sibling)

    def test_survivor_keeps_worktree(self):
        inside = sleeper(self.checkout)
        try:
            with mock.patch.object(cleanup, "send"):
                self.assertEqual(cleanup.main(), 0)
            self.assertTrue(cleanup.alive(inside))
            self.assertTrue((self.checkout / ".git").exists())
            title, body = self.notify.call_args.args
            self.assertEqual(title, "Worktree kept")
            self.assertIn(str(inside), body)
        finally:
            reap(inside)

    def test_primary_checkout_is_never_touched(self):
        inside = sleeper(self.repo)
        event = event_for(self.repo, self.repo, linked=False)
        try:
            with (
                mock.patch.dict(os.environ, {"HERDR_PLUGIN_EVENT_JSON": event}),
                mock.patch.object(cleanup, "stop_processes") as stop,
            ):
                self.assertEqual(cleanup.main(), 0)
            stop.assert_not_called()
            self.assertTrue(cleanup.alive(inside))
            self.assertTrue((self.repo / ".git").is_dir())
        finally:
            reap(inside)


if __name__ == "__main__":
    unittest.main()
