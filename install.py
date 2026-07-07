#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent
HOME = Path.home()
LINUX_APT_UPDATED = False
VERIFY_MODE = False
BTOP_VERSION = "v1.4.7"
BTOP_LINUX_RELEASES = {
    "aarch64": (
        "btop-aarch64-unknown-linux-musl.tar.gz",
        "6270de0ef4c84cf0eea61cb148b3ad9ae91a11e9c3309867ffc6b3751024c252",
    ),
    "arm64": (
        "btop-aarch64-unknown-linux-musl.tar.gz",
        "6270de0ef4c84cf0eea61cb148b3ad9ae91a11e9c3309867ffc6b3751024c252",
    ),
    "x86_64": (
        "btop-x86_64-unknown-linux-musl.tar.gz",
        "5099054dd6a101bd12eb6ff3702a9a6a3f57aaa27923a0da478ae5b517faf335",
    ),
}

LINUX_PACKAGE_OVERRIDES = {
    "fd": {
        "apt": "fd-find",
        "dnf": "fd-find",
        "pacman": "fd",
        "zypper": "fd",
    }
}

PACKAGE_BINARIES = {
    "neovim": ("nvim",),
    "ripgrep": ("rg",),
    "fd": ("fd", "fdfind"),
    "prettier": ("prettier",),
    "tree-sitter-cli": ("tree-sitter",),
    "typescript-language-server": ("typescript-language-server",),
    "basedpyright": ("basedpyright-langserver",),
    "gh": ("gh",),
    "chafa": ("chafa",),
    "viu": ("viu",),
    "mercurial": ("hg",),
    "zsh": ("zsh",),
    "tmux": ("tmux",),
    "direnv": ("direnv",),
    "fzf": ("fzf",),
    "fd": ("fd",),
    "starship": ("starship",),
    "btop": ("btop",),
}


def run(cmd, env=None):
    print(f"+ {' '.join(cmd)}")
    subprocess.run(cmd, check=True, env=env)


def command_exists(cmd):
    return shutil.which(cmd) is not None


def linux_package_manager():
    if not sys.platform.startswith("linux"):
        return None
    for manager, binary in (
        ("apt", "apt-get"),
        ("dnf", "dnf"),
        ("pacman", "pacman"),
        ("zypper", "zypper"),
    ):
        if command_exists(binary):
            return manager
    return None


def with_privilege(cmd):
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        return cmd
    if command_exists("sudo"):
        return ["sudo", *cmd]
    return None


def linux_package_name(pkg, manager):
    return LINUX_PACKAGE_OVERRIDES.get(pkg, {}).get(manager, pkg)


def pkg_installed(pkg):
    binaries = PACKAGE_BINARIES.get(pkg, (pkg,))
    return any(command_exists(binary) for binary in binaries)


def ensure_fd_compat_shim():
    if command_exists("fd"):
        return
    fdfind = shutil.which("fdfind")
    if not fdfind:
        return

    local_bin = HOME / ".local/bin"
    local_bin.mkdir(parents=True, exist_ok=True)
    shim = local_bin / "fd"

    if shim.exists():
        return

    shim.write_text(f"#!/usr/bin/env sh\nexec {shlex.quote(fdfind)} \"$@\"\n", encoding="utf-8")
    shim.chmod(0o755)
    print(f"created fd compatibility shim at {shim} (ensure {local_bin} is in PATH)")


