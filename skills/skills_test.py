"""Every skill directory ships a SKILL.md whose frontmatter names it."""

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SKILL_TREES = ("skills", "claude/skills")


def frontmatter(path):
    match = re.match(r"\A---\n(.*?)\n---\n", path.read_text(encoding="utf-8"), re.S)
    if not match:
        return None
    fields = {}
    for line in match.group(1).splitlines():
        key, sep, value = line.partition(":")
        if sep and not line.startswith(" "):
            fields[key.strip()] = value.strip().strip("\"'")
    return fields


class SkillMetadataTest(unittest.TestCase):
    def test_every_skill_names_and_describes_itself(self):
        skills = sorted(
            path for tree in SKILL_TREES for path in (REPO / tree).glob("*/SKILL.md")
        )
        self.assertTrue(skills)
        for skill in skills:
            with self.subTest(skill=skill.relative_to(REPO)):
                fields = frontmatter(skill)
                self.assertIsNotNone(fields, "missing frontmatter")
                self.assertEqual(fields.get("name"), skill.parent.name)
                self.assertTrue(fields.get("description"), "missing description")

    def test_public_skills_carry_agent_metadata(self):
        for skill in sorted((REPO / "skills").glob("*/SKILL.md")):
            with self.subTest(skill=skill.parent.name):
                agent = skill.parent / "agents/openai.yaml"
                self.assertTrue(agent.is_file(), f"missing {agent}")
                self.assertIn("interface:", agent.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
