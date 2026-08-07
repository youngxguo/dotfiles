/**
 * Compact custom footer based on Pi's official custom-footer example.
 *
 * Shows extension statuses, model/thinking level, a context bar, session token
 * totals/cost, and the current Git branch. Toggle it with /footer.
 */

import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const BAR_WIDTH = 8;

function formatCount(value: number): string {
	if (value < 1_000) return `${value}`;
	if (value < 1_000_000) return `${(value / 1_000).toFixed(1).replace(/\.0$/, "")}k`;
	return `${(value / 1_000_000).toFixed(1).replace(/\.0$/, "")}m`;
}

export default function (pi: ExtensionAPI) {
	let enabled = true;

	function applyFooter(ctx: ExtensionContext) {
		if (!enabled) {
			ctx.ui.setFooter(undefined);
			return;
		}

		ctx.ui.setFooter((tui, theme, footerData) => {
			const unsubscribe = footerData.onBranchChange(() => tui.requestRender());

			return {
				dispose: unsubscribe,
				invalidate() {},
				render(width: number): string[] {
					const statuses = [...footerData.getExtensionStatuses().values()].join(theme.fg("dim", " · "));
					const model = ctx.model?.id ?? "no-model";
					const thinking = ctx.thinkingLevel === "off" ? "" : ` ${theme.fg("accent", `⚡ ${ctx.thinkingLevel}`)}`;
					const left = [statuses, `${theme.fg("accent", `🧠 ${model}`)}${thinking}`].filter(Boolean).join("  ");

					const usage = ctx.getContextUsage();
					const percent = usage?.percent == null ? undefined : Math.max(0, Math.min(100, usage.percent));
					const filled = percent == null ? 0 : Math.round((percent / 100) * BAR_WIDTH);
					const barColor = percent == null ? "dim" : percent >= 85 ? "error" : percent >= 65 ? "warning" : "success";
					const bar = theme.fg(barColor, "█".repeat(filled)) + theme.fg("dim", "░".repeat(BAR_WIDTH - filled));
					const context = percent == null ? `🧩 ${bar} ?` : `🧩 ${bar} ${Math.round(percent)}%`;

					let input = 0;
					let output = 0;
					let cost = 0;
					for (const entry of ctx.sessionManager.getBranch()) {
						if (entry.type !== "message" || entry.message.role !== "assistant") continue;
						const message = entry.message as AssistantMessage;
						input += message.usage.input;
						output += message.usage.output;
						cost += message.usage.cost.total;
					}

					const metrics = `↑${formatCount(input)} ↓${formatCount(output)}`;
					const costText = cost > 0 ? `💰 $${cost.toFixed(3)}` : "";
					const branch = footerData.getGitBranch();
					const branchText = branch ? `🌿 ${branch}` : "";
					const right = [context, metrics, costText, branchText].filter(Boolean).map((part) => theme.fg("dim", part)).join("  ");

					const padding = " ".repeat(Math.max(1, width - visibleWidth(left) - visibleWidth(right)));
					return [truncateToWidth(left + padding + right, width)];
				},
			};
		});
	}

	pi.on("session_start", (_event, ctx) => applyFooter(ctx));

	pi.registerCommand("footer", {
		description: "Toggle the compact custom footer",
		handler: async (_args, ctx) => {
			enabled = !enabled;
			applyFooter(ctx);
			ctx.ui.notify(enabled ? "Custom footer enabled" : "Default footer restored", "info");
		},
	});
}
