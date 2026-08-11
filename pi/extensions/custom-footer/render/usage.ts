import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";

const BAR_WIDTH = 8;

export function renderContextUsage(ctx: ExtensionContext, theme: Theme): string {
	const percent = ctx.getContextUsage()?.percent;
	const boundedPercent = percent == null ? undefined : Math.max(0, Math.min(100, percent));
	const filled = boundedPercent == null ? 0 : Math.round((boundedPercent / 100) * BAR_WIDTH);
	const color =
		boundedPercent == null
			? "dim"
			: boundedPercent >= 85
				? "error"
				: boundedPercent >= 65
					? "warning"
					: "success";
	const bar =
		theme.fg(color, "█".repeat(filled)) + theme.fg("dim", "░".repeat(BAR_WIDTH - filled));
	const label = boundedPercent == null ? "?" : `${Math.round(boundedPercent)}%`;
	return theme.fg("dim", `🧩 ${bar} ${label}`);
}

export function renderWeeklyUsage(usedPercent: number | undefined, theme: Theme): string {
	if (usedPercent == null) return "";
	const remaining = 100 - usedPercent;
	const filled = Math.round((remaining / 100) * BAR_WIDTH);
	const color = remaining <= 15 ? "error" : remaining <= 35 ? "warning" : "success";
	const bar =
		theme.fg(color, "█".repeat(filled)) + theme.fg("dim", "░".repeat(BAR_WIDTH - filled));
	return theme.fg("dim", `📅 week ${bar} ${Math.round(remaining)}% left`);
}
