import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { CompactFooter } from "./footer.js";
import { fetchWeeklyUsedPercent } from "./usage.js";

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
		const value = await fetchWeeklyUsedPercent(ctx);
		if (lookup === weeklyUsageLookup && value != null) updateWeeklyUsedPercent(value);
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
	pi.on("model_select", (event, ctx) => {
		if (event.model.provider === "openai-codex") {
			void refreshWeeklyUsedPercent(ctx);
		} else {
			weeklyUsageLookup++;
			updateWeeklyUsedPercent(undefined);
		}
	});
	pi.on("tool_execution_end", (event) => {
		if (["bash", "edit", "write"].includes(event.toolName)) {
			currentFooter?.markRepositoryDirty();
		}
	});
	pi.on("agent_settled", (_event, ctx) => {
		currentFooter?.refreshDirtyRepository();
		if (ctx.model?.provider === "openai-codex") void refreshWeeklyUsedPercent(ctx);
	});

	pi.registerCommand("footer", {
		description: "Toggle the compact custom footer",
		handler: async (_args, ctx) => {
			enabled = !enabled;
			applyFooter(ctx);
			ctx.ui.notify(enabled ? "Custom footer enabled" : "Default footer restored", "info");
		},
	});
}
