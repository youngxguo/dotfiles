import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type PullRequestChecksStatus = "none" | "pending" | "success" | "failure";

export type OpenPullRequest = {
	number: number;
	url: string;
	checksStatus: PullRequestChecksStatus;
};

const FAILED_CHECK_STATES = new Set([
	"ACTION_REQUIRED",
	"CANCELLED",
	"ERROR",
	"FAILURE",
	"STALE",
	"STARTUP_FAILURE",
	"TIMED_OUT",
]);
const SUCCESSFUL_CHECK_STATES = new Set(["NEUTRAL", "SKIPPED", "SUCCESS"]);

export function summarizePullRequestChecks(checks: unknown): PullRequestChecksStatus {
	if (!Array.isArray(checks) || checks.length === 0) return "none";

	let hasPending = false;
	for (const value of checks) {
		if (typeof value !== "object" || value == null) {
			hasPending = true;
			continue;
		}

		const check = value as Record<string, unknown>;
		const status = typeof check.status === "string" ? check.status.toUpperCase() : undefined;
		const conclusion =
			typeof check.conclusion === "string" ? check.conclusion.toUpperCase() : undefined;
		const state = typeof check.state === "string" ? check.state.toUpperCase() : undefined;
		const result = conclusion || state;

		if (result && FAILED_CHECK_STATES.has(result)) return "failure";
		if (status && status !== "COMPLETED") hasPending = true;
		else if (!result || !SUCCESSFUL_CHECK_STATES.has(result)) hasPending = true;
	}

	return hasPending ? "pending" : "success";
}

/** Returns undefined on lookup failure and null when a resolved pull request is not open. */
export async function findOpenPullRequest(
	pi: ExtensionAPI,
	cwd: string,
): Promise<OpenPullRequest | null | undefined> {
	try {
		const result = await pi.exec(
			"gh",
			["pr", "view", "--json", "number,url,state,statusCheckRollup"],
			{
				cwd,
				timeout: 5_000,
			},
		);
		if (result.code !== 0) return undefined;

		const pullRequest: unknown = JSON.parse(result.stdout);
		if (typeof pullRequest !== "object" || pullRequest == null) return undefined;
		const { number, url, state, statusCheckRollup } = pullRequest as Record<string, unknown>;
		if (typeof number !== "number" || typeof url !== "string" || typeof state !== "string") {
			return undefined;
		}
		if (state !== "OPEN") return null;
		return { number, url, checksStatus: summarizePullRequestChecks(statusCheckRollup) };
	} catch {
		return undefined;
	}
}
