import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import index  # noqa: E402


def ws(workspace_id, repo, linked=False):
    return {
        "workspace_id": workspace_id,
        "worktree": {"repo_key": f"/code/{repo}/.git", "is_linked_worktree": linked},
    }


def apply(workspaces, move):
    block, anchor = move
    rest = [w for w in workspaces if w["workspace_id"] not in block]
    moved = [w for w in workspaces if w["workspace_id"] in block]
    at = len(rest)
    if anchor is not None:
        at = [w["workspace_id"] for w in rest].index(anchor)
    return rest[:at] + moved + rest[at:]


def regrouped(workspaces):
    for _ in range(len(workspaces)):
        move = index.next_regroup(workspaces)
        if move is None:
            return [w["workspace_id"] for w in workspaces]
        workspaces = apply(workspaces, move)
    raise AssertionError("regroup did not converge")


class RegroupTest(unittest.TestCase):
    def test_contiguous_groups_need_no_move(self):
        workspaces = [ws("dot", "dotfiles"), ws("hsys", "hsys"), ws("h1", "hsys", True)]
        self.assertIsNone(index.next_regroup(workspaces))

    def test_new_worktree_moves_behind_its_parent(self):
        workspaces = [
            ws("dot", "dotfiles"),
            ws("tool", "toolbox"),
            ws("hsys", "hsys"),
            ws("h1", "hsys", True),
            ws("d1", "dotfiles", True),
        ]
        self.assertEqual(index.next_regroup(workspaces), (["d1"], "tool"))
        self.assertEqual(regrouped(workspaces), ["dot", "d1", "tool", "hsys", "h1"])

    def test_group_keeps_its_internal_order(self):
        workspaces = [
            ws("hsys", "hsys"),
            ws("h1", "hsys", True),
            ws("dot", "dotfiles"),
            ws("h2", "hsys", True),
        ]
        self.assertEqual(regrouped(workspaces), ["hsys", "h1", "h2", "dot"])

    def test_last_parent_moves_its_group_to_the_end(self):
        workspaces = [
            ws("d1", "dotfiles", True),
            ws("hsys", "hsys"),
            ws("dot", "dotfiles"),
        ]
        self.assertEqual(index.next_regroup(workspaces), (["d1"], None))
        self.assertEqual(regrouped(workspaces), ["hsys", "dot", "d1"])

    def test_worktree_without_open_parent_stays_put(self):
        workspaces = [
            ws("h1", "hsys", True),
            ws("dot", "dotfiles"),
            ws("h2", "hsys", True),
        ]
        self.assertIsNone(index.next_regroup(workspaces))

    def test_plain_workspaces_are_never_grouped(self):
        workspaces = [ws("a", "one"), {"workspace_id": "b"}, ws("c", "one")]
        self.assertIsNone(index.next_regroup(workspaces))


def agent(pane_id, num=None):
    return {"pane_id": pane_id, "tokens": {"num": num} if num else {}}


class WantedNumbersTest(unittest.TestCase):
    def test_numbers_agents_in_list_order(self):
        agents = [agent("a"), agent("b")]
        self.assertEqual(index.wanted_numbers(agents, agents), {"a": "1", "b": "2"})

    def test_skips_panes_already_correct(self):
        agents = [agent("a", "1"), agent("b", "3")]
        self.assertEqual(index.wanted_numbers(agents, agents), {"b": "2"})

    def test_clears_number_left_on_pane_whose_agent_exited(self):
        agents = [agent("a", "1")]
        panes = agents + [agent("gone", "2"), agent("shell")]
        self.assertEqual(index.wanted_numbers(agents, panes), {"gone": None})

    def test_agents_past_nine_have_no_number(self):
        agents = [agent(f"p{i}", str(i) if i <= 9 else "9") for i in range(1, 11)]
        self.assertEqual(index.wanted_numbers(agents, agents), {"p10": None})


class ReleasedPaneTest(unittest.TestCase):
    def released(self, payload):
        with mock.patch.dict(os.environ, {"HERDR_PLUGIN_EVENT_JSON": payload}):
            return index.released_pane()

    def test_release_event_names_its_pane(self):
        payload = {
            "event": "pane.agent_detected",
            "data": {
                "type": "pane_agent_detected",
                "pane_id": "w1:p2",
                "released": True,
            },
        }
        self.assertEqual(self.released(json.dumps(payload)), "w1:p2")

    def test_detection_frees_nothing(self):
        payload = {"data": {"pane_id": "w1:p2", "agent": "claude"}}
        self.assertIsNone(self.released(json.dumps(payload)))

    def test_startup_without_payload_frees_nothing(self):
        with mock.patch.dict(os.environ, clear=True):
            self.assertIsNone(index.released_pane())
        self.assertIsNone(self.released("not json"))


if __name__ == "__main__":
    unittest.main()
