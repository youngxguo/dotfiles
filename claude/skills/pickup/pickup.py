#!/usr/bin/env python3
"""Pick up an existing GitHub pull request in a Herdr worktree workspace."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "kickoff"))
try:
    import kickoff
except ImportError as exc:
    raise SystemExit(f"the kickoff skill must sit beside this one: {exc}")

herdr = kickoff.herdr
wait_for = kickoff.wait_for

PR_FIELDS = (
    "baseRefName,baseRefOid,headRefName,headRefOid,headRepository,isDraft,"
    "mergeStateStatus,number,reviewDecision,state,title,url"
)


@dataclass(frozen=True)
class Repository:
    host: str
    name_with_owner: str


@dataclass(frozen=True)
class Checkout:
    target: list[str]
    root: str
    worktrees: list[dict]
    remote: str


@dataclass(frozen=True)
class BranchSync:
    pr_ref: str
    upstream: str | None
    summary: str
    warning: str | None = None


def run(
    command: list[str], cwd: str | None = None, check: bool = True
) -> subprocess.CompletedProcess:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise SystemExit(detail or f"{' '.join(command)} exited {result.returncode}")
    return result


def pull_request(selector: str, cwd: str | None = None) -> dict:
    result = run(["gh", "pr", "view", selector, "--json", PR_FIELDS], cwd=cwd)
    try:
        pr = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"gh returned invalid pull request data: {exc}")
    if not isinstance(pr, dict) or not pr.get("url"):
        raise SystemExit("gh did not return a pull request")
    return pr


def repository_from_pr_url(url: str) -> Repository:
    parsed = urlsplit(url)
    pieces = [piece for piece in parsed.path.split("/") if piece]
    if not parsed.hostname or len(pieces) < 4 or pieces[2] != "pull":
        raise SystemExit(f"not a GitHub pull request URL: {url}")
    return Repository(parsed.hostname.lower(), f"{pieces[0]}/{pieces[1]}")


def repository_from_remote(url: str) -> Repository | None:
    url = url.strip()
    if not url:
        return None
    if "://" in url:
        parsed = urlsplit(url)
        host = parsed.hostname
        path = parsed.path
    else:
        match = re.match(r"^(?:[^@/]+@)?([^:/]+):(.+)$", url)
        if not match:
            return None
        host, path = match.groups()
    pieces = [piece for piece in path.removesuffix(".git").split("/") if piece]
    if not host or len(pieces) < 2:
        return None
    return Repository(host.lower(), "/".join(pieces[-2:]))


def remotes(root: str) -> list[tuple[str, Repository]]:
    names = run(["git", "remote"], cwd=root).stdout.splitlines()
    found = []
    for name in names:
        urls = run(
            ["git", "remote", "get-url", "--all", name], cwd=root, check=False
        ).stdout.splitlines()
        for url in urls:
            repository = repository_from_remote(url)
            if repository:
                found.append((name, repository))
    return found


def matching_remote(root: str, wanted: Repository) -> str | None:
    matches = [
        name
        for name, repository in remotes(root)
        if repository.name_with_owner.casefold() == wanted.name_with_owner.casefold()
    ]
    if not matches:
        return None
    return "origin" if "origin" in matches else matches[0]


def find_checkout(
    wanted: Repository, workspace: str | None = None, cwd: str | None = None
) -> Checkout:
    if workspace or cwd:
        target, root, worktrees = kickoff.main_checkout(None, workspace, cwd)
        remote = matching_remote(root, wanted)
        if not remote:
            raise SystemExit(
                f"{root} has no remote for {wanted.host}/{wanted.name_with_owner}"
            )
        return Checkout(target, root, worktrees, remote)

    workspaces = kickoff.workspaces()
    current_workspace = os.environ.get("HERDR_WORKSPACE_ID")
    roots: list[tuple[str, str | None]] = []
    seen = set()
    for workspace_info in sorted(
        workspaces,
        key=lambda item: item.get("workspace_id") != current_workspace,
    ):
        provenance = workspace_info.get("worktree") or {}
        root = provenance.get("repo_root")
        if root and root not in seen:
            roots.append((root, workspace_info.get("workspace_id")))
            seen.add(root)

    matches = []
    for root, workspace_id in roots:
        remote = matching_remote(root, wanted)
        if remote:
            matches.append((root, workspace_id, remote))
    if not matches:
        raise SystemExit(
            f"no open Herdr workspace has a remote for "
            f"{wanted.host}/{wanted.name_with_owner}; open its main checkout or pass --cwd"
        )
    if len(matches) > 1:
        paths = ", ".join(root for root, _, _ in matches)
        raise SystemExit(f"more than one checkout matches the PR ({paths}); pass --cwd")

    root, workspace_id, remote = matches[0]
    target, root, worktrees = kickoff.main_checkout(None, workspace_id, root)
    return Checkout(target, root, worktrees, remote)


def ref_exists(root: str, ref: str) -> bool:
    return (
        run(
            ["git", "show-ref", "--verify", "--quiet", ref], cwd=root, check=False
        ).returncode
        == 0
    )


def oid(root: str, ref: str) -> str:
    return run(["git", "rev-parse", ref], cwd=root).stdout.strip()


def is_ancestor(root: str, older: str, newer: str) -> bool:
    return (
        run(
            ["git", "merge-base", "--is-ancestor", older, newer],
            cwd=root,
            check=False,
        ).returncode
        == 0
    )


def fetch_pull_request(
    checkout: Checkout, repository: Repository, pr: dict, branch: str
) -> BranchSync:
    root = checkout.root
    number = int(pr["number"])
    base = pr["baseRefName"]
    head = pr["headRefName"]
    pr_ref = f"refs/remotes/{checkout.remote}/pull/{number}"
    base_ref = f"refs/remotes/{checkout.remote}/{base}"
    specs = [
        f"+refs/pull/{number}/head:{pr_ref}",
        f"+refs/heads/{base}:{base_ref}",
    ]

    head_repository = pr.get("headRepository") or {}
    same_repository = (
        head_repository.get("nameWithOwner", "").casefold()
        == repository.name_with_owner.casefold()
    )
    head_remote = checkout.remote if same_repository else None
    if not same_repository and head_repository.get("nameWithOwner"):
        head_remote = matching_remote(
            root,
            Repository(repository.host, head_repository["nameWithOwner"]),
        )

    upstream = None
    if same_repository:
        upstream = f"refs/remotes/{checkout.remote}/{head}"
        specs.append(f"+refs/heads/{head}:{upstream}")
    run(["git", "fetch", "--no-tags", checkout.remote, *specs], cwd=root)

    if head_remote and head_remote != checkout.remote:
        upstream = f"refs/remotes/{head_remote}/{head}"
        run(
            [
                "git",
                "fetch",
                "--no-tags",
                head_remote,
                f"+refs/heads/{head}:{upstream}",
            ],
            cwd=root,
        )

    known = kickoff.existing_worktree(checkout.worktrees, branch)
    return sync_local_branch(root, branch, pr_ref, upstream, known)


def sync_local_branch(
    root: str,
    branch: str,
    pr_ref: str,
    upstream: str | None,
    known_worktree: dict | None = None,
) -> BranchSync:
    local_ref = f"refs/heads/{branch}"
    if not ref_exists(root, local_ref):
        return BranchSync(pr_ref, upstream, f"will recreate {branch} at the PR head")

    local_oid = oid(root, local_ref)
    remote_oid = oid(root, pr_ref)
    if local_oid == remote_oid:
        return BranchSync(pr_ref, upstream, f"{branch} already matches the PR head")
    if is_ancestor(root, local_oid, remote_oid):
        if known_worktree:
            warning = (
                f"{branch} is behind the PR head, but it is checked out at "
                f"{known_worktree['path']}; pull it there before editing"
            )
            return BranchSync(pr_ref, upstream, "fetched the newer PR head", warning)
        run(["git", "branch", "--force", branch, pr_ref], cwd=root)
        return BranchSync(pr_ref, upstream, f"fast-forwarded {branch} to the PR head")
    if is_ancestor(root, remote_oid, local_oid):
        warning = (
            f"local {branch} is ahead of the PR head; "
            "its unpushed commits were preserved"
        )
        return BranchSync(pr_ref, upstream, "fetched the PR head", warning)

    warning = (
        f"local {branch} and the PR head have diverged; the local branch was preserved, "
        "so reconcile them before pushing"
    )
    return BranchSync(pr_ref, upstream, "fetched the PR head", warning)


def set_upstream(root: str, branch: str, upstream: str | None) -> None:
    if not upstream or not ref_exists(root, upstream):
        return
    run(
        ["git", "branch", "--set-upstream-to", upstream, branch],
        cwd=root,
        check=False,
    )


def make_brief(pr: dict, branch: str, sync: BranchSync, note: str) -> str:
    draft = "draft " if pr.get("isDraft") else ""
    lines = [
        f"Re-familiarize yourself with the existing {draft}pull request "
        f"#{pr['number']}: {pr['title']}",
        pr["url"],
        f"The existing branch {branch} is already checked out in this worktree.",
        "This first pass is orientation only. Do not modify files, implement fixes, "
        "commit, push, update the PR, or start long-running tests. Inspect the PR body "
        "and diff, recent commits, review comments (including inline comments), review "
        f"state, existing checks/CI, and the branch's relationship to {pr['baseRefName']}.",
    ]
    if sync.warning:
        lines.append(f"Important checkout state: {sync.warning}.")
    lines.extend(
        [
            "Then stop and send a concise re-centering report for the user: summarize "
            "the PR's goal, what is currently implemented, review and CI state, any "
            "unfinished work or risks, and the decisions or likely next steps to discuss.",
            "Wait for the user to choose the next step. Do not begin the work even when "
            "the next action seems obvious, and do not create a replacement branch or PR.",
        ]
    )
    if note.strip():
        lines.extend(
            [
                "",
                "Use this additional direction to focus your orientation; it does not "
                f"authorize implementation yet: {note.strip()}",
            ]
        )
    return "\n".join(lines)


def read_agent_report(target: str, lines: int = 160) -> str:
    result = run(
        [
            "herdr",
            "agent",
            "read",
            target,
            "--source",
            "recent-unwrapped",
            "--lines",
            str(lines),
        ]
    )
    return result.stdout.strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "pr", help="pull request URL (or another selector accepted by gh)"
    )
    parser.add_argument("brief", nargs="*", help="additional direction for the agent")
    parser.add_argument("--brief-file", help="read additional direction from a file")
    parser.add_argument("--workspace", help="source workspace id")
    parser.add_argument("--cwd", help="path to the repository's main checkout")
    parser.add_argument(
        "--branch", help="local branch name (default: the PR head branch)"
    )
    parser.add_argument(
        "--name", help="agent name (default: the branch's final component)"
    )
    parser.add_argument("--kind", default="claude", help="agent kind (default: claude)")
    parser.add_argument(
        "--no-agent", action="store_true", help="open the worktree workspace only"
    )
    parser.add_argument("--to", help="pin the claude account rebump picks")
    parser.add_argument("--focus", action="store_true", help="focus the workspace")
    parser.add_argument(
        "--trust-repository",
        action="store_true",
        help="trust a repo herdr has not been pointed at before",
    )
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="return before the agent finishes its reorientation",
    )
    parser.add_argument(
        "--allow-closed", action="store_true", help="allow a closed or merged PR"
    )
    parser.add_argument("--dry-run", action="store_true")

    argv, extra = kickoff.split_agent_args(
        list(sys.argv[1:]) if argv is None else list(argv)
    )
    args = parser.parse_args(argv)
    if os.environ.get("HERDR_ENV") != "1":
        raise SystemExit("pickup must run inside a Herdr-managed pane")

    note = (
        Path(args.brief_file).read_text() if args.brief_file else " ".join(args.brief)
    )
    pr = pull_request(args.pr, args.cwd)
    repository = repository_from_pr_url(pr["url"])
    if pr.get("state") != "OPEN" and not args.allow_closed:
        raise SystemExit(
            f"PR #{pr['number']} is {str(pr.get('state')).lower()}; "
            "pass --allow-closed to open it anyway"
        )
    checkout = find_checkout(repository, args.workspace, args.cwd)
    branch = args.branch or pr["headRefName"]
    if (
        run(["git", "check-ref-format", "--branch", branch], check=False).returncode
        != 0
    ):
        raise SystemExit(f"invalid local branch name: {branch}")

    slug = kickoff.slugify(branch.rsplit("/", 1)[-1]) or f"pr-{pr['number']}"
    print(
        f"{repository.name_with_owner} PR #{pr['number']}: {pr['title']}\n"
        f"  {branch} ({' '.join(checkout.target)})"
    )
    if args.dry_run:
        print(
            f"  would fetch the PR, open its worktree, and start {args.kind} "
            f"as {args.name or slug}"
        )
        return 0

    sync = fetch_pull_request(checkout, repository, pr, branch)
    print(f"  {sync.summary}")
    if sync.warning:
        print(f"  warning: {sync.warning}")

    flags = [
        *checkout.target,
        "--branch",
        branch,
        "--focus" if args.focus else "--no-focus",
        *(["--trust-repository"] if args.trust_repository else []),
    ]
    known = kickoff.existing_worktree(checkout.worktrees, branch)
    if known:
        print(f"  worktree exists at {known['path']}; opening it")
        opened = herdr("worktree", "open", *flags)["result"]
    else:
        opened = herdr("worktree", "create", *flags, "--base", sync.pr_ref)["result"]

    workspace_id = opened["workspace"]["workspace_id"]
    pane_id = opened["root_pane"]["pane_id"]
    path = opened["worktree"]["path"]
    print(f"  workspace {workspace_id} pane {pane_id} at {path}")
    set_upstream(checkout.root, branch, sync.upstream)

    occupant = kickoff.pane_agent(pane_id)
    if occupant:
        raise SystemExit(
            f"{occupant} is already running in {pane_id}; prompt it directly"
        )
    if not wait_for(lambda: kickoff.shell_ready(pane_id), 20):
        raise SystemExit(
            f"the shell in {pane_id} never reached a prompt; "
            f"{workspace_id} is open at {path}"
        )

    if args.no_agent:
        print(f"\n{branch}  {workspace_id}  {pane_id}  {path}")
        return 0

    name = args.name or kickoff.agent_name(slug)
    if args.kind == "claude":
        kickoff.launch_claude(pane_id, args.to, extra, print)
        if not wait_for(lambda: kickoff.pane_agent(pane_id) == "claude", 60):
            raise SystemExit(
                f"herdr never detected claude in {pane_id}; "
                f"{workspace_id} is open at {path}"
            )
    else:
        herdr(
            "agent",
            "start",
            name,
            "--kind",
            args.kind,
            "--pane",
            pane_id,
            *(["--", *extra] if extra else []),
            check=False,
            timeout=120,
        )

    status = kickoff.rebump.settle_agent(pane_id, print)
    herdr("agent", "rename", pane_id, name, check=False)
    print(f"  agent {name} is {status}")
    brief = make_brief(pr, branch, sync, note)
    if status == "blocked":
        print("  agent is waiting on a dialog; pickup brief not sent")
    else:
        herdr(
            "agent",
            "prompt",
            pane_id,
            brief,
            *([] if args.no_wait else ["--wait", "--timeout", "600000"]),
            check=False,
            timeout=660,
        )
        print("  pickup orientation brief sent")

    print(f"\n{name}  {branch}  {workspace_id}  {path}")
    if args.no_wait or status == "blocked":
        print(
            f"check on it: herdr agent get {name} | "
            f"herdr agent read {name} --source recent-unwrapped --lines 160"
        )
    else:
        report = read_agent_report(pane_id)
        print(f"\n--- reorientation report from {name} ---")
        print(report or "The agent settled without a readable report.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
