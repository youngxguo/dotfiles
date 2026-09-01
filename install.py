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
UPDATE_PLUGINS = False
BTOP_VERSION = "v1.4.7"
GH_EXTENSIONS = ("dlvhdr/gh-dash",)
HERDR_INSTALL_URL = "https://herdr.dev/install.sh"
# (owner/repo, plugin id). herdr/config.toml binds ctrl+hjkl to this plugin's
# nav-* actions, and `herdr config check` validates syntax only — an unresolved
# action is dropped silently, so without this the keys are dead on a new machine.
HERDR_PLUGINS = (("lmilojevicc/herdr-splits.nvim", "herdr-splits"),)
PI_NPM_PACKAGE = "@earendil-works/pi-coding-agent"
# pi's package.json engines field. npm refuses the install below it, and a
# distro node is often older, so check it up front to say why pi was skipped.
PI_MIN_NODE_VERSION = (22, 19, 0)
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
    },
    "node": {
        "apt": "nodejs",
        "dnf": "nodejs",
        "pacman": "nodejs",
        "zypper": "nodejs",
    },
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

    shim.write_text(
        f'#!/usr/bin/env sh\nexec {shlex.quote(fdfind)} "$@"\n', encoding="utf-8"
    )
    shim.chmod(0o755)
    print(f"created fd compatibility shim at {shim} (ensure {local_bin} is in PATH)")


