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
const HERDR_TITLE_FALLBACK_WIDTH = 26;
const HERDR_TITLE_ROWS = 3;
const HERDR_METADATA_TOKENS = [
	"title1",
	"title2",
	"title3",
	"repo",
	"branch",
	"pr_open",
	"pr_draft",
	"pr_merged",
	"pr_closed",
] as const;

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
	): Promise<void> {
		const paneId = process.env.HERDR_PANE_ID;
		if (process.env.HERDR_ENV !== "1" || !paneId || ctx.mode !== "tui") return;

		const herdr = process.env.HERDR_BIN_PATH || "herdr";
		const args = [
			"pane",
			"report-metadata",
			paneId,
			"--source",
			HERDR_METADATA_SOURCE,
			"--seq",
			String(++herdrMetadataSeq),
		];
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
					args.push(
						"--token",
						`repo=📁 ${repoName}`,
						"--token",
						`branch= ${branch}`,
					);
					hasGitMetadata = true;
				}
			}
		} catch {}
		if (!hasGitMetadata) {
			args.push("--clear-token", "repo", "--clear-token", "branch");
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

		try {
			await pi.exec(herdr, args);
		} catch {}
	}

	async function clearHerdrMetadata(ctx: ExtensionContext): Promise<void> {
		const paneId = process.env.HERDR_PANE_ID;
		if (process.env.HERDR_ENV !== "1" || !paneId || ctx.mode !== "tui") return;

		const args = [
			"pane",
			"report-metadata",
			paneId,
			"--source",
			HERDR_METADATA_SOURCE,
			"--seq",
			String(++herdrMetadataSeq),
		];
		for (const token of HERDR_METADATA_TOKENS) {
			args.push("--clear-token", token);
		}
		try {
			await pi.exec(process.env.HERDR_BIN_PATH || "herdr", args);
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

	pi.on("session_info_changed", (event, ctx) => {
		if (event.name === automaticTitle) return;
		openingPrompt = undefined;
		titleRequest?.abort();
		titleRequest = undefined;
		generation++;
		if (event.name) setTerminalTitle(event.name, ctx);
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		titleRequest?.abort();
		titleRequest = undefined;
		if (terminalTitleRefresh) clearTimeout(terminalTitleRefresh);
		terminalTitleRefresh = undefined;
		generation++;
		await clearHerdrMetadata(ctx);
	});
}
