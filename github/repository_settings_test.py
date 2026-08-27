import importlib.util
import io
import subprocess
import unittest
from pathlib import Path
from unittest.mock import call, patch

SCRIPT = Path(__file__).with_name("repository_settings.py")
SPEC = importlib.util.spec_from_file_location("repository_settings", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"could not load {SCRIPT}")
repository_settings = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repository_settings)


def ruleset(
    ruleset_id: int,
    name: str = "default branch",
    rules: list[dict[str, object]] | None = None,
) -> dict[str, object]:
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


STATUS_CHECK_PARAMETERS: dict[str, object] = {
    "do_not_enforce_on_create": False,
    "required_status_checks": [{"context": "validate"}],
    "strict_required_status_checks_policy": True,
}
STATUS_CHECKS: dict[str, object] = {
    "type": "required_status_checks",
    "parameters": STATUS_CHECK_PARAMETERS,
}

NONSTRICT_STATUS_CHECKS: dict[str, object] = {
    **STATUS_CHECKS,
    "parameters": {
        **STATUS_CHECK_PARAMETERS,
        "strict_required_status_checks_policy": False,
    },
}

REQUIRED_SIGNATURES: dict[str, object] = {"type": "required_signatures"}


class RepositorySettingsTests(unittest.TestCase):
    def test_merged_branches_are_deleted(self):
        self.assertIs(
            repository_settings.REPOSITORY_SETTINGS["delete_branch_on_merge"], True
        )

    def test_new_ruleset_does_not_invent_status_checks(self):
        result = repository_settings.ruleset_for(None)

        self.assertEqual(
            [rule["type"] for rule in result["rules"]],
            ["deletion", "non_fast_forward", "pull_request"],
        )

    def test_direct_push_option_removes_pull_request_requirement(self):
        existing = ruleset(42, rules=[repository_settings.PULL_REQUEST_RULE])

        result = repository_settings.ruleset_for(existing, allow_direct_push=True)

        self.assertEqual(result["rules"], repository_settings.BRANCH_RULES)

    def test_direct_push_option_is_idempotent(self):
        first = repository_settings.ruleset_for(None, allow_direct_push=True)

        second = repository_settings.ruleset_for(first, allow_direct_push=True)

        self.assertEqual(second, first)

    def test_default_restores_pull_request_requirement(self):
        direct_push_ruleset = repository_settings.ruleset_for(
            None, allow_direct_push=True
        )

        result = repository_settings.ruleset_for(direct_push_ruleset)

        self.assertEqual(
            [rule["type"] for rule in result["rules"]],
            ["deletion", "non_fast_forward", "pull_request"],
        )

    def test_existing_required_status_checks_are_nonstrict(self):
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

        self.assertEqual(
            result["rules"],
            [*repository_settings.branch_rules_for(False), NONSTRICT_STATUS_CHECKS],
        )

    def test_existing_unmanaged_rules_are_preserved(self):
        existing = ruleset(42, rules=[STATUS_CHECKS, REQUIRED_SIGNATURES])

        result = repository_settings.ruleset_for(existing)

        self.assertEqual(
            result["rules"],
            [
                *repository_settings.branch_rules_for(False),
                NONSTRICT_STATUS_CHECKS,
                REQUIRED_SIGNATURES,
            ],
        )

    def test_sync_creates_missing_ruleset(self):
        with (
            patch.object(
                repository_settings, "default_branch_ruleset", return_value=None
            ),
            patch.object(repository_settings, "write_github_api") as write,
            patch.object(
                repository_settings, "remove_legacy_pull_request_rule"
            ) as remove,
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
        remove.assert_called_once_with("owner/repository")

    def test_sync_updates_existing_ruleset(self):
        existing = ruleset(42, rules=[STATUS_CHECKS])
        with (
            patch.object(
                repository_settings,
                "default_branch_ruleset",
                return_value=(42, existing),
            ),
            patch.object(repository_settings, "write_github_api") as write,
            patch.object(repository_settings, "remove_legacy_pull_request_rule"),
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

    def test_legacy_pull_request_rule_is_removed_from_default_branch(self):
        with (
            patch.object(
                repository_settings,
                "read_github_api",
                return_value={"default_branch": "release/current"},
            ),
            patch.object(repository_settings, "delete_github_api") as delete,
        ):
            repository_settings.remove_legacy_pull_request_rule("owner/repository")

        delete.assert_called_once_with(
            "repos/owner/repository/branches/release%2Fcurrent/"
            "protection/required_pull_request_reviews"
        )

    def test_missing_legacy_pull_request_rule_is_ignored(self):
        response = subprocess.CompletedProcess(
            args=[], returncode=1, stdout="", stderr="gh: not found (HTTP 404)"
        )
        with patch.object(repository_settings.subprocess, "run", return_value=response):
            repository_settings.delete_github_api("endpoint")

    def test_direct_push_cli_option_is_forwarded(self):
        with (
            patch.object(repository_settings, "sync_repository") as sync,
            patch("builtins.print"),
        ):
            result = repository_settings.main(
                ["--allow-direct-push", "owner/repository"]
            )

        self.assertEqual(result, 0)
        sync.assert_called_once_with("owner/repository", allow_direct_push=True)

    def test_multiple_default_branch_rulesets_are_rejected(self):
        summaries = [
            {"id": 1, "target": "branch", "source_type": "Repository"},
            {"id": 2, "target": "branch", "source_type": "Repository"},
        ]
        with (
            patch.object(
                repository_settings,
                "read_github_api",
                side_effect=[summaries, ruleset(1, "one"), ruleset(2, "two")],
            ),
            self.assertRaisesRegex(RuntimeError, "multiple default-branch rulesets"),
        ):
            repository_settings.default_branch_ruleset("owner/repository")

    def test_repository_argument_is_required(self):
        with patch("sys.stderr", new_callable=io.StringIO):
            self.assertEqual(repository_settings.main([]), 2)


if __name__ == "__main__":
    unittest.main()
