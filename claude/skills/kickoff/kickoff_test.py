import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import kickoff  # noqa: E402

MAIN = {
    "workspace_id": "w2",
    "worktree": {
        "repo_name": "widget",
        "repo_root": "/repos/widget",
        "checkout_path": "/repos/widget",
        "is_linked_worktree": False,
    },
}
LINKED = {
    "workspace_id": "w9",
    "worktree": {
        "repo_name": "widget",
        "repo_root": "/repos/widget",
        "checkout_path": "/worktrees/widget/mine-thing",
        "is_linked_worktree": True,
    },
}
OTHER = {
    "workspace_id": "w1",
    "worktree": {
        "repo_name": "gadget",
        "repo_root": "/repos/gadget",
        "checkout_path": "/repos/gadget",
        "is_linked_worktree": False,
    },
}


def fake_herdr(**responses):
    """Dispatch on the herdr subcommand, so a test only states what it needs."""

    def call(*args, **kwargs):
        key = "_".join(args[:2]).replace("-", "_")
        if key not in responses:
            raise AssertionError(f"unexpected herdr call: {' '.join(args)}")
        payload = responses[key]
        return payload(*args) if callable(payload) else payload

    return call


class SplitAgentArgsTest(unittest.TestCase):
    def test_without_a_separator_everything_is_ours(self):
        self.assertEqual(
            kickoff.split_agent_args(["slug", "--dry-run"]), (["slug", "--dry-run"], [])
        )

    def test_our_options_survive_a_trailing_brief(self):
        argv, extra = kickoff.split_agent_args(
            ["slug", "do the thing", "--repo", "widget"]
        )
        self.assertEqual(argv, ["slug", "do the thing", "--repo", "widget"])
        self.assertEqual(extra, [])

    def test_the_separator_hands_the_rest_to_the_agent(self):
        argv, extra = kickoff.split_agent_args(
            ["slug", "--focus", "--", "--chrome", "-p"]
        )
        self.assertEqual(argv, ["slug", "--focus"])
        self.assertEqual(extra, ["--chrome", "-p"])

    def test_a_dangling_separator_adds_nothing(self):
        self.assertEqual(kickoff.split_agent_args(["slug", "--"]), (["slug"], []))


class SlugifyTest(unittest.TestCase):
    def test_punctuation_and_case_collapse_to_dashes(self):
        self.assertEqual(kickoff.slugify("Signup rate limit!"), "signup-rate-limit")

    def test_edges_are_trimmed_even_after_truncation(self):
        self.assertEqual(kickoff.slugify("--tidy--"), "tidy")
        self.assertEqual(len(kickoff.slugify("x" * 40)), 32)
        self.assertFalse(kickoff.slugify(f"{'y' * 32} tail").endswith("-"))

    def test_a_slug_with_nothing_in_it_is_empty(self):
        self.assertEqual(kickoff.slugify("!!!"), "")


class AgentNameTest(unittest.TestCase):
    def name(self, slug, live=()):
        agents = {"agent_list": {"result": {"agents": [{"name": n} for n in live]}}}
        with mock.patch.object(kickoff, "herdr", fake_herdr(**agents)):
            return kickoff.agent_name(slug)

    def test_a_free_slug_is_used_as_is(self):
        self.assertEqual(self.name("signup", ["other"]), "signup")

    def test_a_leading_digit_is_prefixed(self):
        self.assertEqual(self.name("2fa"), "a2fa")

    def test_a_live_name_is_not_reused(self):
        self.assertEqual(self.name("signup", ["signup", "signup-2"]), "signup-3")


