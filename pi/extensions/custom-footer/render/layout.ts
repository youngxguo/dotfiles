import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

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
