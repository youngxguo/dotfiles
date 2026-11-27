import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import kickoff  # noqa: E402

RUNNING = {"runtime": {"reachable": True}}


def opened(path, kind="structured", branch="refs/heads/me/thing"):
    launch = {"outcome": {"kind": kind}} if kind else None
    return {"worktree": {"path": path, "branch": branch}, "launch": launch}


class SlugifyTest(unittest.TestCase):
    def test_punctuation_and_case_collapse_to_dashes(self):
        self.assertEqual(kickoff.slugify("Signup rate limit!"), "signup-rate-limit")

    def test_edges_are_trimmed_even_after_truncation(self):
        slug = kickoff.slugify("x" * 31 + "-tail")
        self.assertEqual(slug, "x" * 31)


class OrcaCommandTest(unittest.TestCase):
    def test_a_session_orca_started_uses_the_cli_it_names(self):
        with mock.patch.dict("os.environ", {"ORCA_CLI_COMMAND": "/opt/orca"}):
            self.assertEqual(kickoff.orca_command(), "/opt/orca")

    def test_linux_never_runs_the_bare_name(self):
        looked_up = []

        def which(name):
            looked_up.append(name)
            return f"/usr/bin/{name}"

        with (
            mock.patch.dict("os.environ", {}, clear=True),
            mock.patch.object(kickoff.sys, "platform", "linux"),
            mock.patch.object(kickoff.shutil, "which", which),
        ):
            self.assertEqual(kickoff.orca_command(), "/usr/bin/orca-ide")
        self.assertEqual(looked_up, ["orca-ide"])

    def test_a_machine_without_orca_stops_with_the_reason(self):
        with (
            mock.patch.dict("os.environ", {}, clear=True),
            mock.patch.object(kickoff.shutil, "which", return_value=None),
            mock.patch.object(kickoff, "ORCA_APP_BIN", "/nonexistent/orca"),
            self.assertRaisesRegex(SystemExit, "is missing"),
        ):
            kickoff.orca_command()


class OrcaCallTest(unittest.TestCase):
    def answer(self, stdout, returncode=0, stderr=""):
        return subprocess.CompletedProcess([], returncode, stdout, stderr)

    def call(self, completed):
        with (
            mock.patch.object(kickoff, "orca_command", return_value="orca"),
            mock.patch.object(kickoff.subprocess, "run", return_value=completed) as run,
        ):
            result = kickoff.orca("worktree", "create", "--name", "thing")
        self.assertEqual(
            run.call_args.args[0],
            ["orca", "worktree", "create", "--name", "thing", "--json"],
        )
        return result

    def test_an_ok_answer_returns_its_result(self):
        result = self.call(self.answer('{"ok": true, "result": {"a": 1}}'))
        self.assertEqual(result, {"a": 1})

    def test_orcas_error_is_the_reason(self):
        with self.assertRaisesRegex(
            SystemExit, "orca worktree create failed: repo_not_found"
        ):
            self.call(
                self.answer('{"ok": false, "error": {"code": "repo_not_found"}}', 1)
            )

    def test_output_that_is_not_json_is_the_reason(self):
        with self.assertRaisesRegex(SystemExit, "failed: command not understood"):
            self.call(self.answer("", 2, "command not understood"))


