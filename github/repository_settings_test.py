import importlib.util
import io
import unittest
from pathlib import Path
from unittest.mock import call, patch


SCRIPT = Path(__file__).with_name("repository_settings.py")
SPEC = importlib.util.spec_from_file_location("repository_settings", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
repository_settings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repository_settings)


def ruleset(ruleset_id, name="default branch", rules=None):
    return {
        "id": ruleset_id,
        "name": name,
        "conditions": {
            "ref_name": {
                "include": ["~DEFAULT_BRANCH"],
                "exclude": [],
            }
        },
        "rules": rules or [],
    }


STATUS_CHECKS = {
    "type": "required_status_checks",
    "parameters": {
        "do_not_enforce_on_create": False,
        "required_status_checks": [{"context": "validate"}],
        "strict_required_status_checks_policy": True,
    },
}


class RepositorySettingsTests(unittest.TestCase):
    def test_new_ruleset_contains_only_shared_rules(self):
        result = repository_settings.ruleset_for(None)

        self.assertEqual(
            [rule["type"] for rule in result["rules"]],
            ["deletion", "non_fast_forward", "pull_request"],
        )

    def test_existing_repository_specific_rules_are_preserved(self):
        existing = ruleset(
            42,
            rules=[
                {"type": "deletion"},
                {"type": "non_fast_forward"},
                {"type": "pull_request", "parameters": {}},
                STATUS_CHECKS,
            ],
        )

        result = repository_settings.ruleset_for(existing)

        self.assertEqual(result["rules"][-1], STATUS_CHECKS)
        self.assertEqual(
            [rule["type"] for rule in result["rules"]],
            [
                "deletion",
                "non_fast_forward",
                "pull_request",
                "required_status_checks",
            ],
        )

    def test_sync_creates_missing_ruleset(self):
        with (
            patch.object(
                repository_settings, "default_branch_ruleset", return_value=None
            ),
            patch.object(repository_settings, "write_github_api") as write,
            patch("builtins.print"),
        ):
            repository_settings.sync_repository("owner/repository")

        self.assertEqual(
            write.call_args_list[0].args[:2], ("PATCH", "repos/owner/repository")
        )
        self.assertEqual(
            write.call_args_list[1].args[:2],
            ("POST", "repos/owner/repository/rulesets"),
        )

    def test_sync_updates_existing_ruleset(self):
        existing = ruleset(42, rules=[STATUS_CHECKS])
        with (
            patch.object(
                repository_settings,
                "default_branch_ruleset",
                return_value=(42, existing),
            ),
            patch.object(repository_settings, "write_github_api") as write,
            patch("builtins.print"),
        ):
            repository_settings.sync_repository("owner/repository")

        self.assertEqual(
            write.call_args_list[1],
            call(
                "PUT",
                "repos/owner/repository/rulesets/42",
                repository_settings.ruleset_for(existing),
            ),
        )

    def test_multiple_default_branch_rulesets_are_rejected(self):
        summaries = [
            {"id": 1, "target": "branch", "source_type": "Repository"},
            {"id": 2, "target": "branch", "source_type": "Repository"},
        ]
        with patch.object(
            repository_settings,
            "read_github_api",
            side_effect=[summaries, ruleset(1, "one"), ruleset(2, "two")],
        ):
            with self.assertRaisesRegex(
                RuntimeError, "multiple default-branch rulesets"
            ):
                repository_settings.default_branch_ruleset("owner/repository")

    def test_repository_argument_is_required(self):
        with patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(repository_settings.main([]), 2)


if __name__ == "__main__":
    unittest.main()