def linux_install(pkg):
    global LINUX_APT_UPDATED

    manager = linux_package_manager()
    if not manager:
        print(
            f"skipping {pkg}: no supported linux package manager found (apt/dnf/pacman/zypper)"
        )
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
        install_cmd = with_privilege(
            ["zypper", "--non-interactive", "install", target_pkg]
        )

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
    result = subprocess.run(
        ["brew", "list", pkg], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
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
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not member.isfile():
            raise RuntimeError(
                f"refusing to extract non-file tar member: {member.name}"
            )

        source = tar.extractfile(member)
        if source is None:
            raise RuntimeError(f"unable to read tar member: {member.name}")
        target.parent.mkdir(parents=True, exist_ok=True)
        with source, target.open("wb") as output:
            shutil.copyfileobj(source, output)
        target.chmod(member.mode & 0o777)


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
        print(
            f"cannot clone {repo_url} because {target} already exists and is not a git repo"
        )
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
        backup = target.with_name(
            f"{target.name}.bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
        )
        target.rename(backup)
        print(f"backed up existing file to {backup}")

    target.symlink_to(source)


def managed_links():
    """Return every symlink managed by the setup flow.

    Dynamic categories (ghostty assets, tmux scripts) are enumerated from
    whatever currently exists in the repo; targets read the module-global
    ``HOME`` at call time so verify mode works.
    """
    links = [
        ("zsh", REPO_ROOT / "zsh/.zshrc", HOME / ".zshrc"),
        ("zsh", REPO_ROOT / "starship/starship.toml", HOME / ".config/starship.toml"),
        ("ghostty", REPO_ROOT / "ghostty/config", HOME / ".config/ghostty/config"),
        ("herdr", REPO_ROOT / "herdr/config.toml", HOME / ".config/herdr/config.toml"),
    ]

    shader_dir = REPO_ROOT / "ghostty/shaders"
    if shader_dir.is_dir():
        for shader_file in sorted(shader_dir.glob("*.glsl")):
            links.append(
                (
                    "ghostty",
                    shader_file,
                    HOME / ".config/ghostty/shaders" / shader_file.name,
                )
            )
    theme_dir = REPO_ROOT / "ghostty/themes"
    if theme_dir.is_dir():
        for theme_file in sorted(theme_dir.iterdir()):
            if theme_file.is_file():
                links.append(
                    (
                        "ghostty",
                        theme_file,
                        HOME / ".config/ghostty/themes" / theme_file.name,
                    )
                )

    links.append(("tmux", REPO_ROOT / "tmux/.tmux.conf", HOME / ".tmux.conf"))
    for script in sorted((REPO_ROOT / "tmux").glob(".tmux-*.sh")):
        links.append(("tmux", script, HOME / script.name))

    links.append(
        (
            "btop",
            REPO_ROOT / "btop/.config/btop/btop.conf",
            HOME / ".config/btop/btop.conf",
        )
    )

    if sys.platform == "darwin":
        vscode_user_dir = HOME / "Library/Application Support/Code/User"
    else:
        vscode_user_dir = HOME / ".config/Code/User"
    links.append(
        (
            "vscode",
            REPO_ROOT / "vscode/settings.json",
            vscode_user_dir / "settings.json",
        )
    )
    links.append(
        (
            "vscode",
            REPO_ROOT / "vscode/keybindings.json",
            vscode_user_dir / "keybindings.json",
        )
    )

    links.append(("claude", REPO_ROOT / "claude/CLAUDE.md", HOME / ".claude/CLAUDE.md"))
    links.append(
        (
            "claude",
            REPO_ROOT / "claude/statusline-command.sh",
            HOME / ".claude/statusline-command.sh",
        )
    )
    for script in sorted((REPO_ROOT / "claude/hooks").glob("*.sh")):
        links.append(("claude", script, HOME / ".claude/hooks" / script.name))
    links.append(("codex", REPO_ROOT / "codex/AGENTS.md", HOME / ".codex/AGENTS.md"))

    links.append(
        ("pi", REPO_ROOT / "pi/settings.json", HOME / ".pi/agent/settings.json")
    )
    links.append(
        ("pi", REPO_ROOT / "pi/pi-lens-config.json", HOME / ".pi-lens/config.json")
    )
    pi_themes_dir = REPO_ROOT / "pi/themes"
    if pi_themes_dir.is_dir():
        for theme_file in sorted(pi_themes_dir.glob("*.json")):
            links.append(
                ("pi", theme_file, HOME / ".pi/agent/themes" / theme_file.name)
            )

    pi_extensions_dir = REPO_ROOT / "pi/extensions"
    if pi_extensions_dir.is_dir():
        for extension in sorted(pi_extensions_dir.iterdir()):
            is_extension_file = extension.is_file() and extension.suffix == ".ts"
            is_extension_dir = extension.is_dir() and (extension / "index.ts").is_file()
            if is_extension_file or is_extension_dir:
                links.append(
                    ("pi", extension, HOME / ".pi/agent/extensions" / extension.name)
                )

    pets_dir = REPO_ROOT / "codex/pets"
    if pets_dir.is_dir():
        for pet_dir in sorted(pets_dir.iterdir()):
            if (pet_dir / "pet.json").is_file() and (
                pet_dir / "spritesheet.webp"
            ).is_file():
                links.append(
                    ("codex-pets", pet_dir, HOME / ".codex/pets" / pet_dir.name)
                )

    links.append(("neovim", REPO_ROOT / "neovim/.config/nvim", HOME / ".config/nvim"))

    return links


def links_for(category):
    return [
        (source, target) for cat, source, target in managed_links() if cat == category
    ]


def apply_links(links):
    """Symlink each configured source to its target; return count applied."""
    applied = 0
    for source, target in links:
        if not Path(source).exists():
            raise FileNotFoundError(f"missing repo source: {source}")
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
    if (
        sys.platform.startswith("linux")
        and os.environ.get("INSTALL_HOMEBREW", "0") != "1"
    ):
        print(
            "skipping homebrew bootstrap on linux (set INSTALL_HOMEBREW=1 to force install)"
        )
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
        print(
            "warning: unable to install homebrew; continuing without brew-managed packages"
        )
        return False
    return command_exists("brew")


def install_github_cli():
    print("installing github cli")
    if VERIFY_MODE:
        print("verify mode: skipping github cli package/extension bootstrap")
        return
    if not install_homebrew_only_package("gh"):
        print("skipping github cli extensions: gh is not installed")
        return

    try:
        extension_output = subprocess.check_output(
            ["gh", "extension", "list"], text=True, stderr=subprocess.DEVNULL
        )
    except subprocess.CalledProcessError:
        print(
            "skipping github cli extensions: gh is not authenticated "
            "(run `gh auth login`, then re-run install.py)"
        )
        return

    installed_extensions = {
        columns[1]
        for line in extension_output.splitlines()
        if len(columns := line.split("\t")) >= 2
    }
    for extension in GH_EXTENSIONS:
        if extension in installed_extensions:
            print(f"github cli extension {extension} already installed")
        else:
            try:
                run(["gh", "extension", "install", extension])
            except subprocess.CalledProcessError:
                print(
                    f"warning: unable to install gh extension {extension}; continuing"
                )


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


def install_ghostty():
    print("applying ghostty config")
    apply_links(links_for("ghostty"))


def herdr_command():
    # the upstream installer drops the binary in ~/.local/bin, which zsh/.zshrc
    # adds to PATH but the shell running install.py may not have yet.
    if command_exists("herdr"):
        return "herdr"
    fallback = HOME / ".local/bin/herdr"
    return str(fallback) if fallback.is_file() else None


def herdr_installed():
    return herdr_command() is not None


def lazy_lock_commit(plugin_name):
    # herdr-splits ships both halves from one repo: the herdr-side actions and
    # the neovim-side plugin have to speak the same protocol, so pin herdr's copy
    # to whatever lazy already pinned instead of drifting onto the default branch.
    lockfile = REPO_ROOT / "neovim/.config/nvim/lazy-lock.json"
    try:
        pins = json.loads(lockfile.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    entry = pins.get(plugin_name)
    return entry.get("commit") if isinstance(entry, dict) else None


def install_herdr_plugins():
    herdr = herdr_command()
    if herdr is None:
        print("skipping herdr plugins: herdr is not installed")
        return

    try:
        plugin_output = subprocess.check_output(
            [herdr, "plugin", "list"], text=True, stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, OSError):
        print("skipping herdr plugins: unable to list installed plugins")
        return

    for repo, plugin_id in HERDR_PLUGINS:
        if plugin_id in plugin_output:
            print(f"herdr plugin {plugin_id} already installed")
            continue
        commit = lazy_lock_commit(repo.rsplit("/", 1)[-1])
        pin = ["--ref", commit] if commit else []
        try:
            run([herdr, "plugin", "install", repo, *pin, "-y"])
        except subprocess.CalledProcessError:
            print(f"warning: unable to install herdr plugin {repo}; continuing")

    # keybindings resolve plugin actions at load time, so a server that was
    # already up keeps dropping ctrl+hjkl until it re-reads the config. on a
    # fresh machine there is no server yet and the first launch reads it anyway.
    try:
        status = subprocess.check_output(
            [herdr, "status", "server"], text=True, stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, OSError):
        return
    if "status: running" not in status:
        return
    try:
        run([herdr, "server", "reload-config"])
    except subprocess.CalledProcessError:
        print(
            "warning: unable to reload herdr config; restart herdr to pick up plugins"
        )


def install_herdr():
    print("installing herdr")
    if VERIFY_MODE:
        print("verify mode: skipping herdr bootstrap")
    elif herdr_installed():
        print("herdr already installed")
    else:
        # upstream's installer covers macos/linux on x86_64/aarch64, checks the
        # release checksum, and installs to ~/.local/bin. homebrew only carries
        # the stable channel, so this keeps both platforms on one path and lets
        # `herdr update` follow the preview channel from herdr/config.toml.
        try:
            run(["sh", "-c", f"curl -fsSL {HERDR_INSTALL_URL} | sh"])
        except subprocess.CalledProcessError:
            print("warning: unable to install herdr; continuing")

    print("applying herdr config")
    apply_links(links_for("herdr"))

    if not VERIFY_MODE:
        print("installing herdr plugins")
        install_herdr_plugins()


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
    try:
        fragment = json.loads(fragment_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"skipping codex ai-state hooks: unable to read {fragment_path}: {exc}")
        return
    if not isinstance(fragment, dict):
        print(f"skipping codex ai-state hooks: {fragment_path} is not a JSON object")
        return
    wanted = fragment.get("hooks", {})
    if not wanted:
        return
    if not isinstance(wanted, dict):
        print(
            f"skipping codex ai-state hooks: {fragment_path} hooks is not a JSON object"
        )
        return

    target = HOME / ".codex/hooks.json"
    if target.exists():
        try:
            settings = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
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
            for group in existing
            if isinstance(group, dict)
            for hook in group.get("hooks", [])
            if isinstance(hook, dict)
        }
        for group in groups:
            commands = {
                h.get("command") for h in group.get("hooks", []) if isinstance(h, dict)
            }
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


# settings.json keys the Claude template owns outright. Everything else in the
# live file is preserved so runtime-managed and machine-local state stays local.
CLAUDE_SETTINGS_KEYS = ("permissions", "statusLine")


def merge_claude_settings():
    """Merge repo-owned Claude settings while preserving runtime-managed keys.

    The template owns ``CLAUDE_SETTINGS_KEYS`` plus each hook event it declares;
    hook events it doesn't declare and every other live key pass through.
    """
    source = REPO_ROOT / "claude/settings.json"
    target = HOME / ".claude/settings.json"
    try:
        template = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"skipping claude settings: unable to read {source}: {exc}")
        return
    if not isinstance(template, dict):
        print(f"skipping claude settings: {source} is not a JSON object")
        return

    if target.is_symlink():
        raise RuntimeError(f"refusing to overwrite symlink: {target}")
    settings = {}
    if target.is_file():
        try:
            settings = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
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
    print("applying claude config")
    apply_links(links_for("claude"))
    merge_claude_settings()


