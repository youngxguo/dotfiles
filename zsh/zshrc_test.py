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


if __name__ == "__main__":
    unittest.main()
