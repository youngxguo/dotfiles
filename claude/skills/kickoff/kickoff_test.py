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


class SlugifyTest(unittest.TestCase):
    def test_punctuation_and_case_collapse_to_dashes(self):
        self.assertEqual(kickoff.slugify("Signup rate limit!"), "signup-rate-limit")

    def test_edges_are_trimmed_even_after_truncation(self):
        self.assertEqual(kickoff.slugify("--tidy--"), "tidy")
        self.assertEqual(len(kickoff.slugify("x" * 40)), 32)
        self.assertFalse(kickoff.slugify(f"{'y' * 32} tail").endswith("-"))

    def test_a_slug_with_nothing_in_it_is_empty(self):
        self.assertEqual(kickoff.slugify("!!!"), "")


class MainTest(unittest.TestCase):
    def test_a_task_is_required(self):
        with self.assertRaisesRegex(SystemExit, "needs a task"):
            kickoff.main(["new-work"])


class CseatTest(unittest.TestCase):
    def test_short_account_aliases_become_cseat_names(self):
        self.assertEqual(kickoff.cseat_name("c1"), "claude")
        self.assertEqual(kickoff.cseat_name("c6"), "claude6")
        self.assertEqual(kickoff.cseat_name("work"), "work")

    def test_default_launch_uses_fable_with_handoffs(self):
        self.assertEqual(
            kickoff.cseat_args("run", None, None),
            ["cseat", "run", "--model", "fable", "--handoff"],
        )

    def test_account_and_model_are_forwarded(self):
        self.assertEqual(
            kickoff.cseat_args("run", "c3", "opus"),
            [
                "cseat",
                "run",
                "--model",
                "opus",
                "--handoff",
                "--seat",
                "claude3",
            ],
        )

    def test_preflight_uses_the_same_constraints(self):
        result = mock.Mock(returncode=0, stdout="{}", stderr="")
        with (
            mock.patch.object(kickoff, "cseat_available", return_value=True),
            mock.patch.object(
                kickoff, "run_in_login_shell", return_value=result
            ) as run,
        ):
            self.assertTrue(kickoff.preflight_cseat("c3", "opus"))
        run.assert_called_once_with(
            [
                "cseat",
                "pick",
                "--model",
                "opus",
                "--size",
                "M",
                "--json",
                "--dry-run",
                "--seat",
                "claude3",
            ]
        )

    def test_preflight_reports_cseat_refusal(self):
        result = mock.Mock(
            returncode=2,
            stdout='{"reason": "no seat has headroom"}',
            stderr="",
        )
        with (
            mock.patch.object(kickoff, "cseat_available", return_value=True),
            mock.patch.object(kickoff, "run_in_login_shell", return_value=result),
        ):
            with self.assertRaisesRegex(SystemExit, "no seat has headroom"):
                kickoff.preflight_cseat(None, None)

    def test_missing_cseat_uses_the_portable_fallback(self):
        with mock.patch.object(kickoff, "cseat_available", return_value=False):
            self.assertFalse(kickoff.preflight_cseat(None, None))
        self.assertEqual(
            kickoff.plain_claude_command(None, None),
            "env -u CLAUDE_CONFIG_DIR ANTHROPIC_MODEL=fable claude",
        )

    def test_launch_runs_cseat_in_the_pane(self):
        with mock.patch.object(kickoff, "herdr") as herdr:
            kickoff.launch_claude("w1:p2", lambda _: None, "c3", "opus", True)
        herdr.assert_called_once_with(
            "pane",
            "run",
            "w1:p2",
            "cseat run --model opus --handoff --seat claude3",
        )


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
    def test_repo_name_finds_the_main_checkout(self):
        with mock.patch.object(
            kickoff,
            "herdr",
            fake_herdr(workspace_list={"result": {"workspaces": [LINKED, MAIN]}}),
        ):
            self.assertEqual(
                kickoff.main_checkout("widget"),
                (["--workspace", "w2"], "/repos/widget"),
            )

    def test_a_repo_with_no_open_workspace_fails_before_creating_anything(self):
        with mock.patch.object(
            kickoff,
            "herdr",
            fake_herdr(workspace_list={"result": {"workspaces": [OTHER]}}),
        ):
            with self.assertRaises(SystemExit):
                kickoff.main_checkout("widget")

    def test_a_linked_worktree_resolves_up_to_its_parent(self):
        calls = fake_herdr(
            worktree_list={"result": {"source": {"repo_root": "/repos/widget"}}},
            workspace_list={"result": {"workspaces": [LINKED, MAIN]}},
        )
        with mock.patch.object(kickoff, "herdr", calls):
            self.assertEqual(
                kickoff.main_checkout(None),
                (["--workspace", "w2"], "/repos/widget"),
            )

    def test_a_closed_parent_workspace_falls_back_to_its_path(self):
        calls = fake_herdr(
            worktree_list={"result": {"source": {"repo_root": "/repos/widget"}}},
            workspace_list={"result": {"workspaces": [LINKED]}},
        )
        with mock.patch.object(kickoff, "herdr", calls):
            self.assertEqual(
                kickoff.main_checkout(None),
                (["--cwd", "/repos/widget"], "/repos/widget"),
            )


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
