import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class ClaudeAliasesTest(unittest.TestCase):
    def test_aliases_discover_numbered_accounts_and_preserve_arguments(self):
        if not shutil.which("zsh"):
            self.skipTest("zsh is not installed")
        rc = Path(__file__).with_name("zshrc").read_text()
        aliases = rc[
            rc.index('alias c="') : rc.index("unset _claude_dir _claude_number")
        ]
        with tempfile.TemporaryDirectory(prefix="claude aliases ") as tmpdir:
            home = Path(tmpdir)
            for name in (".claude2", ".claude99", ".claude1000"):
                (home / name).mkdir()
            result = subprocess.run(
                [
                    "zsh",
                    "-f",
                    "-c",
                    aliases
                    + """
claude() { printf '%s\\n' "$CLAUDE_CONFIG_DIR" "$@"; }
eval 'c99 "two words"'
eval 'c1000 --resume'
""",
                ],
                env={**os.environ, "HOME": str(home)},
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(
                result.stdout.splitlines(),
                [
                    str(home / ".claude99"),
                    "--chrome",
                    "two words",
                    str(home / ".claude1000"),
                    "--chrome",
                    "--resume",
                ],
            )


class HistoryFilterTest(unittest.TestCase):
    def test_session_resumes_stay_out_of_history(self):
        if not shutil.which("zsh"):
            self.skipTest("zsh is not installed")
        rc = Path(__file__).with_name("zshrc").read_text()
        hook = rc[rc.index("zshaddhistory() {") :]
        hook = hook[: hook.index("\n}\n") + 3]
        uuid = "0f98ec83-f054-47e2-a199-8e8335c1d699"
        lines = {
            f"cseat run --size S --handoff -- --resume {uuid}\n": "1",
            f"env -u CLAUDE_CONFIG_DIR claude --chrome --resume {uuid}\n": "1",
            f"claude --resume={uuid}\n": "1",
            "claude --resume\n": "0",
            "git status\n": "0",
        }
        for line, kept in lines.items():
            result = subprocess.run(
                ["zsh", "-f", "-c", hook + 'zshaddhistory "$1"; print $?', "_", line],
                text=True,
                capture_output=True,
                check=True,
            )
            self.assertEqual(result.stdout.strip(), kept, line)


if __name__ == "__main__":
    unittest.main()
