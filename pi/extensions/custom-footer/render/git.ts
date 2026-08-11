import type { Theme } from "@earendil-works/pi-coding-agent";

import type { GitStatus } from "../repository.js";

export function renderGitStatus(status: GitStatus | undefined, theme: Theme): string {
	if (!status) return "";

	const fileChanges = status.staged + status.modified + status.untracked + status.conflicts;
	const parts = [
		fileChanges === 0 ? theme.fg("success", "✓ clean") : "",
		status.additions > 0 ? theme.fg("success", `+${status.additions}`) : "",
		status.deletions > 0 ? theme.fg("error", `-${status.deletions}`) : "",
		status.staged > 0 ? theme.fg("success", `●${status.staged}`) : "",
		status.modified > 0 ? theme.fg("warning", `~${status.modified}`) : "",
		status.untracked > 0 ? theme.fg("muted", `?${status.untracked}`) : "",
		status.conflicts > 0 ? theme.fg("error", `!${status.conflicts}`) : "",
		status.ahead > 0 ? theme.fg("accent", `↑${status.ahead}`) : "",
		status.behind > 0 ? theme.fg("warning", `↓${status.behind}`) : "",
	].filter(Boolean);
	return parts.join(" ");
}
