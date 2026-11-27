import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pass_work  # noqa: E402

HEAD = "a" * 40
STALE = "b" * 40
BRANCH = "me/task"
PROJECT = "github:o/r"
PRIMARY = {
    "id": "repo::/src",
    "repoId": "repo",
    "projectId": PROJECT,
    "path": "/src",
    "isMainWorktree": True,
    "branch": "refs/heads/main",
    "head": STALE,
}


def tree(head: str = HEAD, branch: str = BRANCH) -> dict:
    return {
        "id": "repo::/wt",
        "repoId": "repo",
        "projectId": PROJECT,
        "path": "/wt",
        "branch": f"refs/heads/{branch}",
        "head": head,
    }


class Orca:
    """The other machine: the worktrees it lists and what a create returns."""

    def __init__(
        self,
        there: list[dict],
        made: dict | None = None,
        prompt: str = "journaled",
        project: str | None = PROJECT,
        reached: str | None = HEAD,
    ) -> None:
        self.there = there
        self.made = made
        self.prompt = prompt
        self.project = project
        self.reached = reached
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, *args: str, timeout: int = 60) -> dict:
        self.calls.append(args)
        command = args[:2]
        if command == ("environment", "list"):
            return {"environments": [{"name": "Work Mac"}, {"name": "Home Mac"}]}
        if command == ("host", "list"):
            return {"hosts": [{"kind": "local", "machineName": "Home Mac"}]}
        if command == ("worktree", "current"):
            return {"worktree": {"id": "here::/wt", "projectId": self.project}}
        if command == ("worktree", "list"):
            return {"worktrees": self.there}
        if command == ("worktree", "create"):
            return {"worktree": self.made}
        if command == ("terminal", "create"):
            return {"terminal": {"handle": "t1"}}
        if command == ("terminal", "read"):
            said = [f"PASS-HEAD {self.reached}"] if self.reached else []
            return {"terminal": {"tail": ["$ git fetch origin", *said, "$ "]}}
        if command == ("terminal", "list"):
            return {"terminals": []}
        if command == ("agent", "launch"):
            return {
                "outcome": {"kind": "structured", "sessionId": "s1"},
                "prompt": {"outcome": self.prompt},
            }
        return {}

    def ran(self, *command: str) -> list[tuple[str, ...]]:
        return [call for call in self.calls if call[: len(command)] == command]


def git_answers(dirty: str = "", pushed: str = HEAD, branch: str = BRANCH):
    def git(*args: str) -> str:
        if args[0] == "status":
            return dirty
        if args[0] == "ls-remote":
            return f"{pushed}\trefs/heads/{branch}"
        if args[0] == "symbolic-ref":
            return branch
        return HEAD

    return git


