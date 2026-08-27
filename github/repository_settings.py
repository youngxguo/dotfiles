#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
from typing import cast
from urllib.parse import quote

# GitHub does not read repository settings from a tracked file, so apply this
# version-controlled policy through the authenticated GitHub CLI.
REPOSITORY_SETTINGS: dict[str, object] = {
    "allow_squash_merge": True,
    "allow_merge_commit": False,
    "allow_rebase_merge": False,
    "delete_branch_on_merge": True,
    "squash_merge_commit_title": "PR_TITLE",
    "squash_merge_commit_message": "PR_BODY",
}

RULESET_NAME = "default branch"
# Required checks remain repository-specific, but they never require a branch
# to be updated with the latest default branch before merging.
MANAGED_RULE_TYPES = {
    "deletion",
    "non_fast_forward",
    "pull_request",
    "required_status_checks",
}
BRANCH_RULES: list[dict[str, object]] = [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
]
PULL_REQUEST_RULE: dict[str, object] = {
    "type": "pull_request",
    "parameters": {
        "allowed_merge_methods": ["squash"],
        "dismiss_stale_reviews_on_push": False,
        "require_code_owner_review": False,
        "require_last_push_approval": False,
        "required_approving_review_count": 0,
        "required_review_thread_resolution": False,
        "required_reviewers": [],
    },
}


def branch_rules_for(allow_direct_push: bool) -> list[dict[str, object]]:
    if allow_direct_push:
        return [*BRANCH_RULES]
    return [*BRANCH_RULES, PULL_REQUEST_RULE]


def ruleset_for(
    existing_ruleset: dict[str, object] | None,
    *,
    allow_direct_push: bool = False,
) -> dict[str, object]:
    # Preserve repository-specific rules this shared policy does not manage.
    preserved_rules: list[dict[str, object]] = []
    if existing_ruleset is not None:
        existing_rules = existing_ruleset.get("rules")
        if not isinstance(existing_rules, list):
            raise RuntimeError("GitHub returned an invalid ruleset rule list")
        for item in cast(list[object], existing_rules):
            rule = object_mapping(item, "ruleset rule")
            if rule.get("type") == "required_status_checks":
                parameters = object_mapping(
                    rule.get("parameters"), "required status checks parameters"
                )
                preserved_rules.append(
                    {
                        **rule,
                        "parameters": {
                            **parameters,
                            "strict_required_status_checks_policy": False,
                        },
                    }
                )
            elif rule.get("type") not in MANAGED_RULE_TYPES:
                preserved_rules.append(rule)

    return {
        "name": RULESET_NAME,
        "target": "branch",
        "enforcement": "active",
        "bypass_actors": [],
        "conditions": {
            "ref_name": {
                "include": ["~DEFAULT_BRANCH"],
                "exclude": [],
            }
        },
        "rules": [
            *branch_rules_for(allow_direct_push),
            *preserved_rules,
        ],
    }


def read_github_api(endpoint: str) -> object:
    result = subprocess.run(
        ["gh", "api", endpoint],
        check=True,
        capture_output=True,
        text=True,
    )
    try:
        return cast(object, json.loads(result.stdout))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"GitHub returned invalid JSON for {endpoint}") from exc


def write_github_api(method: str, endpoint: str, payload: dict[str, object]) -> None:
    _ = subprocess.run(
        ["gh", "api", "--method", method, endpoint, "--input", "-", "--silent"],
        check=True,
        input=json.dumps(payload),
        text=True,
    )


