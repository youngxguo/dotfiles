import importlib.util
import os
import unittest
from pathlib import Path
from unittest import mock


path = Path(__file__).with_name("worktree_tabs.py")
spec = importlib.util.spec_from_file_location("worktree_tabs", path)
worktree_tabs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worktree_tabs)


class WorktreeTabsTest(unittest.TestCase):
    def test_opens_vim_and_focused_chat_tabs(self):
        event = (
            '{"data":{"workspace":{"workspace_id":"w2",'
            '"active_tab_id":"w2:t1"},"worktree":{"path":"/tmp/repo"}}}'
        )
        responses = [
            {"result": {"panes": [{"pane_id": "w2:p1", "tab_id": "w2:t1"}]}},
            {},
            {"result": {"root_pane": {"pane_id": "w2:p2"}}},
            {},
            {},
        ]

        with mock.patch.dict(os.environ, {"HERDR_PLUGIN_EVENT_JSON": event}):
            with mock.patch.object(worktree_tabs, "herdr", side_effect=responses) as herdr:
                worktree_tabs.configure_worktree()

        self.assertEqual(
            [call.args for call in herdr.call_args_list],
            [
                ("pane", "list", "--workspace", "w2"),
                ("tab", "rename", "w2:t1", "vim"),
                (
                    "tab", "create", "--workspace", "w2", "--cwd", "/tmp/repo",
                    "--label", "chat", "--focus",
                ),
                ("pane", "run", "w2:p1", "nvim"),
                ("pane", "run", "w2:p2", "pi"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
