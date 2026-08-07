/**
 * Turn status based on Pi's official status-line example.
 * The custom footer renders this alongside its other segments.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	let turnCount = 0;

	pi.on("session_start", (_event, ctx) => {
		turnCount = 0;
		ctx.ui.setStatus("turn-status", ctx.ui.theme.fg("success", "🟢 Ready"));
	});

	pi.on("turn_start", (_event, ctx) => {
		turnCount++;
		ctx.ui.setStatus(
			"turn-status",
			ctx.ui.theme.fg("accent", `🟠 Turn ${turnCount}…`),
		);
	});

	pi.on("turn_end", (_event, ctx) => {
		ctx.ui.setStatus(
			"turn-status",
			ctx.ui.theme.fg("success", `✅ Turn ${turnCount}`),
		);
	});
}