class PassTest(unittest.TestCase):
    def passing(
        self, orca: Orca, git=None, brief: str = "do it", to: str = "work", push=None
    ) -> str | int:
        """The exit status, or the refusal the script stopped with."""
        with tempfile.TemporaryDirectory() as tmp:
            brief_file = Path(tmp) / "brief"
            brief_file.write_text(brief)
            self.out = io.StringIO()
            self.push = push or mock.Mock(
                return_value=subprocess.CompletedProcess([], 1, "", "rejected")
            )
            with (
                mock.patch.multiple(
                    pass_work,
                    orca=orca,
                    git=git or git_answers(),
                    SYNC_TIMEOUT=0,
                    close_passed_setup=mock.Mock(),
                ),
                mock.patch.object(pass_work.subprocess, "run", self.push),
                contextlib.redirect_stdout(self.out),
            ):
                try:
                    return pass_work.main(["--to", to, "--brief-file", str(brief_file)])
                except SystemExit as stopped:
                    return str(stopped.code)

    def test_a_part_of_the_name_picks_the_machine_only_when_one_has_it(self):
        cases = {"work": 0, "WORK MAC": 0, "mac": "more than one", "desk": "no paired"}
        for asked, expected in cases.items():
            with self.subTest(asked):
                result = self.passing(Orca([PRIMARY], made=tree()), to=asked)
                if expected == 0:
                    self.assertEqual(result, 0)
                else:
                    self.assertIn(expected, result)

    def test_gates_refuse_before_the_other_machine_is_touched(self):
        cases = {
            "uncommitted": (Orca([PRIMARY]), git_answers(dirty=" M a\n?? b")),
            "detached": (Orca([PRIMARY]), git_answers(branch="")),
            "cannot carry": (Orca([PRIMARY]), git_answers(branch="me/a b")),
            "push failed": (Orca([PRIMARY]), git_answers(pushed=STALE)),
            "names no project": (Orca([PRIMARY], project=None), git_answers()),
            "is empty": (Orca([PRIMARY]), git_answers()),
        }
        for said, (orca, git) in cases.items():
            with self.subTest(said):
                brief = "  \n" if said == "is empty" else "do it"
                self.assertIn(said, self.passing(orca, git, brief=brief))
                self.assertFalse(orca.ran("terminal", "create"))
                self.assertFalse(orca.ran("worktree", "create"))

    def test_a_branch_origin_lacks_is_pushed_first(self):
        pushed = {"head": STALE}

        def git(*args: str) -> str:
            if args[0] == "ls-remote":
                return f"{pushed['head']}\trefs/heads/{BRANCH}"
            return git_answers()(*args)

        def push(command, **_):
            pushed["head"] = HEAD
            return subprocess.CompletedProcess(command, 0, "", "")

        orca = Orca([PRIMARY], made=tree())
        self.assertEqual(self.passing(orca, git, push=mock.Mock(side_effect=push)), 0)
        self.assertEqual(
            self.push.call_args.args[0][-2:], ["origin", f"HEAD:refs/heads/{BRANCH}"]
        )

    def test_a_new_worktree_on_the_passed_commit_gets_the_brief(self):
        orca = Orca([PRIMARY], made=tree())
        self.assertEqual(self.passing(orca, brief="line one\n`code` $HOME 'q'"), 0)
        (launch,) = orca.ran("agent", "launch")
        prompt = launch[launch.index("--prompt") + 1]
        self.assertIn("id:repo::/wt", launch)
        self.assertIn("passed to you from the Orca on Home Mac", prompt)
        self.assertTrue(prompt.endswith("line one\n`code` $HOME 'q'"))
        self.assertIn("Work Mac", launch)
        (create,) = orca.ran("worktree", "create")
        self.assertIn(f"origin/{BRANCH}", create)
        self.assertIn("passed from Home Mac", create)
        self.assertIn("passed to Work Mac", orca.ran("worktree", "set")[-1])

    def test_the_worktree_already_on_the_branch_is_reused(self):
        orca = Orca([PRIMARY, tree()])
        self.assertEqual(self.passing(orca), 0)
        self.assertFalse(orca.ran("worktree", "create"))
        (sync,) = orca.ran("terminal", "create")
        command = sync[sync.index("--command") + 1]
        self.assertIn("git diff --quiet HEAD && git merge --ff-only", command)
        self.assertTrue(orca.ran("agent", "launch"))

    def test_no_claude_starts_on_another_commit_or_branch(self):
        cases = {
            "existing worktree stayed behind": Orca([PRIMARY, tree()], reached=STALE),
            "existing worktree never answered": Orca([PRIMARY, tree()], reached=None),
            "new worktree on a stale commit": Orca([PRIMARY], made=tree(STALE)),
            "new worktree on a renamed branch": Orca(
                [PRIMARY], made=tree(HEAD, "me/task-2")
            ),
        }
        for name, orca in cases.items():
            with self.subTest(name):
                self.assertIn("Settle it there first", self.passing(orca))
                self.assertFalse(orca.ran("agent", "launch"))
                self.assertEqual(bool(orca.ran("worktree", "rm")), bool(orca.made))
                self.assertFalse(
                    [
                        c
                        for c in orca.ran("worktree", "set")
                        if "passed to Work Mac" in c
                    ]
                )

    def test_a_renamed_branch_orca_made_is_dropped_only_when_merged(self):
        orca = Orca([PRIMARY], made=tree(HEAD, "me/task-2"))
        self.passing(orca)
        cleanup = orca.ran("terminal", "create")[-1]
        command = cleanup[cleanup.index("--command") + 1]
        self.assertIn(
            "git merge-base --is-ancestor refs/heads/me/task-2 FETCH_HEAD"
            " && git branch -D me/task-2",
            command,
        )

    def test_a_brief_that_did_not_arrive_is_said(self):
        orca = Orca([PRIMARY], made=tree(), prompt="dropped")
        self.assertIn("paste the brief", self.passing(orca))

    def test_a_dry_run_changes_nothing(self):
        orca = Orca([PRIMARY])
        with (
            mock.patch.multiple(
                pass_work, orca=orca, git=git_answers(dirty=" M a", pushed=STALE)
            ),
            contextlib.redirect_stdout(io.StringIO()) as out,
        ):
            self.assertEqual(pass_work.main(["--to", "work", "--dry-run"]), 0)
        self.assertIn("not ready: 1 uncommitted", out.getvalue())
        self.assertIn("after a push", out.getvalue())
        for changed in ("terminal", "agent"):
            self.assertFalse(orca.ran(changed))
        self.assertFalse(orca.ran("worktree", "create") + orca.ran("worktree", "set"))


if __name__ == "__main__":
    unittest.main()