class RepoSelectorTest(unittest.TestCase):
    def test_another_repository_goes_by_its_orca_name(self):
        self.assertEqual(kickoff.repo_selector("widget"), "name:widget")

    def in_dir(self, path):
        here = os.getcwd()
        self.addCleanup(os.chdir, here)
        os.chdir(path)

    def test_a_linked_worktree_resolves_to_the_main_checkout(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        main = Path(tmp.name).resolve() / "widget"
        linked = Path(tmp.name).resolve() / "linked"
        identity = ["-c", "user.name=t", "-c", "user.email=t@example.com"]
        for cmd in (
            ["init", "-q", str(main)],
            ["-C", str(main), "commit", "-q", "--allow-empty", "-m", "one"],
            ["-C", str(main), "worktree", "add", "-q", str(linked)],
        ):
            subprocess.run(["git", *identity, *cmd], check=True, capture_output=True)
        self.in_dir(linked)
        self.assertEqual(kickoff.repo_selector(None), f"path:{main}")

    def test_outside_a_checkout_it_asks_for_a_repository(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.in_dir(tmp.name)
        with (
            mock.patch.dict("os.environ", {"GIT_CEILING_DIRECTORIES": tmp.name}),
            self.assertRaisesRegex(SystemExit, "needs a Git checkout"),
        ):
            kickoff.repo_selector(None)


class MainTest(unittest.TestCase):
    def run_main(self, argv, result=None, default="main", status=RUNNING):
        """Run main against a fake Orca; returns (create args, stdout, git calls)."""
        calls = []

        def orca(*args, **kwargs):
            calls.append(args)
            return status if args[0] == "status" else result

        out = io.StringIO()
        with (
            mock.patch.object(kickoff, "orca", orca),
            mock.patch.object(kickoff, "repo_selector", lambda repo: f"sel:{repo}"),
            mock.patch.object(kickoff, "default_branch", return_value=default),
            mock.patch.object(kickoff.subprocess, "run") as run,
            contextlib.redirect_stdout(out),
        ):
            kickoff.main(argv)
        create = next(c for c in calls if c[:2] == ("worktree", "create"))
        return create, out.getvalue(), [c.args[0] for c in run.call_args_list]

    def flag(self, create, name):
        return create[create.index(name) + 1]

    def test_default_starts_an_independent_worktree_and_lets_orca_choose(self):
        create, out, git_calls = self.run_main(
            ["Signup limit", "cap", "signups"], opened("/wt/signup-limit")
        )
        self.assertEqual(self.flag(create, "--name"), "signup-limit")
        self.assertEqual(self.flag(create, "--repo"), "sel:None")
        self.assertEqual(self.flag(create, "--agent"), "claude")
        self.assertIn("--no-parent", create)
        # Orca's Claude command picks the login and model, its setting the surface.
        for absent in ("--base-branch", "--model", "--surface", "--branch"):
            self.assertNotIn(absent, create)
        self.assertEqual(git_calls, [])
        self.assertEqual(out, "chat  me/thing from main  /wt/signup-limit\n")

    def test_the_prompt_names_the_parent_then_grills_then_carries_the_task(self):
        create, _, _ = self.run_main(["thing", "cap signups"], opened("/wt/thing"))
        prompt = self.flag(create, "--prompt")
        self.assertTrue(
            prompt.startswith(
                "This branch starts from main. Use main as the PR base unless"
            )
        )
        self.assertIn("never reply to them.\n\n" + kickoff.GRILL + "\n\n", prompt)
        self.assertTrue(prompt.endswith("\n\ncap signups"))

    def test_no_grill_sends_the_task_without_the_grilling_instruction(self):
        create, _, _ = self.run_main(
            ["--no-grill", "thing", "cap signups"], opened("/wt/thing")
        )
        prompt = self.flag(create, "--prompt")
        self.assertNotIn("grilling skill", prompt)
        self.assertTrue(prompt.endswith("never reply to them.\n\ncap signups"))

    def test_base_stacks_keeps_orcas_lineage_and_records_the_pr_base(self):
        create, out, git_calls = self.run_main(
            ["--base", "me/parent", "thing", "task"], opened("/wt/thing")
        )
        self.assertEqual(self.flag(create, "--base-branch"), "me/parent")
        self.assertNotIn("--no-parent", create)
        self.assertIn(
            "This branch starts from me/parent.", self.flag(create, "--prompt")
        )
        self.assertEqual(
            git_calls,
            [
                [
                    "git",
                    "-C",
                    "/wt/thing",
                    "config",
                    "branch.me/thing.gh-merge-base",
                    "me/parent",
                ]
            ],
        )
        self.assertIn("me/thing from me/parent", out)

    def test_a_named_model_is_passed_to_orca(self):
        create, _, _ = self.run_main(
            ["--model", "opus", "thing", "task"], opened("/wt/thing")
        )
        self.assertEqual(self.flag(create, "--model"), "opus")

    def test_another_repository_does_not_borrow_this_ones_default_branch(self):
        create, out, _ = self.run_main(
            ["--repo", "widget", "thing", "task"], opened("/wt/thing")
        )
        self.assertEqual(self.flag(create, "--repo"), "sel:widget")
        self.assertIn(
            "starts from the repository's default branch. Use it as the PR base",
            self.flag(create, "--prompt"),
        )
        self.assertIn("from the default branch", out)

    def test_the_brief_can_come_from_a_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".md") as brief:
            brief.write("a long task")
            brief.flush()
            create, _, _ = self.run_main(
                ["--brief-file", brief.name, "thing"], opened("/wt/thing")
            )
        self.assertTrue(self.flag(create, "--prompt").endswith("a long task"))

    def test_a_terminal_launch_is_reported_as_one(self):
        _, out, _ = self.run_main(["thing", "task"], opened("/wt/thing", "terminal"))
        self.assertTrue(out.startswith("terminal  "))

    def test_a_worktree_without_an_agent_fails_and_names_the_path(self):
        with self.assertRaisesRegex(SystemExit, "did not start.*at /wt/thing"):
            self.run_main(["thing", "task"], opened("/wt/thing", kind=None))

    def test_orca_not_running_stops_before_anything_is_created(self):
        calls = []

        def orca(*args, **kwargs):
            calls.append(args)
            return {"runtime": {"reachable": False}}

        with (
            mock.patch.object(kickoff, "orca", orca),
            mock.patch.object(kickoff, "repo_selector", return_value="sel"),
            self.assertRaisesRegex(SystemExit, "Orca is not running"),
        ):
            kickoff.main(["thing", "task"])
        self.assertEqual([c[0] for c in calls], ["status"])

    def test_an_empty_slug_or_task_is_refused(self):
        with self.assertRaisesRegex(SystemExit, "slug needs"):
            kickoff.main(["!!!", "task"])
        with self.assertRaisesRegex(SystemExit, "needs a task"):
            kickoff.main(["thing", " "])


if __name__ == "__main__":
    unittest.main()
