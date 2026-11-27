import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("statusline-command.sh")
PALETTE = ("34", "36", "33", "32", "31", "35", "95")


def setUpModule():
    # The script falls back to CLAUDE_CONFIG_DIR when a transcript path names
    # no account, so a run from a numbered Claude login would report that login.
    patcher = mock.patch.dict(os.environ)
    patcher.start()
    os.environ.pop("CLAUDE_CONFIG_DIR", None)
    unittest.addModuleCleanup(patcher.stop)


class StatuslineTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def statusline(self, config_dir, workspace=None, **env):
        payload = {
            "model": {"display_name": "Fable 5.1"},
            "transcript_path": str(config_dir / "projects" / "test.jsonl"),
            "workspace": {"current_dir": str(workspace or self.root)},
        }
        return subprocess.run(
            ["sh", str(SCRIPT)],
            input=json.dumps(payload),
            text=True,
            check=True,
            capture_output=True,
            env={**os.environ, "HOME": str(self.root / "home"), **env},
        ).stdout

    def account_color(self, account):
        name = f".claude{account[1:]}" if account.startswith("c") else account
        out = self.statusline(self.root / name)
        shown = re.match(r"\033\[01;(\d+)m(.*?)\033\[00m", out)
        self.assertIsNotNone(shown, out)
        self.assertEqual(shown.group(2), account)
        return shown.group(1)

    def test_every_account_gets_its_label_in_a_palette_color(self):
        for account in ("c1", "c7", "c9", "c99", "c1000", ".claude-test", ".claude-é"):
            with self.subTest(account=account):
                self.assertIn(self.account_color(account), PALETTE)

    def test_numbered_accounts_cycle_through_the_palette(self):
        self.assertEqual(self.account_color("c1"), PALETTE[0])
        self.assertEqual(self.account_color("c7"), PALETTE[6])
        self.assertEqual(self.account_color("c8"), PALETTE[0])

    def test_account_label_is_the_cseat_seat_name(self):
        config_dir = self.root / ".claude-work"
        config_dir.mkdir()
        cseat_config = self.root / "xdg" / "cseat" / "config.toml"
        cseat_config.parent.mkdir(parents=True)
        cseat_config.write_text(
            f'[seats.yc1]\ndir = "{config_dir}"\n', encoding="utf-8"
        )
        out = self.statusline(config_dir, XDG_CONFIG_HOME=str(self.root / "xdg"))
        self.assertRegex(out, r"^\033\[01;\d+myc1\033\[00m")

    def test_account_email_follows_the_label(self):
        config_dir = self.root / ".claude8"
        config_dir.mkdir()
        (config_dir / ".claude.json").write_text(
            json.dumps({"oauthAccount": {"emailAddress": "young@example.com"}}),
            encoding="utf-8",
        )
        out = self.statusline(config_dir)
        self.assertIn("c8\033[00m \033[02myoung@example.com\033[00m | ", out)

    def test_model_follows_the_account(self):
        out = self.statusline(self.root / ".claude")
        self.assertIn("c1\033[00m | \033[01;35mFable 5.1\033[00m", out)

    def test_branch_is_shown_inside_a_repository(self):
        workspace = self.root / "workspace"
        branch = "young/ui-design-system-guidance"
        subprocess.run(["git", "init", "-q", str(workspace)], check=True)
        git = ["git", "-C", str(workspace)]
        subprocess.run(
            [*git, "symbolic-ref", "HEAD", f"refs/heads/{branch}"], check=True
        )
        subprocess.run(
            [
                *git,
                "-c",
                "user.name=test",
                "-c",
                "user.email=test@example.com",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "initial",
            ],
            check=True,
        )
        out = self.statusline(self.root / ".claude", workspace)
        self.assertIn(f" | \033[01;32m\ue725 {branch}\033[00m", out)

    def test_no_branch_is_shown_outside_a_repository(self):
        out = self.statusline(
            self.root / ".claude", GIT_CEILING_DIRECTORIES=str(self.root)
        )
        self.assertNotIn("\033[01;32m", out)


if __name__ == "__main__":
    unittest.main()
