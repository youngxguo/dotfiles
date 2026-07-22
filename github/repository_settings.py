#!/usr/bin/env python3

import json
import subprocess
import sys
from typing import cast


# GitHub does not read repository settings from a tracked file, so apply this
# version-controlled policy through the authenticated GitHub CLI.
REPOSITORY_SETTINGS: dict[str, object] = {
    "allow_squash_merge": True,
    "allow_merge_commit": False,
    "allow_rebase_merge": False,
    "squash_merge_commit_title": "PR_TITLE",
    "squash_merge_commit_message": "PR_BODY",
}

# GitHub requires each status check to be named explicitly in a ruleset.
REQUIRED_STATUS_CHECKS = {
    "youngxguo/dotfiles": ("validate",),
    "youngxguo/yxgui": (
        "Quality Checks",
        "Vercel",
        "Vercel Preview Comments",
    ),
}

RULESET_NAME = "default branch"
BRANCH_RULES: list[dict[str, object]] = [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {
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
    },
]


def ruleset_for(repository: str) -> dict[str, object]:
    required_checks = REQUIRED_STATUS_CHECKS.get(repository)
    if required_checks is None:
        raise RuntimeError(
            f"add {repository}'s checks to REQUIRED_STATUS_CHECKS before syncing"
        )

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
            *BRANCH_RULES,
            {
                "type": "required_status_checks",
                "parameters": {
                    "do_not_enforce_on_create": False,
                    "required_status_checks": [
                        {"context": check} for check in required_checks
                    ],
                    "strict_required_status_checks_policy": True,
                },
            },
        ],
    }


def read_github_api(endpoint: str) -> object:
    result = subprocess.run(
        ["gh", "api", endpoint],
        check=True,
        capture_output=True,
        text=True,
    )
    return cast(object, json.loads(result.stdout))


def write_github_api(method: str, endpoint: str, payload: dict[str, object]) -> None:
    _ = subprocess.run(
        ["gh", "api", "--method", method, endpoint, "--input", "-", "--silent"],
        check=True,
        input=json.dumps(payload),
        text=True,
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


def default_branch_ruleset_id(repository: str) -> int | None:
    response = read_github_api(f"repos/{repository}/rulesets")
    if not isinstance(response, list):
        raise RuntimeError("GitHub returned an invalid ruleset list")

    matching_rulesets: list[tuple[int, str]] = []
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
                (ruleset_id, name if isinstance(name, str) else "")
            )

    managed_rulesets = [
        ruleset_id for ruleset_id, name in matching_rulesets if name == RULESET_NAME
    ]
    if len(managed_rulesets) == 1:
        return managed_rulesets[0]
    if len(matching_rulesets) == 1:
        return matching_rulesets[0][0]
    if matching_rulesets:
        raise RuntimeError(
            f"{repository} has multiple default-branch rulesets; refusing to choose one"
        )
    return None


def sync_repository(repository: str) -> None:
    ruleset = ruleset_for(repository)
    write_github_api("PATCH", f"repos/{repository}", REPOSITORY_SETTINGS)

    ruleset_id = default_branch_ruleset_id(repository)
    if ruleset_id is None:
        write_github_api("POST", f"repos/{repository}/rulesets", ruleset)
    else:
        write_github_api("PUT", f"repos/{repository}/rulesets/{ruleset_id}", ruleset)

    print(f"{repository}: repository settings and ruleset synced")


def main(repositories: list[str]) -> int:
    if not repositories:
        print(f"usage: {sys.argv[0]} OWNER/REPOSITORY...", file=sys.stderr)
        return 2

    for repository in repositories:
        sync_repository(repository)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
