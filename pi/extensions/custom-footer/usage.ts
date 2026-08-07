import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

const WEEK_MINUTES = 7 * 24 * 60;

type JsonRecord = Record<string, unknown>;

type RateLimitWindow = {
	usedPercent: number;
	windowMinutes: number;
};

function isRecord(value: unknown): value is JsonRecord {
	return typeof value === "object" && value != null && !Array.isArray(value);
}

function isWeeklyWindow(windowMinutes: number): boolean {
	return windowMinutes >= WEEK_MINUTES * 0.95 && windowMinutes <= WEEK_MINUTES * 1.05;
}

function parseRateLimitWindow(
	headers: Record<string, string>,
	name: "primary" | "secondary",
): RateLimitWindow | undefined {
	const usedPercent = Number(headers[`x-codex-${name}-used-percent`]);
	const windowMinutes = Number(headers[`x-codex-${name}-window-minutes`]);
	if (!Number.isFinite(usedPercent) || !Number.isFinite(windowMinutes)) return undefined;
	return {
		usedPercent: Math.max(0, Math.min(100, usedPercent)),
		windowMinutes,
	};
}

export function parseWeeklyUsedPercent(headers: Record<string, string>): number | undefined {
	const normalizedHeaders = Object.fromEntries(
		Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]),
	);
	return (["primary", "secondary"] as const)
		.map((name) => parseRateLimitWindow(normalizedHeaders, name))
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

export async function fetchWeeklyUsedPercent(
	ctx: ExtensionContext,
): Promise<number | undefined> {
	if (ctx.model?.provider !== "openai-codex") return undefined;
	try {
		const authResult = await ctx.modelRegistry.getProviderAuth("openai-codex");
		const token = authResult?.auth.apiKey;
		const accountId = token ? extractAccountId(token) : undefined;
		if (!token || !accountId) return undefined;

		const baseUrl = (authResult.auth.baseUrl ?? ctx.model.baseUrl)
			.replace(/\/+$/, "")
			.replace(/\/codex$/, "");
		const response = await fetch(`${baseUrl}/wham/usage`, {
			headers: {
				accept: "application/json",
				Authorization: `Bearer ${token}`,
				"chatgpt-account-id": accountId,
				originator: "pi",
			},
			signal: AbortSignal.timeout(10_000),
		});
		if (!response.ok) return undefined;
		return parseWeeklyUsedPercentFromUsage(await response.json());
	} catch {
		return undefined;
	}
}