def linux_install(pkg):
    global LINUX_APT_UPDATED

    manager = linux_package_manager()
    if not manager:
        print(f"skipping {pkg}: no supported linux package manager found (apt/dnf/pacman/zypper)")
        return False

    if pkg_installed(pkg):
        print(f"{pkg} already installed")
        if pkg == "fd":
            ensure_fd_compat_shim()
        return True

    target_pkg = linux_package_name(pkg, manager)

    if manager == "apt":
        if not LINUX_APT_UPDATED:
            update_cmd = with_privilege(["apt-get", "update"])
            if not update_cmd:
                print("skipping apt install: sudo is required (or run as root)")
                return False
            run(update_cmd)
            LINUX_APT_UPDATED = True
        install_cmd = with_privilege(["apt-get", "install", "-y", target_pkg])
    elif manager == "dnf":
        install_cmd = with_privilege(["dnf", "install", "-y", target_pkg])
    elif manager == "pacman":
        install_cmd = with_privilege(["pacman", "-S", "--noconfirm", target_pkg])
    else:
        install_cmd = with_privilege(["zypper", "--non-interactive", "install", target_pkg])

    if not install_cmd:
        print(f"skipping {pkg}: sudo is required (or run as root)")
        return False

    run(install_cmd)

    if pkg == "fd":
        ensure_fd_compat_shim()

    return pkg_installed(pkg)


def brew_prefix():
    if not command_exists("brew"):
        return None
    return subprocess.check_output(["brew", "--prefix"], text=True).strip()


def install_package(pkg):
    if VERIFY_MODE:
        print(f"verify mode: skipping package install for {pkg}")
        return False
    if not command_exists("brew"):
        if sys.platform.startswith("linux"):
            return linux_install(pkg)
        print(f"skipping {pkg}: homebrew is not available")
        return False
    result = subprocess.run(["brew", "list", pkg], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if result.returncode == 0:
        print(f"{pkg} already installed")
        return True
    else:
        run(["brew", "install", pkg])
        return True


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_tar_safely(tar, destination):
    destination = Path(destination).resolve()
    for member in tar.getmembers():
        target = (destination / member.name).resolve()
        if target != destination and destination not in target.parents:
            raise RuntimeError(f"refusing to extract unsafe tar member: {member.name}")
    tar.extractall(destination)


def install_btop_linux_release():
    machine = platform.machine().lower()
    asset = BTOP_LINUX_RELEASES.get(machine)
    if not asset:
        print(f"skipping btop: unsupported linux architecture {machine}")
        return False

    filename, expected_sha256 = asset
    url = f"https://github.com/aristocratos/btop/releases/download/{BTOP_VERSION}/{filename}"
    print(f"installing btop {BTOP_VERSION} from upstream release")

    with tempfile.TemporaryDirectory(prefix="btop-install-") as tmpdir:
        tmpdir_path = Path(tmpdir)
        archive = tmpdir_path / filename
        run(["curl", "-fsSL", "-o", str(archive), url])

        actual_sha256 = sha256_file(archive)
        if actual_sha256 != expected_sha256:
            raise RuntimeError(
                f"checksum mismatch for {filename}: expected {expected_sha256}, got {actual_sha256}"
            )

        with tarfile.open(archive, "r:gz") as tar:
            extract_tar_safely(tar, tmpdir_path)

        source = tmpdir_path / "btop"
        local_bin = HOME / ".local/bin"
        local_share = HOME / ".local/share/btop"
        local_bin.mkdir(parents=True, exist_ok=True)
        local_share.mkdir(parents=True, exist_ok=True)

        shutil.copy2(source / "bin/btop", local_bin / "btop")
        (local_bin / "btop").chmod(0o755)
        shutil.copy2(source / "README.md", local_share / "README.md")
        shutil.copytree(source / "themes", local_share / "themes", dirs_exist_ok=True)

    return pkg_installed("btop")


def install_btop():
    print("installing btop")
    if VERIFY_MODE:
        print("verify mode: skipping btop package/bootstrap")
    elif pkg_installed("btop"):
        print("btop already installed")
    elif command_exists("brew"):
        install_package("btop")
    elif sys.platform.startswith("linux"):
        install_btop_linux_release()
    else:
        print("skipping btop: no supported installer available")

    print("applying btop config")
    apply_links(links_for("btop"))


def install_homebrew_only_package(pkg):
    if pkg_installed(pkg):
        print(f"{pkg} already installed")
        return True
    if VERIFY_MODE:
        print(f"verify mode: skipping optional homebrew package install for {pkg}")
        return False
    if not command_exists("brew"):
        print(f"skipping optional {pkg}: homebrew is not available")
        return False
    return install_package(pkg)


def install_npm_global(package, binaries):
    if any(command_exists(binary) for binary in binaries):
        print(f"{package} already installed")
        return True
    if VERIFY_MODE:
        print(f"verify mode: skipping npm global install for {package}")
        return False
    if not command_exists("npm"):
        if command_exists("brew"):
            install_package("node")
    if not command_exists("npm"):
        print(f"skipping {package}: npm is not available")
        return False
    run(["npm", "install", "-g", package])
    return any(command_exists(binary) for binary in binaries)


def clone_if_missing(repo_url, target_dir):
    target = Path(target_dir).expanduser()
    if VERIFY_MODE:
        print(f"verify mode: skipping clone for {repo_url} -> {target}")
        return
    git_dir = target / ".git"
    if git_dir.is_dir():
        print(f"repo already present at {target}")
        return
    if target.exists():
        print(f"cannot clone {repo_url} because {target} already exists and is not a git repo")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "clone", repo_url, str(target)])


