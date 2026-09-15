import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pickup  # noqa: E402

PR = {
    "baseRefName": "main",
    "baseRefOid": "base-oid",
    "headRefName": "young/finish-widget",
    "headRefOid": "head-oid",
    "headRepository": {"nameWithOwner": "acme/widget"},
    "isDraft": True,
    "mergeStateStatus": "CLEAN",
    "number": 42,
    "reviewDecision": "",
    "state": "OPEN",
    "title": "Finish the widget",
    "url": "https://github.com/acme/widget/pull/42",
}


def git(root, *args):
    return subprocess.run(
        ["git", *args], cwd=root, capture_output=True, text=True, check=True
    ).stdout.strip()


class RepositoryParsingTest(unittest.TestCase):
    def test_pull_request_url_identifies_the_base_repository(self):
        self.assertEqual(
            pickup.repository_from_pr_url(PR["url"]),
            pickup.Repository("github.com", "acme/widget"),
        )

    def test_https_ssh_and_scp_remotes_are_understood(self):
        wanted = pickup.Repository("github.com", "acme/widget")
        for remote in (
            "https://github.com/acme/widget.git",
            "ssh://git@github.com/acme/widget.git",
            "git@github.com:acme/widget.git",
        ):
            with self.subTest(remote=remote):
                self.assertEqual(pickup.repository_from_remote(remote), wanted)

    def test_an_unrelated_path_is_not_a_pull_request(self):
        with self.assertRaises(SystemExit):
            pickup.repository_from_pr_url("https://github.com/acme/widget/issues/42")


class MatchingRemoteTest(unittest.TestCase):
    def test_origin_wins_when_more_than_one_remote_matches(self):
        remotes = [
            ("upstream", pickup.Repository("github.com", "acme/widget")),
            ("origin", pickup.Repository("github.com", "ACME/WIDGET")),
        ]
        with mock.patch.object(pickup, "remotes", return_value=remotes):
            self.assertEqual(
                pickup.matching_remote(
                    "/repo", pickup.Repository("github.com", "acme/widget")
                ),
                "origin",
            )

    def test_a_different_repository_does_not_match(self):
        with mock.patch.object(
            pickup,
            "remotes",
            return_value=[("origin", pickup.Repository("github.com", "acme/gadget"))],
        ):
            self.assertIsNone(
                pickup.matching_remote(
                    "/repo", pickup.Repository("github.com", "acme/widget")
                )
            )


class FindCheckoutTest(unittest.TestCase):
    def test_an_explicit_checkout_is_validated_against_the_pr(self):
        wanted = pickup.Repository("github.com", "acme/widget")
        with (
            mock.patch.object(
                pickup.kickoff,
                "main_checkout",
                return_value=(["--workspace", "w2"], "/repos/widget", []),
            ),
            mock.patch.object(pickup, "matching_remote", return_value="origin"),
        ):
            self.assertEqual(
                pickup.find_checkout(wanted, cwd="/repos/widget"),
                pickup.Checkout(["--workspace", "w2"], "/repos/widget", [], "origin"),
            )

    def test_the_pr_repository_is_found_across_open_workspaces(self):
        wanted = pickup.Repository("github.com", "acme/widget")
        workspaces = [
            {
                "workspace_id": "w1",
                "worktree": {"repo_root": "/repos/other"},
            },
            {
                "workspace_id": "w2",
                "worktree": {"repo_root": "/repos/widget"},
            },
            {
                "workspace_id": "w9",
                "worktree": {"repo_root": "/repos/widget"},
            },
        ]

        def match(root, _wanted):
            return "upstream" if root == "/repos/widget" else None

        with (
            mock.patch.object(pickup.kickoff, "workspaces", return_value=workspaces),
            mock.patch.object(pickup, "matching_remote", side_effect=match),
            mock.patch.object(
                pickup.kickoff,
                "main_checkout",
                return_value=(["--workspace", "w2"], "/repos/widget", []),
            ) as main_checkout,
        ):
            checkout = pickup.find_checkout(wanted)

        self.assertEqual(checkout.remote, "upstream")
        main_checkout.assert_called_once_with(None, "w2", "/repos/widget")

    def test_no_open_checkout_gives_an_actionable_error(self):
        with (
            mock.patch.object(pickup.kickoff, "workspaces", return_value=[]),
            self.assertRaisesRegex(SystemExit, "open its main checkout or pass --cwd"),
        ):
            pickup.find_checkout(pickup.Repository("github.com", "acme/widget"))


