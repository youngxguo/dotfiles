#!/usr/bin/env bash
# Verify ~/.tmux-palette.sh is the sole hex source and covers every @solarized_*
# reference in ~/.tmux.conf.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

python3 - "$repo/tmux/.tmux-palette.sh" "$repo/tmux/.tmux.conf" <<'PY'
import re
import sys
from pathlib import Path

palette_path = Path(sys.argv[1])
conf_path = Path(sys.argv[2])

palette = dict(
    re.findall(r'^TMUX_PALETTE_(\w+)="(#[0-9a-fA-F]{6})"', palette_path.read_text(), re.M)
)
conf = conf_path.read_text()

def to_option(name: str) -> str:
    return f"solarized_{name.lower()}"

loaded = {to_option(name): hex_color for name, hex_color in palette.items()}
referenced = {f"solarized_{name}" for name in re.findall(r'@solarized_(\w+)', conf)}

errors = []
for opt in sorted(referenced):
    if opt not in loaded:
        errors.append(f"@{opt} used in {conf_path.name} but not defined in {palette_path.name}")

if errors:
    print("tmux palette drift:", file=sys.stderr)
    for err in errors:
        print(f"  {err}", file=sys.stderr)
    sys.exit(1)

print(f"ok   - tmux palette ({len(loaded)} colours, conf references covered)")
PY