def link_file(source_path, target_path):
    source = Path(source_path).resolve()
    target = Path(target_path).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)

    if target.is_symlink():
        if target.resolve() == source:
            print(f"link already configured: {target}")
            return
        target.unlink()
    elif target.exists():
        backup = target.with_name(f"{target.name}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}")
        target.rename(backup)
        print(f"backed up existing file to {backup}")

    target.symlink_to(source)


def managed_links():
    """Single source of truth for every symlink this repo manages.

    Returns a list of (category, source, target) tuples. Both the setup flow
    (via ``links_for``/``apply_links``) and ``cleanup_links`` iterate over this,
    so the two can never drift. Dynamic categories (ghostty assets, tmux
    scripts) are enumerated from whatever currently exists in the repo; targets
    read the module-global ``HOME`` at call time so verify mode works.
    """
    links = [
        ("zsh", REPO_ROOT / "zsh/.zshrc", HOME / ".zshrc"),
        ("zsh", REPO_ROOT / "starship/starship.toml", HOME / ".config/starship.toml"),
        ("ghostty", REPO_ROOT / "ghostty/config", HOME / ".config/ghostty/config"),
    ]

    shader_dir = REPO_ROOT / "ghostty/shaders"
    if shader_dir.is_dir():
        for shader_file in sorted(shader_dir.glob("*.glsl")):
            links.append(("ghostty", shader_file, HOME / ".config/ghostty/shaders" / shader_file.name))
    theme_dir = REPO_ROOT / "ghostty/themes"
    if theme_dir.is_dir():
        for theme_file in sorted(theme_dir.iterdir()):
            if theme_file.is_file():
                links.append(("ghostty", theme_file, HOME / ".config/ghostty/themes" / theme_file.name))

    links.append(("tmux", REPO_ROOT / "tmux/.tmux.conf", HOME / ".tmux.conf"))
    for script in sorted((REPO_ROOT / "tmux").glob(".tmux-*.sh")):
        links.append(("tmux", script, HOME / script.name))

    links.append(("btop", REPO_ROOT / "btop/.config/btop/btop.conf", HOME / ".config/btop/btop.conf"))

    if sys.platform == "darwin":
        vscode_user_dir = HOME / "Library/Application Support/Code/User"
    else:
        vscode_user_dir = HOME / ".config/Code/User"
    links.append(("vscode", REPO_ROOT / "vscode/settings.json", vscode_user_dir / "settings.json"))
    links.append(("vscode", REPO_ROOT / "vscode/keybindings.json", vscode_user_dir / "keybindings.json"))

    links.append(("claude", REPO_ROOT / "claude/CLAUDE.md", HOME / ".claude/CLAUDE.md"))
    links.append(
        ("claude", REPO_ROOT / "claude/statusline-command.sh", HOME / ".claude/statusline-command.sh")
    )
    for script in sorted((REPO_ROOT / "claude/hooks").glob("*.sh")):
        links.append(("claude", script, HOME / ".claude/hooks" / script.name))
    links.append(("codex", REPO_ROOT / "codex/AGENTS.md", HOME / ".codex/AGENTS.md"))
    links.append(("neovim", REPO_ROOT / "neovim/.config/nvim", HOME / ".config/nvim"))

    return links