def node_version():
    """Return the installed node version as a (major, minor, patch) tuple."""
    if not command_exists("node"):
        return None
    try:
        raw = subprocess.check_output(["node", "--version"], text=True).strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    parts = raw.lstrip("v").split("-", 1)[0].split(".")[:3]
    try:
        return tuple(int(part) for part in parts)
    except ValueError:
        return None


def npm_global_prefix():
    try:
        prefix = subprocess.check_output(["npm", "prefix", "-g"], text=True).strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    return Path(prefix) if prefix else None


def pi_installed():
    # npm's global bin is not necessarily on PATH in the shell running this
    # script (a linux system node puts it in /usr/bin, nvm under ~/.nvm), so
    # fall back to the prefix npm would install into before reinstalling.
    if command_exists("pi"):
        return True
    prefix = npm_global_prefix()
    return prefix is not None and (prefix / "bin/pi").exists()


def install_pi_cli():
    if not command_exists("npm"):
        install_package("node")
        # debian and friends ship npm separately from the nodejs package.
        if not command_exists("npm") and sys.platform.startswith("linux"):
            install_package("npm")
    if not command_exists("npm"):
        print("skipping pi: npm is not available")
        return

    version = node_version()
    wanted = ".".join(str(part) for part in PI_MIN_NODE_VERSION)
    if version is None or version < PI_MIN_NODE_VERSION:
        found = ".".join(str(part) for part in version) if version else "none"
        print(f"skipping pi: node {wanted}+ is required (found {found})")
        return

    # upstream's curl installer is an interactive menu that also offers to edit
    # the shell profile zsh/.zshrc already owns, so run the npm install it ends
    # up performing instead. --ignore-scripts is upstream's documented quick
    # start: pi needs no dependency lifecycle scripts.
    cmd = ["npm", "install", "-g", "--ignore-scripts", PI_NPM_PACKAGE]
    prefix = npm_global_prefix()
    if prefix is not None and not os.access(prefix, os.W_OK):
        # homebrew and nvm prefixes belong to the user; a linux system node
        # installs globals under a root-owned /usr.
        privileged = with_privilege(cmd)
        if not privileged:
            print("skipping pi: sudo is required to write to npm's global prefix")
            return
        cmd = privileged

    try:
        run(cmd)
    except subprocess.CalledProcessError:
        print("warning: unable to install pi; continuing")


