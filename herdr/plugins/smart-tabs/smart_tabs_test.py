import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest import mock


path = Path(__file__).with_name("smart_tabs.py")
spec = importlib.util.spec_from_file_location("smart_tabs", path)
smart_tabs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smart_tabs)


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


class SmartTabsTest(unittest.TestCase):
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
            {
                "result": {
                    "process_info": {
                        "foreground_process_group_id": 41,
                        "foreground_processes": [
                            {"pid": 41, "argv0": "pi", "name": "node"},
                        ],
                    }
                }
            },
            {"result": {"root_pane": {"pane_id": "w2:p2"}}},
            {},
        ]
        env = {"HERDR_PLUGIN_CONTEXT_JSON": plugin_context()}

        with mock.patch.dict(os.environ, env):
            with mock.patch.object(smart_tabs, "herdr", side_effect=responses) as herdr:
                smart_tabs.create_tab()

        self.assertEqual(
            [call.args for call in herdr.call_args_list],
            [
                ("pane", "current", "--pane", "w2:p1"),
                ("pane", "process-info", "--pane", "w2:p1"),
                (
                    "tab", "create", "--workspace", "w2", "--cwd", "/tmp/repo/src",
                    "--focus",
                ),
                ("pane", "run", "w2:p2", "pi"),
            ],
        )

    def test_mirrors_any_detected_agent_command(self):
        cases = [
            ("opencode", ["opencode"], "opencode"),
            ("claude", ["claude"], "claude"),
            ("codex", ["codex"], "codex"),
            (
                "acme",
                ["/opt/Acme Agent/bin/acme", "--profile", "code review"],
                "'/opt/Acme Agent/bin/acme' --profile 'code review'",
            ),
        ]

        for agent, argv, expected_command in cases:
            with self.subTest(agent=agent):
                responses = [
                    {"result": {"pane": {"cwd": "/tmp/repo", "foreground_cwd": None}}},
                    {
                        "result": {
                            "process_info": {
                                "foreground_process_group_id": 41,
                                "foreground_processes": [
                                    {"pid": 42, "argv": ["bash", "tool.sh"]},
                                    {"pid": 41, "argv": argv},
                                ],
                            }
                        }
                    },
                    {"result": {"root_pane": {"pane_id": "w2:p2"}}},
                    {},
                ]
                env = {
                    "HERDR_PLUGIN_CONTEXT_JSON": plugin_context(
                        focused_pane_agent=agent
                    ),
                }

                with mock.patch.dict(os.environ, env):
                    with mock.patch.object(
                        smart_tabs, "herdr", side_effect=responses
                    ) as herdr:
                        smart_tabs.create_tab()

                self.assertEqual(
                    [call.args for call in herdr.call_args_list],
                    [
                        ("pane", "current", "--pane", "w2:p1"),
                        ("pane", "process-info", "--pane", "w2:p1"),
                        (
                            "tab", "create", "--workspace", "w2",
                            "--cwd", "/tmp/repo", "--focus",
                        ),
                        ("pane", "run", "w2:p2", expected_command),
                    ],
                )

    def test_creates_shell_tab_from_non_agent_pane(self):
        responses = [
            {"result": {"pane": {"cwd": "/tmp/repo", "foreground_cwd": None}}},
            {"result": {"root_pane": {"pane_id": "w2:p2"}}},
        ]
        env = {
            "HERDR_PLUGIN_CONTEXT_JSON": plugin_context(focused_pane_agent=None),
        }

        with mock.patch.dict(os.environ, env):
            with mock.patch.object(smart_tabs, "herdr", side_effect=responses) as herdr:
                smart_tabs.create_tab()

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


if __name__ == "__main__":
    unittest.main()