def links_for(category):
    return [(source, target) for cat, source, target in managed_links() if cat == category]


def apply_links(links):
    """Symlink each (source, target) whose source exists; return count applied."""
    applied = 0
    for source, target in links:
        if not Path(source).exists():
            continue
        link_file(source, target)
        applied += 1
    return applied


def install_homebrew():
    print("installing homebrew")
    if VERIFY_MODE:
        print("verify mode: skipping homebrew bootstrap")
        return False
    if command_exists("brew"):
        print("homebrew already installed")
        return True
    if sys.platform.startswith("linux") and os.environ.get("INSTALL_HOMEBREW", "0") != "1":
        print("skipping homebrew bootstrap on linux (set INSTALL_HOMEBREW=1 to force install)")
        return False
    env = os.environ.copy()
    env["NONINTERACTIVE"] = "1"
    try:
        run(
            [
                "/bin/bash",
                "-c",
                "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh | /bin/bash",
            ],
            env=env,
        )
    except subprocess.CalledProcessError:
        print("warning: unable to install homebrew; continuing without brew-managed packages")
        return False
    return command_exists("brew")


def install_zsh_stack():
    print("installing zsh")
    if VERIFY_MODE:
        print("verify mode: skipping zsh package/plugin bootstrap")
    else:
        install_package("zsh")
        if not command_exists("zsh"):
            print("skipping zsh setup: zsh is not installed")
            return

        print("installing oh my zsh")
        oh_my_zsh_dir = HOME / ".oh-my-zsh"
        if oh_my_zsh_dir.is_dir():
            print("oh my zsh already installed")
        else:
            env = os.environ.copy()
            env["RUNZSH"] = "no"
            env["CHSH"] = "no"
            env["KEEP_ZSHRC"] = "yes"
            run(
                [
                    "sh",
                    "-c",
                    "curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh",
                ],
                env=env,
            )

        print("installing zsh plugins")
        install_package("direnv")
        install_package("starship")
        install_package("fd")
        zsh_custom = os.environ.get("ZSH_CUSTOM", str(HOME / ".oh-my-zsh/custom"))
        clone_if_missing(
            "https://github.com/zsh-users/zsh-autosuggestions",
            Path(zsh_custom) / "plugins/zsh-autosuggestions",
        )
        clone_if_missing(
            "https://github.com/zsh-users/zsh-syntax-highlighting",
            Path(zsh_custom) / "plugins/zsh-syntax-highlighting",
        )

        if install_package("fzf"):
            prefix = brew_prefix()
            if prefix:
                fzf_install = Path(prefix) / "opt/fzf/install"
                if fzf_install.exists():
                    run([str(fzf_install), "--all", "--no-update-rc"])
                else:
                    print(f"skipping fzf installer (not found at {fzf_install})")

    print("applying zsh config")
    apply_links(links_for("zsh"))

    if VERIFY_MODE:
        print("verify mode: skipping chsh")
        return

    zsh_path = shutil.which("zsh")
    target_shell = Path(zsh_path) if zsh_path else None
    current_shell = os.environ.get("SHELL", "")
    if target_shell and target_shell.exists() and current_shell != str(target_shell):
        if os.environ.get("APPLY_LOGIN_SHELL", "0") == "1":
            run(["chsh", "-s", str(target_shell)])
        else:
            print(f"skipping chsh (set APPLY_LOGIN_SHELL=1 to apply {target_shell})")


