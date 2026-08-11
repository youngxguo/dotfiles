import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { CompactFooter } from "./footer.js";
import { fetchWeeklyUsedPercent, parseWeeklyUsedPercent } from "./usage.js";

export default function (pi: ExtensionAPI) {
	let enabled = true;
	let currentFooter: CompactFooter | undefined;
	let weeklyUsedPercent: number | undefined;
	let weeklyUsageLookup = 0;

	function updateWeeklyUsedPercent(value: number | undefined) {
		weeklyUsedPercent = value;
		currentFooter?.setWeeklyUsedPercent(value);
	}

	async function refreshWeeklyUsedPercent(ctx: ExtensionContext) {
		const lookup = ++weeklyUsageLookup;
		updateWeeklyUsedPercent(undefined);
		const value = await fetchWeeklyUsedPercent(ctx);
		if (lookup === weeklyUsageLookup) updateWeeklyUsedPercent(value);
	}

	function applyFooter(ctx: ExtensionContext) {
		currentFooter = undefined;
		if (!enabled) {
			ctx.ui.setFooter(undefined);
			return;
		}

		ctx.ui.setFooter((tui, theme, data) => {
			currentFooter = new CompactFooter(pi, ctx, tui, theme, data, weeklyUsedPercent);
			return currentFooter;
		});
	}

	pi.on("session_start", (_event, ctx) => {
		applyFooter(ctx);
		void refreshWeeklyUsedPercent(ctx);
	});
	pi.on("after_provider_response", (event, ctx) => {
		if (ctx.model?.provider !== "openai-codex") return;
		const value = parseWeeklyUsedPercent(event.headers);
		if (value == null) return;
		weeklyUsageLookup++;
		updateWeeklyUsedPercent(value);
	});
	pi.on("model_select", (_event, ctx) => void refreshWeeklyUsedPercent(ctx));
	pi.on("tool_execution_end", (event) => {
		if (["bash", "edit", "write"].includes(event.toolName)) {
			currentFooter?.markRepositoryDirty();
		}
	});
	pi.on("agent_settled", () => currentFooter?.refreshDirtyRepository());

	pi.registerCommand("footer", {
		description: "Toggle the compact custom footer",
		handler: async (_args, ctx) => {
			enabled = !enabled;
			applyFooter(ctx);
			ctx.ui.notify(enabled ? "Custom footer enabled" : "Default footer restored", "info");
		},
	});
}
