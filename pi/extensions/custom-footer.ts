/**
 * Compact custom footer based on Pi's official custom-footer example.
 *
 * Shows extension statuses, model/thinking level, context and weekly Codex
 * usage bars and the current Git branch and pull request. Toggle it with
 * /footer.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { hyperlink, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

const BAR_WIDTH = 8;
const WEEK_MINUTES = 7 * 24 * 60;
const FOOTER_GAP = 2;

function alignFooterSides(left: string, right: string, width: number): string {
	if (width <= 0) return "";
	if (!left) {
		const renderedRight = truncateToWidth(right, width, "…");
		return " ".repeat(Math.max(0, width - visibleWidth(renderedRight))) + renderedRight;
	}
	if (!right) return truncateToWidth(left, width, "…");
	if (width <= FOOTER_GAP) return truncateToWidth(left, width, "…");

	const leftWidth = visibleWidth(left);
	const rightWidth = visibleWidth(right);
	if (leftWidth + FOOTER_GAP + rightWidth <= width) {
		return left + " ".repeat(width - leftWidth - rightWidth) + right;
	}

	const available = width - FOOTER_GAP;
	let leftBudget = Math.min(leftWidth, Math.floor(available / 2));
	const rightBudget = Math.min(rightWidth, available - leftBudget);
	leftBudget = Math.min(leftWidth, available - rightBudget);

	const renderedLeft = truncateToWidth(left, leftBudget, "…");
	const renderedRight = truncateToWidth(right, rightBudget, "…");
	const padding = " ".repeat(
		Math.max(FOOTER_GAP, width - visibleWidth(renderedLeft) - visibleWidth(renderedRight)),
	);
	return truncateToWidth(renderedLeft + padding + renderedRight, width, "");
}

type RateLimitWindow = {
	usedPercent: number;
	windowMinutes: number;
};

type JsonRecord = Record<string, unknown>;

function isRecord(value: unknown): value is JsonRecord {
	return typeof value === "object" && value != null && !Array.isArray(value);
}

function parseRateLimitWindow(
	headers: Record<string, string>,
	name: "primary" | "secondary",
): RateLimitWindow | undefined {
	const normalizedHeaders = Object.fromEntries(
		Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]),
	);
	const usedPercent = Number(normalizedHeaders[`x-codex-${name}-used-percent`]);
	const windowMinutes = Number(normalizedHeaders[`x-codex-${name}-window-minutes`]);
	if (!Number.isFinite(usedPercent) || !Number.isFinite(windowMinutes)) return undefined;
	return {
		usedPercent: Math.max(0, Math.min(100, usedPercent)),
		windowMinutes,
	};
}

function isWeeklyWindow(windowMinutes: number): boolean {
	return windowMinutes >= WEEK_MINUTES * 0.95 && windowMinutes <= WEEK_MINUTES * 1.05;
}

function parseWeeklyUsedPercent(headers: Record<string, string>): number | undefined {
	return (["primary", "secondary"] as const)
		.map((name) => parseRateLimitWindow(headers, name))
		.filter((window): window is RateLimitWindow => window != null)
		.find((window) => isWeeklyWindow(window.windowMinutes))?.usedPercent;
}

function parseWeeklyUsedPercentFromUsage(payload: unknown): number | undefined {
	if (!isRecord(payload) || !isRecord(payload.rate_limit)) return undefined;
	for (const name of ["primary_window", "secondary_window"] as const) {
		const window = payload.rate_limit[name];
		if (!isRecord(window)) continue;
		const usedPercent = window.used_percent;
		const windowSeconds = window.limit_window_seconds;
		if (
			typeof usedPercent === "number" &&
			Number.isFinite(usedPercent) &&
			typeof windowSeconds === "number" &&
			Number.isFinite(windowSeconds) &&
			isWeeklyWindow(windowSeconds / 60)
		) {
			return Math.max(0, Math.min(100, usedPercent));
		}
	}
	return undefined;
}

function extractAccountId(token: string): string | undefined {
	try {
		const encodedPayload = token.split(".")[1];
		if (!encodedPayload) return undefined;
		const payload: unknown = JSON.parse(
			Buffer.from(encodedPayload, "base64url").toString("utf8"),
		);
		if (!isRecord(payload)) return undefined;
		const auth = payload["https://api.openai.com/auth"];
		if (!isRecord(auth)) return undefined;
		return typeof auth.chatgpt_account_id === "string" ? auth.chatgpt_account_id : undefined;
	} catch {
		return undefined;
	}
}

type OpenPullRequest = {
	number: number;
	url: string;
};

async function findOpenPullRequest(
	pi: ExtensionAPI,
	cwd: string,
	branch: string,
): Promise<OpenPullRequest | undefined> {
	try {
		const result = await pi.exec(
			"gh",
			["pr", "list", "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"],
			{ cwd, timeout: 5_000 },
		);
		if (result.code !== 0) return undefined;
		const pullRequests: unknown = JSON.parse(result.stdout);
		if (!Array.isArray(pullRequests)) return undefined;
		const pullRequest = pullRequests[0] as { number?: unknown; url?: unknown } | undefined;
		return typeof pullRequest?.number === "number" && typeof pullRequest.url === "string"
			? { number: pullRequest.number, url: pullRequest.url }
			: undefined;
	} catch {
		return undefined;
	}
}

export default function (pi: ExtensionAPI) {
	let enabled = true;
	let weeklyUsedPercent: number | undefined;
	let requestFooterRender: (() => void) | undefined;
	let refreshPullRequest: (() => void) | undefined;

	function updateWeeklyUsedPercent(value: number | undefined) {
		if (value == null) return;
		weeklyUsedPercent = value;
		requestFooterRender?.();
	}

	async function refreshWeeklyUsedPercent(ctx: ExtensionContext) {
		if (ctx.model?.provider !== "openai-codex") return;
		try {
			const authResult = await ctx.modelRegistry.getProviderAuth("openai-codex");
			const token = authResult?.auth.apiKey;
			const accountId = token ? extractAccountId(token) : undefined;
			if (!token || !accountId) return;

			const baseUrl = (authResult.auth.baseUrl ?? ctx.model.baseUrl).replace(/\/$/, "");
			const response = await fetch(`${baseUrl}/wham/usage`, {
				headers: {
					accept: "application/json",
					Authorization: `Bearer ${token}`,
					"chatgpt-account-id": accountId,
					originator: "pi",
				},
				signal: AbortSignal.timeout(10_000),
			});
			if (!response.ok) return;
			updateWeeklyUsedPercent(parseWeeklyUsedPercentFromUsage(await response.json()));
		} catch {
			// Quota is optional UI data; keep the footer usable when it is unavailable.
		}
	}

	function applyFooter(ctx: ExtensionContext) {
		if (!enabled) {
			ctx.ui.setFooter(undefined);
			return;
		}

		ctx.ui.setFooter((tui, theme, footerData) => {
			const renderFooter = () => tui.requestRender();
			let openPullRequest: OpenPullRequest | undefined;
			let pullRequestLookup = 0;

			const updatePullRequest = () => {
				const branch = footerData.getGitBranch();
				const lookup = ++pullRequestLookup;
				openPullRequest = undefined;
				renderFooter();
				if (!branch) return;
				void findOpenPullRequest(pi, ctx.cwd, branch).then((pullRequest) => {
					if (lookup !== pullRequestLookup) return;
					openPullRequest = pullRequest;
					renderFooter();
				});
			};

			const unsubscribe = footerData.onBranchChange(updatePullRequest);
			requestFooterRender = renderFooter;
			refreshPullRequest = updatePullRequest;
			updatePullRequest();

			return {
				dispose() {
					unsubscribe();
					pullRequestLookup++;
					if (requestFooterRender === renderFooter) requestFooterRender = undefined;
					if (refreshPullRequest === updatePullRequest) refreshPullRequest = undefined;
				},
				invalidate() {},
				render(width: number): string[] {
					const statuses = [...footerData.getExtensionStatuses().values()].join(theme.fg("dim", " · "));
					const model = ctx.model?.id ?? "no-model";
					const thinking = ctx.thinkingLevel === "off" ? "" : ` ${theme.fg("accent", `⚡ ${ctx.thinkingLevel}`)}`;
					const modelText = `${theme.fg("accent", `🧠 ${model}`)}${thinking}`;

					const usage = ctx.getContextUsage();
					const percent = usage?.percent == null ? undefined : Math.max(0, Math.min(100, usage.percent));
					const filled = percent == null ? 0 : Math.round((percent / 100) * BAR_WIDTH);
					const barColor = percent == null ? "dim" : percent >= 85 ? "error" : percent >= 65 ? "warning" : "success";
					const bar = theme.fg(barColor, "█".repeat(filled)) + theme.fg("dim", "░".repeat(BAR_WIDTH - filled));
					const context = percent == null ? `🧩 ${bar} ?` : `🧩 ${bar} ${Math.round(percent)}%`;

					let weekly = "";
					if (ctx.model?.provider === "openai-codex" && weeklyUsedPercent != null) {
						const weeklyRemaining = 100 - weeklyUsedPercent;
						const weeklyFilled = Math.round((weeklyRemaining / 100) * BAR_WIDTH);
						const weeklyColor = weeklyRemaining <= 15 ? "error" : weeklyRemaining <= 35 ? "warning" : "success";
						const weeklyBar = theme.fg(weeklyColor, "█".repeat(weeklyFilled)) + theme.fg("dim", "░".repeat(BAR_WIDTH - weeklyFilled));
						weekly = `📅 week ${weeklyBar} ${Math.round(weeklyRemaining)}% left`;
					}
					const usageText = [context, weekly]
						.filter(Boolean)
						.map((part) => theme.fg("dim", part))
						.join("  ");

					const branch = footerData.getGitBranch();
					const pullRequest = openPullRequest
						? `  ${hyperlink(`🔀 #${openPullRequest.number}`, openPullRequest.url)}`
						: "";
					const branchText = branch ? theme.fg("dim", `🌿 ${branch}${pullRequest}`) : "";

					const left = [statuses, branchText].filter(Boolean).join("  ");
					const right = [usageText, modelText].filter(Boolean).join("  ");
					return [alignFooterSides(left, right, width)];
				},
			};
		});
	}

	pi.on("session_start", (_event, ctx) => {
		applyFooter(ctx);
		void refreshWeeklyUsedPercent(ctx);
	});

	pi.on("after_provider_response", (event) => {
		updateWeeklyUsedPercent(parseWeeklyUsedPercent(event.headers));
	});

	pi.on("model_select", (_event, ctx) => {
		void refreshWeeklyUsedPercent(ctx);
	});

	pi.on("agent_settled", () => refreshPullRequest?.());

	pi.registerCommand("footer", {
		description: "Toggle the compact custom footer",
		handler: async (_args, ctx) => {
			enabled = !enabled;
			applyFooter(ctx);
			ctx.ui.notify(enabled ? "Custom footer enabled" : "Default footer restored", "info");
		},
	});
}