def install_ghostty():
    print("applying ghostty config")
    apply_links(links_for("ghostty"))


def install_tmux():
    print("installing tmux")
    install_package("tmux")
    print("applying tmux config")
    apply_links(links_for("tmux"))


def install_vscode():
    print("copying vscode configs")
    apply_links(links_for("vscode"))


def ensure_codex_hooks():
    """Merge the repo's agent-state hooks into ``~/.codex/hooks.json``."""
    fragment_path = REPO_ROOT / "codex/ai-state-hooks.json"
    if not fragment_path.exists():
        print("skipping codex ai-state hooks: no codex/ai-state-hooks.json present")
        return
    wanted = json.loads(fragment_path.read_text(encoding="utf-8")).get("hooks", {})
    if not wanted:
        return

    target = HOME / ".codex/hooks.json"
    if target.exists():
        try:
            settings = json.loads(target.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"skipping codex ai-state hooks: {target} is not valid JSON")
            return
        if not isinstance(settings, dict):
            print(f"skipping codex ai-state hooks: {target} is not a JSON object")
            return
    else:
        settings = {}

    hooks = settings.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        print(f"skipping codex ai-state hooks: {target} hooks is not a JSON object")
        return

    changed = False
    for event, groups in wanted.items():
        existing = hooks.get(event)
        if existing is None:
            existing = hooks[event] = []
        elif not isinstance(existing, list):
            print(f"skipping codex hook event {event}: existing value is not a list")
            continue
        present = {
            hook.get("command")
            for group in existing if isinstance(group, dict)
            for hook in group.get("hooks", []) if isinstance(hook, dict)
        }
        for group in groups:
            commands = {h.get("command") for h in group.get("hooks", []) if isinstance(h, dict)}
            if commands & present:
                continue
            existing.append(group)
            present |= commands
            changed = True

    if not changed:
        print("codex ai-state hooks already present")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    print(f"merged codex ai-state hooks into {target}")


# settings.json keys the repo template owns outright. Hooks are owned
# per-event instead (see merge_claude_settings), and everything else in the
# live file — model, enabledPlugins, env, and machine-local hooks — is
# preserved as-is, so the template stays small enough to generalize to any
# machine.
CLAUDE_SETTINGS_KEYS = ("permissions", "statusLine")


