import { readFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { uuidv7 } from "@earendil-works/pi-ai";
import type {
	ExtensionAPI,
	ExtensionContext,
	SessionEntry,
} from "@earendil-works/pi-coding-agent";

const MAX_TITLE_LENGTH = 60;
const TITLE_PROMPT_LIMIT = 4_000;
const TITLE_TIMEOUT_MS = 15_000;
const TITLE_SYSTEM_PROMPT = `Name a coding-agent session from the user's opening request.

Return only the title. Use 3-7 words and at most 50 characters. Preserve meaningful identifiers and capitalization. Do not use quotes, markdown, a trailing full stop, or filler such as "Help with".`;
const HERDR_METADATA_SOURCE = "pi-auto-session-title";
const HERDR_MODEL_SOURCE = "pi-auto-session-title-model";
const HERDR_SUBSCRIPTION_SOURCE = "pi-auto-session-title-subscription";
const HERDR_TITLE_FALLBACK_WIDTH = 26;
const HERDR_TITLE_ROWS = 3;
const HERDR_REPO_TOKENS = [
	"repo_color_1",
	"repo_color_2",
	"repo_color_3",
	"repo_color_4",
	"repo_color_5",
	"repo_color_6",
] as const;
const HERDR_MODEL_TOKENS = [
	"model_fable",
	"model_opus",
	"model_sonnet",
	"model_haiku",
	"model_sol",
	"model_terra",
	"model_luna",
	"model_other",
] as const;
const HERDR_SUBSCRIPTION_TOKENS = [
	"subscription_codex",
	"subscription_c1",
	"subscription_c2",
	"subscription_c3",
	"subscription_c4",
	"subscription_c5",
	"subscription_c6",
] as const;
const HERDR_MAIN_TOKENS = [
	"title1",
	"title2",
	"title3",
	"repo",
	...HERDR_REPO_TOKENS,
	"branch",
	"pr_open",
	"pr_draft",
	"pr_merged",
	"pr_closed",
] as const;
const HERDR_MODEL_METADATA_TOKENS = ["model", ...HERDR_MODEL_TOKENS] as const;
const HERDR_SUBSCRIPTION_METADATA_TOKENS = [
	"subscription",
	...HERDR_SUBSCRIPTION_TOKENS,
] as const;

export function herdrRepoToken(
	repoName: string,
): (typeof HERDR_REPO_TOKENS)[number] {
	// FNV-1a gives every repository a stable palette slot without putting
	// work-specific repository names in these portable dotfiles.
	let hash = 2_166_136_261;
	for (const byte of new TextEncoder().encode(repoName)) {
		hash = Math.imul(hash ^ byte, 16_777_619) >>> 0;
	}
	return HERDR_REPO_TOKENS[hash % HERDR_REPO_TOKENS.length];
}

function herdrModelToken(modelId: string): (typeof HERDR_MODEL_TOKENS)[number] {
	const normalized = modelId.toLowerCase();
	const words = normalized.split(/[^a-z0-9]+/);
	if (words.includes("fable")) return "model_fable";
	if (words.includes("opus")) return "model_opus";
	if (words.includes("sonnet")) return "model_sonnet";
	if (words.includes("haiku")) return "model_haiku";
	if (words.includes("sol")) return "model_sol";
	if (words.includes("terra")) return "model_terra";
	if (words.includes("luna")) return "model_luna";
	return "model_other";
}

function truncateTitle(title: string): string {
	const characters = [...title];
	if (characters.length <= MAX_TITLE_LENGTH) return title;

	const clipped = characters.slice(0, MAX_TITLE_LENGTH - 1).join("");
	const wordBoundary = clipped.replace(/\s+\S*$/, "").trimEnd();
	return `${wordBoundary || clipped}…`;
}

export function titleFromPrompt(prompt: string): string | undefined {
	const title = prompt
		.slice(0, TITLE_PROMPT_LIMIT)
		.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ")
		.replace(/!\[([^\]]*)\]\([^)]*\)/g, "$1")
		.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
		.replace(/\s+/g, " ")
		.trim()
		.replace(/^(?:#{1,6}|>|[-*+] |\d+[.)] )\s*/, "")
		.replace(/^(?:(?:hey|hi)[,!]?\s+)?(?:please\s+|(?:can|could|would|will)\s+you\s+(?:please\s+)?|i\s+(?:need|want)\s+(?:you\s+to\s+)?)/i, "")
		.replace(/[.!?,:;\s]+$/, "")
		.trim();

	return title ? truncateTitle(title) : undefined;
}

export function herdrTitleRows(title: string, width: number): string[] {
	const limit = Math.max(10, width);
	let remaining = title.replace(/\s+/g, " ").trim();
	const rows: string[] = [];

	while (remaining && rows.length < HERDR_TITLE_ROWS) {
		const characters = [...remaining];
		if (characters.length <= limit) {
			rows.push(remaining);
			break;
		}

		const clipped = characters.slice(0, limit).join("");
		const boundary = clipped.lastIndexOf(" ");
		const take = /^\s$/.test(characters[limit] ?? "")
			? limit
			: boundary > 0
				? boundary
				: limit;
		let row = characters.slice(0, take).join("").trimEnd();
		remaining = characters.slice(take).join("").trimStart();

		if (rows.length === HERDR_TITLE_ROWS - 1 && remaining) {
			row = `${[...row].slice(0, limit - 1).join("").trimEnd()}…`;
			remaining = "";
		}
		rows.push(row);
	}

	return rows;
}

function herdrSidebarTitleWidth(): number {
	const socketPath = process.env.HERDR_SOCKET_PATH;
	if (!socketPath) return HERDR_TITLE_FALLBACK_WIDTH;
	try {
		const session = JSON.parse(
			readFileSync(join(dirname(socketPath), "session.json"), "utf8"),
		) as { sidebar_width?: unknown };
		if (typeof session.sidebar_width === "number") {
			return Math.max(10, session.sidebar_width - 4);
		}
	} catch {}
	return HERDR_TITLE_FALLBACK_WIDTH;
}

function titleFromResponse(response: string): string | undefined {
	const firstLine = response
		.split("\n")
		.map((line) => line.trim())
		.find(Boolean);
	if (!firstLine) return undefined;

	return titleFromPrompt(
		firstLine
			.replace(/^title\s*:\s*/i, "")
			.replace(/^[`"'*_]+|[`"'*_]+$/g, ""),
	);
}

function userPrompt(entries: readonly SessionEntry[]): string | undefined {
	for (const entry of entries) {
		if (entry.type !== "message" || entry.message.role !== "user") continue;
		const content = entry.message.content;
		return typeof content === "string"
			? content
			: content
					.filter((part) => part.type === "text")
					.map((part) => part.text)
					.join(" ");
	}
	return undefined;
}

function hasNameDecision(entries: readonly SessionEntry[]): boolean {
	return entries.some((entry) => entry.type === "session_info");
}

export default function (pi: ExtensionAPI) {
	let openingPrompt: string | undefined;
	let automaticTitle: string | undefined;
	let titleAttempted = false;
	let titleRequest: AbortController | undefined;
	let terminalTitleRefresh: ReturnType<typeof setTimeout> | undefined;
	let generation = 0;
	// Herdr accepts u64 sequences. Epoch nanoseconds represented as a bigint stay
	// monotonic across extension reloads without losing precision in JavaScript.
	let herdrMetadataSeq = BigInt(Date.now()) * 1_000_000n;

	async function reportHerdrMetadata(
		title: string | undefined,
		ctx: ExtensionContext,
		model: ExtensionContext["model"] = ctx.model,
	): Promise<void> {
		const paneId = process.env.HERDR_PANE_ID;
		if (process.env.HERDR_ENV !== "1" || !paneId || ctx.mode !== "tui") return;

		const herdr = process.env.HERDR_BIN_PATH || "herdr";
		const sequence = String(++herdrMetadataSeq);
		const metadataArgs = (source: string) => [
			"pane",
			"report-metadata",
			paneId,
			"--source",
			source,
			"--seq",
			sequence,
		];
		const args = metadataArgs(HERDR_METADATA_SOURCE);
		const rows = title ? herdrTitleRows(title, herdrSidebarTitleWidth()) : [];
		for (let index = 0; index < HERDR_TITLE_ROWS; index++) {
			const row = rows[index];
			args.push(row ? "--token" : "--clear-token", row ? `title${index + 1}=${row}` : `title${index + 1}`);
		}

		let branch: string | undefined;
		let hasGitMetadata = false;
		try {
			const git = await pi.exec("git", [
				"-C",
				ctx.cwd,
				"rev-parse",
				"--show-toplevel",
				"--abbrev-ref",
				"HEAD",
				"--git-dir",
				"--git-common-dir",
			]);
			if (git.code === 0) {
				const [repoRoot, reportedBranch, gitDir, gitCommonDir] = git.stdout
					.trim()
					.split("\n");
				branch = reportedBranch;
				if (branch === "HEAD") {
					const head = await pi.exec("git", [
						"-C",
						ctx.cwd,
						"rev-parse",
						"--short",
						"HEAD",
					]);
					branch = head.code === 0 ? head.stdout.trim() : undefined;
				}
				if (repoRoot && branch && gitDir && gitCommonDir) {
					const resolvedGitDir = resolve(ctx.cwd, gitDir);
					const resolvedCommonDir = resolve(ctx.cwd, gitCommonDir);
					const repoName =
						resolvedGitDir === resolvedCommonDir
							? basename(repoRoot)
							: basename(dirname(resolvedCommonDir));
					const selectedRepoToken = herdrRepoToken(repoName);
					args.push("--clear-token", "repo");
					for (const token of HERDR_REPO_TOKENS) {
						args.push(
							token === selectedRepoToken ? "--token" : "--clear-token",
							token === selectedRepoToken ? `${token}=📁 ${repoName}` : token,
						);
					}
					args.push("--token", `branch= ${branch}`);
					hasGitMetadata = true;
				}
			}
		} catch {}
		if (!hasGitMetadata) {
			for (const token of ["repo", ...HERDR_REPO_TOKENS]) {
				args.push("--clear-token", token);
			}
			args.push("--clear-token", "branch");
		}

		let pullRequestToken: { state: string; value: string } | undefined;
		if (branch) {
			try {
				const pullRequests = await pi.exec("gh", [
					"pr",
					"list",
					"--state",
					"all",
					"--head",
					branch,
					"--limit",
					"1",
					"--json",
					"number,state,isDraft",
				]);
				const pullRequest = (
					JSON.parse(pullRequests.stdout) as Array<{
						number?: number;
						state?: string;
						isDraft?: boolean;
					}>
				)[0];
				if (pullRequest?.number) {
					const state = pullRequest.isDraft
						? "draft"
						: pullRequest.state?.toLowerCase() === "open"
							? "open"
							: pullRequest.state?.toLowerCase() === "merged"
								? "merged"
								: "closed";
					const suffix = state === "open" || state === "draft" ? "" : ` ${state}`;
					pullRequestToken = {
						state,
						value: ` #${pullRequest.number}${suffix}`,
					};
				}
			} catch {}
		}
		for (const state of ["open", "draft", "merged", "closed"]) {
			if (pullRequestToken?.state === state) {
				args.push("--token", `pr_${state}=${pullRequestToken.value}`);
			} else {
				args.push("--clear-token", `pr_${state}`);
			}
		}

		const modelArgs = metadataArgs(HERDR_MODEL_SOURCE);
		modelArgs.push("--clear-token", "model");
		const selectedModelToken = model?.id ? herdrModelToken(model.id) : undefined;
		for (const token of HERDR_MODEL_TOKENS) {
			if (token === selectedModelToken && model) {
				modelArgs.push("--token", `${token}=${model.id}`);
			} else {
				modelArgs.push("--clear-token", token);
			}
		}

		const subscriptionArgs = metadataArgs(HERDR_SUBSCRIPTION_SOURCE);
		subscriptionArgs.push("--clear-token", "subscription");
		const selectedSubscriptionToken =
			model?.provider === "openai-codex" ? "subscription_codex" : undefined;
		for (const token of HERDR_SUBSCRIPTION_TOKENS) {
			if (token === selectedSubscriptionToken) {
				subscriptionArgs.push("--token", `${token}=codex`);
			} else {
				subscriptionArgs.push("--clear-token", token);
			}
		}

		try {
			await Promise.all([
				pi.exec(herdr, args),
				pi.exec(herdr, modelArgs),
				pi.exec(herdr, subscriptionArgs),
			]);
		} catch {}
	}

	async function clearHerdrMetadata(ctx: ExtensionContext): Promise<void> {
		const paneId = process.env.HERDR_PANE_ID;
		if (process.env.HERDR_ENV !== "1" || !paneId || ctx.mode !== "tui") return;

		const sequence = String(++herdrMetadataSeq);
		const clearArgs = (source: string, tokens: readonly string[]) => {
			const args = [
				"pane",
				"report-metadata",
				paneId,
				"--source",
				source,
				"--seq",
				sequence,
			];
			for (const token of tokens) args.push("--clear-token", token);
			return args;
		};
		const herdr = process.env.HERDR_BIN_PATH || "herdr";
		try {
			await Promise.all([
				pi.exec(herdr, clearArgs(HERDR_METADATA_SOURCE, HERDR_MAIN_TOKENS)),
				pi.exec(herdr, clearArgs(HERDR_MODEL_SOURCE, HERDR_MODEL_METADATA_TOKENS)),
				pi.exec(
					herdr,
					clearArgs(
						HERDR_SUBSCRIPTION_SOURCE,
						HERDR_SUBSCRIPTION_METADATA_TOKENS,
					),
				),
			]);
		} catch {}
	}

	function setTerminalTitle(title: string, ctx: ExtensionContext): void {
		if (ctx.mode !== "tui") return;
		ctx.ui.setTitle(title);
		void reportHerdrMetadata(title, ctx);
		if (terminalTitleRefresh) clearTimeout(terminalTitleRefresh);
		terminalTitleRefresh = setTimeout(() => ctx.ui.setTitle(title), 0);
		terminalTitleRefresh.unref();
	}

	function setAutomaticTitle(title: string, ctx: ExtensionContext): void {
		automaticTitle = title;
		pi.setSessionName(title);
		setTerminalTitle(title, ctx);
	}

	function setFallbackTitle(prompt: string, ctx: ExtensionContext): void {
		if (hasNameDecision(ctx.sessionManager.getEntries())) return;
		const title = titleFromPrompt(prompt);
		if (!title) return;
		openingPrompt = prompt;
		setAutomaticTitle(title, ctx);
	}

	function generateTitle(ctx: ExtensionContext): void {
		if (
			!openingPrompt ||
			!automaticTitle ||
			!ctx.model ||
			titleAttempted ||
			titleRequest ||
			process.env.PI_OFFLINE
		) {
			return;
		}

		const prompt = openingPrompt.slice(0, TITLE_PROMPT_LIMIT);
		const fallback = automaticTitle;
		const request = new AbortController();
		const requestGeneration = ++generation;
		titleAttempted = true;
		titleRequest = request;

		void ctx.modelRegistry
			.complete(
				ctx.model,
				{
					systemPrompt: TITLE_SYSTEM_PROMPT,
					messages: [
						{
							role: "user",
							content: [{ type: "text", text: prompt }],
							timestamp: Date.now(),
						},
					],
				},
				{
					signal: AbortSignal.any([
						request.signal,
						AbortSignal.timeout(TITLE_TIMEOUT_MS),
					]),
					reasoningEffort: "minimal",
					maxTokens: 40,
					cacheRetention: "none",
					sessionId: uuidv7(),
				},
			)
			.then((response) => {
				if (
					requestGeneration !== generation ||
					request.signal.aborted ||
					pi.getSessionName() !== fallback
				) {
					return;
				}
				const generated = titleFromResponse(
					response.content
						.filter((part) => part.type === "text")
						.map((part) => part.text)
						.join("\n"),
				);
				if (generated && generated !== fallback) setAutomaticTitle(generated, ctx);
			})
			.catch(() => {})
			.finally(() => {
				if (requestGeneration === generation) titleRequest = undefined;
			});
	}

	pi.on("session_start", (_event, ctx) => {
		const entries = ctx.sessionManager.getEntries();
		const existingName = pi.getSessionName();
		if (existingName) {
			setTerminalTitle(existingName, ctx);
			return;
		}
		void reportHerdrMetadata(undefined, ctx);
		if (hasNameDecision(entries)) return;

		const prompt = userPrompt(entries);
		if (!prompt) return;
		setFallbackTitle(prompt, ctx);
		if (entries.some((entry) => entry.type === "message" && entry.message.role === "assistant")) {
			generateTitle(ctx);
		}
	});

	pi.on("before_agent_start", (event, ctx) => {
		setFallbackTitle(event.prompt, ctx);
	});

	pi.on("agent_settled", (_event, ctx) => {
		generateTitle(ctx);
		void reportHerdrMetadata(pi.getSessionName(), ctx);
	});

	pi.on("model_select", (event, ctx) => {
		void reportHerdrMetadata(pi.getSessionName(), ctx, event.model);
	});

	pi.on("session_info_changed", (event, ctx) => {
		if (event.name === automaticTitle) return;
		openingPrompt = undefined;
		titleRequest?.abort();
		titleRequest = undefined;
		generation++;
		if (event.name) setTerminalTitle(event.name, ctx);
	});

	pi.on("session_shutdown", async (event, ctx) => {
		titleRequest?.abort();
		titleRequest = undefined;
		if (terminalTitleRefresh) clearTimeout(terminalTitleRefresh);
		terminalTitleRefresh = undefined;
		generation++;
		if (event.reason === "new" && ctx.mode === "tui") ctx.ui.setTitle("");
		await clearHerdrMetadata(ctx);
	});
}