def delete_github_api(endpoint: str) -> None:
    result = subprocess.run(
        ["gh", "api", "--method", "DELETE", endpoint, "--silent"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0 or "(HTTP 404)" in result.stderr:
        return
    raise subprocess.CalledProcessError(
        result.returncode,
        result.args,
        output=result.stdout,
        stderr=result.stderr,
    )


def object_mapping(value: object, description: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise RuntimeError(f"GitHub returned an invalid {description}")
    return cast(dict[str, object], value)


def targets_default_branch(ruleset: dict[str, object]) -> bool:
    conditions = object_mapping(ruleset.get("conditions"), "ruleset conditions")
    ref_name = object_mapping(conditions.get("ref_name"), "ruleset ref condition")
    included_refs = ref_name.get("include")
    return isinstance(included_refs, list) and "~DEFAULT_BRANCH" in included_refs


def remove_legacy_pull_request_rule(repository: str) -> None:
    details = object_mapping(read_github_api(f"repos/{repository}"), "repository")
    default_branch = details.get("default_branch")
    if not isinstance(default_branch, str):
        raise RuntimeError("GitHub returned an invalid default branch")
    branch = quote(default_branch, safe="")
    delete_github_api(
        f"repos/{repository}/branches/{branch}/protection/required_pull_request_reviews"
    )


def default_branch_ruleset(
    repository: str,
) -> tuple[int, dict[str, object]] | None:
    response = read_github_api(f"repos/{repository}/rulesets")
    if not isinstance(response, list):
        raise RuntimeError("GitHub returned an invalid ruleset list")

    matching_rulesets: list[tuple[int, str, dict[str, object]]] = []
    for item in cast(list[object], response):
        summary = object_mapping(item, "ruleset summary")
        ruleset_id = summary.get("id")
        if (
            summary.get("target") != "branch"
            or summary.get("source_type") != "Repository"
            or not isinstance(ruleset_id, int)
        ):
            continue

        ruleset = object_mapping(
            read_github_api(f"repos/{repository}/rulesets/{ruleset_id}"),
            "ruleset",
        )
        if targets_default_branch(ruleset):
            name = ruleset.get("name")
            matching_rulesets.append(
                (ruleset_id, name if isinstance(name, str) else "", ruleset)
            )

    managed_rulesets = [
        ruleset for ruleset in matching_rulesets if ruleset[1] == RULESET_NAME
    ]
    if len(managed_rulesets) == 1:
        ruleset_id, _, ruleset = managed_rulesets[0]
        return ruleset_id, ruleset
    if len(matching_rulesets) == 1:
        ruleset_id, _, ruleset = matching_rulesets[0]
        return ruleset_id, ruleset
    if matching_rulesets:
        raise RuntimeError(
            f"{repository} has multiple default-branch rulesets; refusing to choose one"
        )
    return None


def sync_repository(repository: str, *, allow_direct_push: bool = False) -> None:
    write_github_api("PATCH", f"repos/{repository}", REPOSITORY_SETTINGS)

    existing_ruleset = default_branch_ruleset(repository)
    if existing_ruleset is None:
        write_github_api(
            "POST",
            f"repos/{repository}/rulesets",
            ruleset_for(None, allow_direct_push=allow_direct_push),
        )
    else:
        ruleset_id, ruleset = existing_ruleset
        write_github_api(
            "PUT",
            f"repos/{repository}/rulesets/{ruleset_id}",
            ruleset_for(ruleset, allow_direct_push=allow_direct_push),
        )

    # Rulesets are the source of truth. Remove any legacy branch-protection PR
    # requirement after the replacement rule is active so direct mode works.
    remove_legacy_pull_request_rule(repository)

    print(f"{repository}: repository settings and ruleset synced")


def parse_args(arguments: list[str]) -> tuple[list[str], bool]:
    parser = argparse.ArgumentParser(
        description="Apply repository settings and default-branch rules."
    )
    _ = parser.add_argument(
        "--allow-direct-push",
        action="store_true",
        help="Allow direct pushes by omitting the pull-request rule.",
    )
    _ = parser.add_argument("repositories", metavar="OWNER/REPOSITORY", nargs="*")
    parsed = parser.parse_args(arguments)
    return cast(list[str], parsed.repositories), cast(bool, parsed.allow_direct_push)


def main(arguments: list[str]) -> int:
    repositories, allow_direct_push = parse_args(arguments)
    if not repositories:
        print(
            f"usage: {sys.argv[0]} [--allow-direct-push] OWNER/REPOSITORY...",
            file=sys.stderr,
        )
        return 2

    for repository in repositories:
        sync_repository(repository, allow_direct_push=allow_direct_push)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
