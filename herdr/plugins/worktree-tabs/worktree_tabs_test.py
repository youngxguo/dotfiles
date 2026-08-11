import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest import mock


path = Path(__file__).with_name("worktree_tabs.py")
spec = importlib.util.spec_from_file_location("worktree_tabs", path)
worktree_tabs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worktree_tabs)


def plugin_context(**overrides):
    context = {
        "workspace_id": "w2",
        "workspace_cwd": "/tmp/current",
        "focused_pane_id": "w2:p1",
        "focused_pane_cwd": "/tmp/current",
        "focused_pane_agent": "pi",
    }
    context.update(overrides)
    return json.dumps(context)


def plugin_event(data):
    return json.dumps({"data": data})


class WorktreeTabsTest(unittest.TestCase):
    def test_creates_pi_tab_from_pi_pane(self):
        responses = [
            {
                "result": {
                    "pane": {
                        "cwd": "/tmp/repo",
                        "foreground_cwd": "/tmp/repo/src",
                    }
                }
            },
            {"result": {"root_pane": {"pane_id": "w2:p2"}}},
            {},
        ]
        env = {"HERDR_PLUGIN_CONTEXT_JSON": plugin_context()}

        with mock.patch.dict(os.environ, env):
            with mock.patch.object(worktree_tabs, "herdr", side_effect=responses) as herdr:
                worktree_tabs.create_tab()

        self.assertEqual(
            [call.args for call in herdr.call_args_list],
            [
                ("pane", "current", "--pane", "w2:p1"),
                (
                    "tab", "create", "--workspace", "w2", "--cwd", "/tmp/repo/src",
                    "--focus",
                ),
                ("pane", "run", "w2:p2", "pi"),
            ],
        )

    def test_creates_shell_tab_from_non_pi_pane(self):
        responses = [
            {"result": {"pane": {"cwd": "/tmp/repo", "foreground_cwd": None}}},
            {"result": {"root_pane": {"pane_id": "w2:p2"}}},
        ]
        env = {
            "HERDR_PLUGIN_CONTEXT_JSON": plugin_context(focused_pane_agent=None),
        }

        with mock.patch.dict(os.environ, env):
            with mock.patch.object(worktree_tabs, "herdr", side_effect=responses) as herdr:
                worktree_tabs.create_tab()

        self.assertEqual(
            [call.args for call in herdr.call_args_list],
            [
                ("pane", "current", "--pane", "w2:p1"),
                (
                    "tab", "create", "--workspace", "w2", "--cwd", "/tmp/repo",
                    "--focus",
                ),
            ],
        )

    def assert_workspace_configured(self, event_data, expected_cwd):
        responses = [
            {},
            {"result": {"root_pane": {"pane_id": "w2:p2"}}},
            {},
            {},
        ]
        env = {
            "HERDR_PLUGIN_EVENT_JSON": plugin_event(event_data),
            "HERDR_PLUGIN_CONTEXT_JSON": plugin_context(),
        }

        with mock.patch.dict(os.environ, env):
            with mock.patch.object(worktree_tabs, "herdr", side_effect=responses) as herdr:
                worktree_tabs.configure_workspace()

        self.assertEqual(
            [call.args for call in herdr.call_args_list],
            [
                ("tab", "rename", "w2:t1", "vim"),
                (
                    "tab", "create", "--workspace", "w2", "--cwd", expected_cwd,
                    "--label", "chat", "--focus",
                ),
                ("pane", "run", "w2:p1", "nvim"),
                ("pane", "run", "w2:p2", "pi"),
            ],
        )

    def test_configures_worktree_from_worktree_event(self):
        self.assert_workspace_configured(
            {
                "workspace": {"workspace_id": "w2", "active_tab_id": "w2:t1"},
                "worktree": {"path": "/tmp/repo"},
            },
            "/tmp/repo",
        )

    def test_configures_plain_workspace_from_workspace_context(self):
        self.assert_workspace_configured(
            {"workspace": {"workspace_id": "w2", "active_tab_id": "w2:t1"}},
            "/tmp/current",
        )

    def test_ignores_workspace_event_for_worktree(self):
        event = plugin_event(
            {
                "workspace": {
                    "workspace_id": "w2",
                    "active_tab_id": "w2:t1",
                    "worktree": {"checkout_path": "/tmp/repo"},
                }
            }
        )

        with mock.patch.dict(os.environ, {"HERDR_PLUGIN_EVENT_JSON": event}):
            with mock.patch.object(worktree_tabs, "herdr") as herdr:
                worktree_tabs.configure_workspace()

        herdr.assert_not_called()


if __name__ == "__main__":
    unittest.main()
