import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import sessions  # noqa: E402


def record(content, **fields):
    return {"type": "user", "message": {"content": content}, **fields}


class PromptTextTest(unittest.TestCase):
    def test_a_terminal_prompt_is_its_string(self):
        self.assertEqual(sessions.prompt_text(record("merge it")), "merge it")

    def test_an_orca_chat_prompt_is_its_text_blocks(self):
        chat = record(
            [{"type": "text", "text": "merge it"}, {"type": "image", "source": {}}],
            promptSource="sdk",
            entrypoint="orca",
        )
        self.assertEqual(sessions.prompt_text(chat), "merge it")

    def test_tool_results_and_the_interrupt_notice_are_not_prompts(self):
        result = record([{"type": "tool_result", "content": "ok"}], entrypoint="orca")
        notice = record(
            [{"type": "text", "text": "[Request interrupted by user]"}],
            entrypoint="orca",
        )
        self.assertIsNone(sessions.prompt_text(result))
        self.assertIsNone(sessions.prompt_text(notice))


class ClassifyTest(unittest.TestCase):
    def test_what_the_person_typed(self):
        self.assertEqual(sessions.classify(" merge it\n"), ("typed", "merge it"))

    def test_a_kickoff_brief_pasted_into_a_terminal_or_sent_by_orca(self):
        brief = "This branch starts from main. Use main as the PR base."
        pasted = f'<pasted_content id="1">\n{brief}'
        self.assertEqual(sessions.classify(brief), ("kickoff", brief))
        self.assertEqual(sessions.classify(pasted), ("kickoff", brief))

    def test_a_handoff(self):
        self.assertEqual(sessions.classify("Handoff from w2: go")[0], "handoff")

    def test_other_pasted_text_is_typed(self):
        pasted = '<pasted_content id="1">\nsome log'
        self.assertEqual(sessions.classify(pasted), ("typed", pasted))

    def test_orcas_restart_prompt_and_harness_records_are_nobodys_words(self):
        restart = sessions.ORCA_RESTART + " with existing commitments."
        self.assertEqual(sessions.classify(restart), (None, ""))
        self.assertEqual(sessions.classify("<task-notification>x"), (None, ""))

    def test_a_slash_command_and_a_compaction(self):
        command = "<command-name>/model</command-name><command-args>opus</command-args>"
        self.assertEqual(sessions.classify(command), ("command", "/model opus"))
        self.assertEqual(
            sessions.classify("This session is being continued from")[0], "compaction"
        )


if __name__ == "__main__":
    unittest.main()
