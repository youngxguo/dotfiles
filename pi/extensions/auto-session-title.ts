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

	function setTerminalTitle(title: string, ctx: ExtensionContext): void {
		if (ctx.mode !== "tui") return;
		ctx.ui.setTitle(title);
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
	});

	pi.on("session_info_changed", (event, ctx) => {
		if (event.name === automaticTitle) return;
		openingPrompt = undefined;
		titleRequest?.abort();
		titleRequest = undefined;
		generation++;
		if (event.name) setTerminalTitle(event.name, ctx);
	});

	pi.on("session_shutdown", (event, ctx) => {
		titleRequest?.abort();
		titleRequest = undefined;
		if (terminalTitleRefresh) clearTimeout(terminalTitleRefresh);
		terminalTitleRefresh = undefined;
		generation++;
		if (event.reason === "new" && ctx.mode === "tui") ctx.ui.setTitle("");
	});
}