def install_pi():
    print("installing pi")
    if VERIFY_MODE:
        print("verify mode: skipping pi bootstrap")
    elif pi_installed():
        print("pi already installed")
    else:
        install_pi_cli()

    print("applying pi config")
    apply_links(links_for("pi"))


def ensure_codex_local_config():
    """Seed a local Codex config when one does not already exist."""
    target = HOME / ".codex/config.toml"
    template = REPO_ROOT / "codex/config.example.toml"

    if target.is_symlink() or target.exists():
        print(f"leaving existing codex config unmanaged: {target}")
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(template, target)
    print(f"created local codex config from {template}: {target}")


def install_codex():
    print("applying codex global instructions")
    apply_links(links_for("codex"))

    ensure_codex_local_config()
    ensure_codex_hooks()

    pet_links = links_for("codex-pets")
    if pet_links:
        print("applying codex pets")
        apply_links(pet_links)


def neovim_lua_command(lua):
    return ["nvim", "--headless", f"+lua {lua}", "+qa"]


def neovim_plugin_commands(update=False):
    """Return the headless nvim commands that bring plugins to the wanted state.

    Installing and updating are deliberately separate. ``lazy.sync()`` is
    clean + install + *update*, and update fetches the newest commit matching
    each version spec and then rewrites lazy-lock.json — so running it here
    would make a "fresh machine" install whatever landed upstream that morning
    and leave the repo dirty on every run. The committed lockfile is the
    contract instead: ``install`` clones missing plugins straight to their
    locked commits, and ``restore`` pulls already-installed ones back to the
    lock (it only touches installed plugins, which is why both are needed).
    Moving the lock is then an explicit act via ``--update-plugins``, whose
    diff you review and commit.
    """
    if update:
        print("updating neovim plugins (this rewrites lazy-lock.json)")
        plugins = [neovim_lua_command("require('lazy').sync({wait = true})")]
    else:
        print("installing neovim plugins at their locked commits")
        plugins = [
            neovim_lua_command(
                "require('lazy').install({wait = true, lockfile = true})"
            ),
            neovim_lua_command("require('lazy').restore({wait = true})"),
        ]
    # parsers are not covered by lazy-lock.json; treesitter tracks its own
    # revisions per parser and TSUpdateSync is the only way to fetch them.
    return [*plugins, ["nvim", "--headless", "-c", "TSUpdateSync", "-c", "quitall"]]


