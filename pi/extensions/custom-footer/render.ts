import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const BAR_WIDTH = 8;
const FOOTER_GAP = 2;

export function alignSides(left: string, right: string, width: number): string {
	if (width <= 0) return "";
	if (!left) {
		const renderedRight = truncateToWidth(right, width, "…");
		return " ".repeat(width - visibleWidth(renderedRight)) + renderedRight;
	}
	if (!right) return truncateToWidth(left, width, "…");
	if (width <= FOOTER_GAP) return truncateToWidth(left, width, "…");

	const available = width - FOOTER_GAP;
	let leftBudget = Math.min(visibleWidth(left), Math.floor(available / 2));
	const rightBudget = Math.min(visibleWidth(right), available - leftBudget);
	leftBudget = Math.min(visibleWidth(left), available - rightBudget);

	const renderedLeft = truncateToWidth(left, leftBudget, "…");
	const renderedRight = truncateToWidth(right, rightBudget, "…");
	return (
		renderedLeft +
		" ".repeat(width - visibleWidth(renderedLeft) - visibleWidth(renderedRight)) +
		renderedRight
	);
}

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
