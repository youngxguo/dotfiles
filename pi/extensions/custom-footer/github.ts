import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type OpenPullRequest = {
	number: number;
	url: string;
};

export async function findOpenPullRequest(
	pi: ExtensionAPI,
	cwd: string,
): Promise<OpenPullRequest | undefined> {
	try {
		const result = await pi.exec("gh", ["pr", "view", "--json", "number,url,state"], {
			cwd,
			timeout: 5_000,
		});
		if (result.code !== 0) return undefined;

		const pullRequest: unknown = JSON.parse(result.stdout);
		if (typeof pullRequest !== "object" || pullRequest == null) return undefined;
		const { number, url, state } = pullRequest as Record<string, unknown>;
		return typeof number === "number" && typeof url === "string" && state === "OPEN"
			? { number, url }
			: undefined;
	} catch {
		return undefined;
	}
}