def ensure_typescript_fallback():
    """Install the typescript that ts_ls falls back to when a project has none.

    typescript-language-server drives a real typescript install and exits
    during `initialize` without one, so a repo whose node_modules are not
    installed - or a stray .ts file outside any package - takes the whole LSP
    client down with an error. The neovim config points `tsserver.path` at this
    copy; nothing else uses it.
    """
    target = HOME / ".local/share/nvim/ts-fallback"
    if (target / "node_modules/typescript/lib/tsserver.js").exists():
        print("neovim typescript fallback already installed")
        return
    if VERIFY_MODE:
        print("verify mode: skipping neovim typescript fallback")
        return
    if not command_exists("npm"):
        print("skipping neovim typescript fallback: npm is not available")
        return
    target.mkdir(parents=True, exist_ok=True)
    run(
        [
            "npm",
            "install",
            "--prefix",
            str(target),
            "--no-audit",
            "--no-fund",
            "typescript@5",
        ]
    )


def install_neovim():
    if VERIFY_MODE:
        print("verify mode: skipping neovim package/bootstrap")
        apply_links(links_for("neovim"))
        # nvim reads $HOME from the environment, not our patched module global,
        # so running it here would mutate the real plugin dir and lockfile that
        # verify mode exists to avoid touching. neovim_plugin_commands is
        # covered by install_test.py instead.
        print("verify mode: skipping neovim plugin bootstrap")
        return
    install_package("neovim")
    install_package("ripgrep")
    install_package("fd")
    install_homebrew_only_package("prettier")
    install_homebrew_only_package("ruff")
    install_homebrew_only_package("tree-sitter-cli")
    install_homebrew_only_package("typescript-language-server")
    ensure_typescript_fallback()
    install_homebrew_only_package("basedpyright")
    install_homebrew_only_package("chafa")
    install_homebrew_only_package("viu")
    install_homebrew_only_package("mercurial")
    ensure_fd_compat_shim()
    if not command_exists("nvim"):
        print("skipping neovim config: nvim is not installed")
        return
    apply_links(links_for("neovim"))
    for command in neovim_plugin_commands(update=UPDATE_PLUGINS):
        run(command)


def run_install_flow():
    install_homebrew()
    install_github_cli()
    install_zsh_stack()
    install_ghostty()
    install_herdr()
    install_tmux()
    install_btop()
    install_vscode()
    install_claude()
    install_codex()
    install_pi()
    install_neovim()
    print("Done")


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
            print(
                "idempotency check failed: backup files were created during verify mode",
                file=sys.stderr,
            )
            for path in backup_files:
                print(f"- {path}", file=sys.stderr)
            sys.exit(1)

        if first_snapshot != second_snapshot:
            print(
                "idempotency check failed: filesystem state changed between run #1 and run #2",
                file=sys.stderr,
            )
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


def parse_args():
    parser = argparse.ArgumentParser(description="Bootstrap dotfiles on macOS/Linux.")
    parser.add_argument(
        "--verify-idempotent",
        action="store_true",
        help="Run a safe two-pass install verification in a temporary HOME.",
    )
    parser.add_argument(
        "--update-plugins",
        action="store_true",
        help=(
            "Update neovim plugins to the newest allowed commits and rewrite "
            "lazy-lock.json. Without this, plugins are pinned to the lockfile."
        ),
    )
    return parser.parse_args()


def main():
    global UPDATE_PLUGINS

    args = parse_args()
    if args.verify_idempotent:
        verify_idempotent()
        return
    UPDATE_PLUGINS = args.update_plugins
    run_install_flow()


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(
            f"command failed with exit code {exc.returncode}: {exc.cmd}",
            file=sys.stderr,
        )
        sys.exit(exc.returncode)