class MainCheckoutTest(unittest.TestCase):
    WORKTREES = [{"branch": "main", "path": "/repos/widget"}]

    def test_repo_name_finds_the_main_checkout(self):
        with mock.patch.object(
            kickoff,
            "herdr",
            fake_herdr(
                workspace_list={"result": {"workspaces": [LINKED, MAIN]}},
                worktree_list={"result": {"worktrees": self.WORKTREES}},
            ),
        ):
            self.assertEqual(
                kickoff.main_checkout("widget", None, None),
                (["--workspace", "w2"], "/repos/widget", self.WORKTREES),
            )

    def test_a_repo_with_no_open_workspace_fails_before_creating_anything(self):
        with mock.patch.object(
            kickoff,
            "herdr",
            fake_herdr(workspace_list={"result": {"workspaces": [OTHER]}}),
        ):
            with self.assertRaises(SystemExit):
                kickoff.main_checkout("widget", None, None)

    def test_a_linked_worktree_resolves_up_to_its_parent(self):
        calls = fake_herdr(
            worktree_list={
                "result": {
                    "source": {"repo_root": "/repos/widget"},
                    "worktrees": self.WORKTREES,
                }
            },
            workspace_list={"result": {"workspaces": [LINKED, MAIN]}},
        )
        with mock.patch.object(kickoff, "herdr", calls):
            self.assertEqual(
                kickoff.main_checkout(None, "w9", None),
                (["--workspace", "w2"], "/repos/widget", self.WORKTREES),
            )

    def test_a_closed_parent_workspace_falls_back_to_its_path(self):
        calls = fake_herdr(
            worktree_list={
                "result": {
                    "source": {"repo_root": "/repos/widget"},
                    "worktrees": self.WORKTREES,
                }
            },
            workspace_list={"result": {"workspaces": [LINKED]}},
        )
        with mock.patch.object(kickoff, "herdr", calls):
            self.assertEqual(
                kickoff.main_checkout(None, "w9", None),
                (["--cwd", "/repos/widget"], "/repos/widget", self.WORKTREES),
            )


class ExistingWorktreeTest(unittest.TestCase):
    WORKTREES = [
        {"branch": "main", "path": "/repos/widget"},
        {"branch": "mine/thing", "path": "/worktrees/widget/mine-thing"},
    ]

    def test_a_known_branch_is_found_by_name(self):
        self.assertEqual(
            kickoff.existing_worktree(self.WORKTREES, "mine/thing")["path"],
            "/worktrees/widget/mine-thing",
        )

    def test_an_unknown_branch_is_not(self):
        self.assertIsNone(kickoff.existing_worktree(self.WORKTREES, "mine/other"))


class ShellReadyTest(unittest.TestCase):
    def ready(self, info):
        with mock.patch.object(
            kickoff,
            "herdr",
            fake_herdr(pane_process_info={"result": {"process_info": info}}),
        ):
            return kickoff.shell_ready("w1:p1")

    def test_a_bare_prompt_is_ready(self):
        self.assertTrue(self.ready({"shell_pid": 7, "foreground_processes": []}))

    def test_the_shell_in_the_foreground_is_still_a_prompt(self):
        self.assertTrue(
            self.ready({"shell_pid": 7, "foreground_processes": [{"pid": 7}]})
        )

    def test_a_running_command_is_not_ready(self):
        self.assertFalse(
            self.ready(
                {"shell_pid": 7, "foreground_processes": [{"pid": 7}, {"pid": 9}]}
            )
        )

    def test_a_pane_herdr_cannot_describe_is_not_ready(self):
        self.assertFalse(self.ready({}))


class BranchPrefixTest(unittest.TestCase):
    def test_the_git_email_becomes_the_branch_prefix(self):
        result = mock.Mock(stdout="Ada.Lovelace@Example.com\n")
        with mock.patch.object(kickoff.subprocess, "run", return_value=result):
            self.assertEqual(kickoff.branch_prefix("/repos/widget"), "ada-lovelace")

    def test_no_configured_email_means_no_prefix(self):
        with mock.patch.object(
            kickoff.subprocess, "run", return_value=mock.Mock(stdout="\n")
        ):
            self.assertEqual(kickoff.branch_prefix("/repos/widget"), "")


if __name__ == "__main__":
    unittest.main()
