import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

import { CompactFooter } from "./footer.js";

export default function (pi: ExtensionAPI) {
	let enabled = true;
	let currentFooter: CompactFooter | undefined;

	function applyFooter(ctx: ExtensionContext) {
		currentFooter = undefined;
		if (!enabled) {
			ctx.ui.setFooter(undefined);
			return;
		}

		ctx.ui.setFooter((tui, theme, data) => {
			currentFooter = new CompactFooter(pi, ctx, tui, theme, data);
			return currentFooter;
		});
	}

	pi.on("session_start", (_event, ctx) => applyFooter(ctx));
	pi.on("agent_settled", () => currentFooter?.refreshPullRequest());

	pi.registerCommand("footer", {
		description: "Toggle the compact custom footer",
		handler: async (_args, ctx) => {
			enabled = !enabled;
			applyFooter(ctx);
			ctx.ui.notify(enabled ? "Custom footer enabled" : "Default footer restored", "info");
		},
	});
}
