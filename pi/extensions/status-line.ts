/**
 * Agent activity status rendered by the custom footer.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		ctx.ui.setStatus("agent-status", ctx.ui.theme.fg("success", "🟢"));
	});

	pi.on("agent_start", (_event, ctx) => {
		ctx.ui.setStatus("agent-status", ctx.ui.theme.fg("accent", "🟠"));
	});

	pi.on("agent_settled", (_event, ctx) => {
		ctx.ui.setStatus("agent-status", ctx.ui.theme.fg("success", "🟢"));
	});
}