def merge_claude_settings():
    """Merge the repo-owned parts of claude/settings.json into ``~/.claude/settings.json``.

    The live file cannot be a symlink into the repo: Claude Code rewrites
    settings.json in place at runtime (model changes, enabledPlugins, ...),
    which replaces a symlink with a plain file and orphans the repo copy — that
    is exactly how the old symlink scheme drifted. Instead the template owns
    ``CLAUDE_SETTINGS_KEYS`` plus each hook event it declares; hook events it
    doesn't declare and every other live key pass through untouched.
    """
    source = REPO_ROOT / "claude/settings.json"
    target = HOME / ".claude/settings.json"
    if not source.is_file():
        print("skipping claude settings: no claude/settings.json present")
        return
    template = json.loads(source.read_text(encoding="utf-8"))

    if target.is_symlink():
        # Left over from the old symlink scheme; writing through it would
        # clobber the repo template.
        target.unlink()
    settings = {}
    if target.is_file():
        try:
            settings = json.loads(target.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            print(f"skipping claude settings: {target} is not valid JSON")
            return
        if not isinstance(settings, dict):
            print(f"skipping claude settings: {target} is not a JSON object")
            return

    for key in CLAUDE_SETTINGS_KEYS:
        if key in template:
            settings[key] = template[key]

    hooks = settings.setdefault("hooks", {})
    if isinstance(hooks, dict):
        for event, groups in template.get("hooks", {}).items():
            hooks[event] = groups
    else:
        print(f"skipping claude hooks merge: {target} hooks is not a JSON object")

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
    print(f"merged claude settings into {target}")


def install_claude():
    links = links_for("claude")
    if any(Path(source).exists() for source, _ in links):
        print("applying claude config")
        apply_links(links)
    else:
        print("skipping claude config: no claude/ files present")
    merge_claude_settings()


def ensure_codex_local_config():
    """Keep Codex config local while preserving old repo-symlink installs."""
    target = HOME / ".codex/config.toml"
    template = REPO_ROOT / "codex/config.example.toml"

    if target.is_symlink():
        source = target.resolve()
        if source.exists() and source.is_relative_to(REPO_ROOT):
            target.unlink()
            shutil.copy2(source, target)
            print(f"detached codex config into local file: {target}")
            return

    if target.exists():
        print(f"leaving existing codex config unmanaged: {target}")
        return

    if not template.exists():
        print("skipping codex config: no local config or codex/config.example.toml present")
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(template, target)
    print(f"created local codex config from {template}: {target}")


def install_codex():
    agents_links = [(s, d) for s, d in links_for("codex") if Path(s).name == "AGENTS.md"]

    if any(Path(s).exists() for s, _ in agents_links):
        print("applying codex global instructions")
        apply_links(agents_links)
    else:
        print("skipping codex global instructions: no codex/AGENTS.md present")

    ensure_codex_local_config()
    ensure_codex_hooks()


def install_neovim():
    if VERIFY_MODE:
        print("verify mode: skipping neovim package/bootstrap")
        apply_links(links_for("neovim"))
        print("verify mode: skipping neovim sync")
        return
    install_package("neovim")
    install_package("ripgrep")
    install_package("fd")
    install_homebrew_only_package("prettier")
    install_homebrew_only_package("ruff")
    install_homebrew_only_package("tree-sitter-cli")
    install_homebrew_only_package("typescript-language-server")
    install_homebrew_only_package("basedpyright")
    install_homebrew_only_package("gh")
    install_homebrew_only_package("chafa")
    install_homebrew_only_package("viu")
    install_homebrew_only_package("mercurial")
    install_npm_global("vscode-langservers-extracted", ("vscode-eslint-language-server",))
    ensure_fd_compat_shim()
    if not command_exists("nvim"):
        print("skipping neovim config: nvim is not installed")
        return
    apply_links(links_for("neovim"))
    print("syncing neovim plugins")
    run(["nvim", "--headless", "+lua require('lazy').sync({wait = true})", "+qa"])
    run(["nvim", "--headless", "-c", "TSUpdateSync", "-c", "quitall"])


def run_install_flow():
    install_homebrew()
    install_zsh_stack()
    install_ghostty()
    install_tmux()
    install_btop()
    install_vscode()
    install_claude()
    install_codex()
    install_neovim()
    print("Done")


def cleanup_links(dry_run=False):
    """Remove only the symlinks this repo created.

    A target is removed only when it is a symlink that resolves into this repo,
    so real user files (and symlinks pointing elsewhere) are left untouched.
    Packages, cloned repos, and ``*.bak.*`` backups are not affected.
    """
    label = " (dry run)" if dry_run else ""
    print(f"cleaning up repo-managed symlinks{label}")
    removed = 0
    skipped = 0
    for _category, source, target in managed_links():
        target = Path(target)
        if target.is_symlink():
            if target.resolve() == Path(source).resolve():
                if dry_run:
                    print(f"would remove link: {target}")
                else:
                    target.unlink()
                    print(f"removed link: {target}")
                removed += 1
            else:
                print(f"skipping {target}: symlink points outside repo -> {os.readlink(target)}")
                skipped += 1
        elif target.exists():
            print(f"skipping {target}: real file, not a repo symlink")
            skipped += 1

    verb = "would remove" if dry_run else "removed"
    print(f"cleanup done: {verb} {removed} link(s), skipped {skipped}")


def snapshot_tree(root):
    snapshot = {}
    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        dirpath_path = Path(dirpath)

        kept_dirs = []
        for dirname in sorted(dirnames):
            path = dirpath_path / dirname
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                snapshot[rel] = ("symlink", os.readlink(path))
            else:
                snapshot[rel] = ("dir",)
                kept_dirs.append(dirname)
        dirnames[:] = kept_dirs

        for filename in sorted(filenames):
            path = dirpath_path / filename
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                snapshot[rel] = ("symlink", os.readlink(path))
            elif path.is_file():
                snapshot[rel] = ("file", path.read_bytes())
    return snapshot


def verify_idempotent():
    global HOME, VERIFY_MODE, LINUX_APT_UPDATED

    print("verifying install.py idempotency (safe mode)")
    original_home = HOME
    original_verify = VERIFY_MODE
    original_apt_updated = LINUX_APT_UPDATED

    with tempfile.TemporaryDirectory(prefix="dotfiles-idempotent-") as tmpdir:
        HOME = Path(tmpdir) / "home"
        HOME.mkdir(parents=True, exist_ok=True)
        VERIFY_MODE = True
        LINUX_APT_UPDATED = False

        print(f"using temporary HOME: {HOME}")
        run_install_flow()
        first_snapshot = snapshot_tree(HOME)
        run_install_flow()
        second_snapshot = snapshot_tree(HOME)

        backup_files = sorted(HOME.rglob("*.bak.*"))
        if backup_files:
            print("idempotency check failed: backup files were created during verify mode", file=sys.stderr)
            for path in backup_files:
                print(f"- {path}", file=sys.stderr)
            sys.exit(1)

        if first_snapshot != second_snapshot:
            print("idempotency check failed: filesystem state changed between run #1 and run #2", file=sys.stderr)
            first_keys = set(first_snapshot)
            second_keys = set(second_snapshot)
            for rel in sorted(first_keys - second_keys):
                print(f"- missing after second run: {rel}", file=sys.stderr)
            for rel in sorted(second_keys - first_keys):
                print(f"- added after second run: {rel}", file=sys.stderr)
            for rel in sorted(first_keys & second_keys):
                if first_snapshot[rel] != second_snapshot[rel]:
                    print(f"- changed on second run: {rel}", file=sys.stderr)
            sys.exit(1)

        print("idempotency verification passed")

    HOME = original_home
    VERIFY_MODE = original_verify
    LINUX_APT_UPDATED = original_apt_updated


def verify_neovim_health():
    if not command_exists("nvim"):
        print("neovim health check failed: nvim is not installed", file=sys.stderr)
        sys.exit(1)

    with tempfile.NamedTemporaryFile(prefix="nvim-health-", suffix=".txt") as health_file:
        run([
            "nvim",
            "--headless",
            "+checkhealth",
            f"+write! {health_file.name}",
            "+qa",
        ])
        health = Path(health_file.name).read_text(encoding="utf-8", errors="replace")

    if "ERROR" in health or "❌" in health:
        print("neovim health check reported errors", file=sys.stderr)
        sys.exit(1)

    print("neovim health verification passed")


def parse_args():
    parser = argparse.ArgumentParser(description="Bootstrap dotfiles on macOS/Linux.")
    parser.add_argument(
        "--verify-idempotent",
        action="store_true",
        help="Run a safe two-pass install verification in a temporary HOME.",
    )
    parser.add_argument(
        "--verify-neovim-health",
        action="store_true",
        help="Run Neovim checkhealth and fail if health reports errors.",
    )
    parser.add_argument(
        "--cleanup",
        action="store_true",
        help="Remove repo-managed symlinks from $HOME (packages and real files are left untouched).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="With --cleanup, print what would be removed without changing anything.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    if args.verify_idempotent:
        verify_idempotent()
        return
    if args.verify_neovim_health:
        verify_neovim_health()
        return
    if args.cleanup:
        cleanup_links(dry_run=args.dry_run)
        return
    run_install_flow()


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(f"command failed with exit code {exc.returncode}: {exc.cmd}", file=sys.stderr)
        sys.exit(exc.returncode)