class SyncLocalBranchTest(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory(prefix="pickup-test-")
        self.root = self.tempdir.name
        git(self.root, "init", "-b", "main")
        git(self.root, "config", "user.name", "Test")
        git(self.root, "config", "user.email", "test@example.com")
        self.commit("base", "base")
        self.base = git(self.root, "rev-parse", "HEAD")

    def tearDown(self):
        self.tempdir.cleanup()

    def commit(self, contents, message):
        Path(self.root, "file.txt").write_text(contents, encoding="utf-8")
        git(self.root, "add", "file.txt")
        git(self.root, "commit", "-m", message)

    def set_pr_ref(self, revision):
        git(self.root, "update-ref", "refs/remotes/origin/pull/42", revision)

    def sync(self, known=None):
        return pickup.sync_local_branch(
            self.root,
            "feature",
            "refs/remotes/origin/pull/42",
            "refs/remotes/origin/feature",
            known,
        )

    def test_a_missing_branch_will_be_recreated_at_the_pr_head(self):
        self.set_pr_ref(self.base)
        result = self.sync()
        self.assertIn("recreate feature", result.summary)
        self.assertFalse(pickup.ref_exists(self.root, "refs/heads/feature"))

    def test_a_branch_behind_the_pr_is_fast_forwarded(self):
        git(self.root, "branch", "feature", self.base)
        self.commit("remote", "remote")
        remote = git(self.root, "rev-parse", "HEAD")
        self.set_pr_ref(remote)

        result = self.sync()

        self.assertIn("fast-forwarded", result.summary)
        self.assertEqual(git(self.root, "rev-parse", "feature"), remote)

    def test_a_checked_out_branch_is_not_moved_behind_its_back(self):
        git(self.root, "branch", "feature", self.base)
        self.commit("remote", "remote")
        remote = git(self.root, "rev-parse", "HEAD")
        self.set_pr_ref(remote)

        result = self.sync({"path": "/worktrees/widget/feature"})

        self.assertIn("checked out", result.warning)
        self.assertEqual(git(self.root, "rev-parse", "feature"), self.base)

    def test_local_commits_ahead_of_the_pr_are_preserved(self):
        self.set_pr_ref(self.base)
        git(self.root, "switch", "-c", "feature")
        self.commit("local", "local")
        local = git(self.root, "rev-parse", "HEAD")

        result = self.sync()

        self.assertIn("unpushed commits were preserved", result.warning)
        self.assertEqual(git(self.root, "rev-parse", "feature"), local)

    def test_diverged_history_is_preserved_for_the_agent_to_reconcile(self):
        git(self.root, "switch", "-c", "feature")
        self.commit("local", "local")
        local = git(self.root, "rev-parse", "HEAD")
        git(self.root, "switch", "main")
        self.commit("remote", "remote")
        self.set_pr_ref("main")

        result = self.sync()

        self.assertIn("diverged", result.warning)
        self.assertEqual(git(self.root, "rev-parse", "feature"), local)


class BriefTest(unittest.TestCase):
    def test_the_first_pass_is_read_only_and_stops_for_the_user(self):
        sync = pickup.BranchSync(
            "refs/remotes/origin/pull/42",
            "refs/remotes/origin/young/finish-widget",
            "fetched",
            "local history diverged",
        )
        brief = pickup.make_brief(PR, PR["headRefName"], sync, "focus on the review")
        self.assertIn("draft pull request #42", brief)
        self.assertIn(PR["url"], brief)
        self.assertIn("orientation only", brief)
        self.assertIn("Do not modify files", brief)
        self.assertIn("inline comments", brief)
        self.assertIn("send a concise re-centering report", brief)
        self.assertIn("Wait for the user to choose the next step", brief)
        self.assertIn("local history diverged", brief)
        self.assertIn("focus on the review", brief)
        self.assertIn("does not authorize implementation", brief)
        self.assertNotIn("Continue unfinished work", brief)

    def test_the_reorientation_report_is_read_from_the_worktree_agent(self):
        completed = mock.Mock(stdout="The PR is waiting on review.\n")
        with mock.patch.object(pickup, "run", return_value=completed) as run:
            self.assertEqual(
                pickup.read_agent_report("w9:p1"), "The PR is waiting on review."
            )
        run.assert_called_once_with(
            [
                "herdr",
                "agent",
                "read",
                "w9:p1",
                "--source",
                "recent-unwrapped",
                "--lines",
                "160",
            ]
        )


class DryRunTest(unittest.TestCase):
    def test_dry_run_does_not_fetch_or_open_a_worktree(self):
        checkout = pickup.Checkout(["--workspace", "w2"], "/repos/widget", [], "origin")
        with (
            mock.patch.dict(os.environ, {"HERDR_ENV": "1"}),
            mock.patch.object(pickup, "pull_request", return_value=PR),
            mock.patch.object(pickup, "find_checkout", return_value=checkout),
            mock.patch.object(pickup, "run", return_value=mock.Mock(returncode=0)),
            mock.patch.object(pickup, "fetch_pull_request") as fetch,
            mock.patch.object(pickup, "herdr") as herdr,
        ):
            self.assertEqual(pickup.main([PR["url"], "--dry-run"]), 0)
        fetch.assert_not_called()
        herdr.assert_not_called()

    def test_a_merged_pr_is_rejected_by_default(self):
        merged = {**PR, "state": "MERGED"}
        with (
            mock.patch.dict(os.environ, {"HERDR_ENV": "1"}),
            mock.patch.object(pickup, "pull_request", return_value=merged),
            self.assertRaisesRegex(SystemExit, "pass --allow-closed"),
        ):
            pickup.main([PR["url"], "--dry-run"])


if __name__ == "__main__":
    unittest.main()
