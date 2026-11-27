import assert from "node:assert/strict";
import test from "node:test";

import autoSessionTitle, { titleFromPrompt } from "./auto-session-title.ts";

function extensionHarness(entries = []) {
	const handlers = new Map();
	const terminalTitles = [];
	let sessionName = entries.findLast((entry) => entry.type === "session_info")?.name;
	const pi = {
		on(event, handler) {
			handlers.set(event, handler);
		},
		getSessionName() {
			return sessionName;
		},
		setSessionName(name) {
			sessionName = name;
			entries.push({ type: "session_info", name });
		},
	};
	const ctx = {
		mode: "tui",
		model: { id: "test", provider: "test" },
		modelRegistry: {},
		sessionManager: { getEntries: () => entries },
		ui: { setTitle: (title) => terminalTitles.push(title) },
	};
	autoSessionTitle(pi);
	return { ctx, handlers, pi, terminalTitles };
}

test("uses a short opening request as the fallback title", () => {
	assert.equal(
		titleFromPrompt("auto session title is not working for pi"),
		"auto session title is not working for pi",
	);
});

test("removes conversational and markdown noise", () => {
	assert.equal(
		titleFromPrompt("Hey, could you please fix [the title](https://example.com)?"),
		"fix the title",
	);
	assert.equal(titleFromPrompt("  # Fix\n\tthe\u001b title.  "), "Fix the title");
});

test("truncates at a word boundary", () => {
	const title = titleFromPrompt(
		"please make this deliberately long session title stop at a sensible word boundary instead of splitting the final word",
	);
	assert.equal(title, "make this deliberately long session title stop at a…");
	assert.ok([...title].length <= 60);
});

test("does not name an empty text-only prompt", () => {
	assert.equal(titleFromPrompt(" \n\t "), undefined);
});

test("names a new session and its terminal from the opening request", () => {
	const harness = extensionHarness();
	harness.handlers.get("before_agent_start")(
		{ prompt: "Could you fix the auto title?" },
		harness.ctx,
	);

	assert.equal(harness.pi.getSessionName(), "fix the auto title");
	assert.deepEqual(harness.terminalTitles, ["fix the auto title"]);
});

test("refines the fallback with a model-generated title", async () => {
	const harness = extensionHarness();
	harness.ctx.modelRegistry.complete = async () => ({
		content: [{ type: "text", text: "Pi auto session titles" }],
	});
	harness.handlers.get("before_agent_start")(
		{ prompt: "auto session title is not working for pi" },
		harness.ctx,
	);
	harness.handlers.get("agent_settled")({}, harness.ctx);
	await new Promise((resolve) => setImmediate(resolve));

	assert.equal(harness.pi.getSessionName(), "Pi auto session titles");
	assert.ok(harness.terminalTitles.includes("Pi auto session titles"));
});

test("does not replace a manual name", () => {
	const entries = [{ type: "session_info", name: "keep me" }];
	const harness = extensionHarness(entries);
	harness.handlers.get("before_agent_start")(
		{ prompt: "replace the existing title" },
		harness.ctx,
	);

	assert.equal(harness.pi.getSessionName(), "keep me");
	assert.deepEqual(harness.terminalTitles, []);
});

test("clears its terminal title on /new", () => {
	const harness = extensionHarness();
	harness.handlers.get("session_shutdown")({ reason: "new" }, harness.ctx);

	assert.deepEqual(harness.terminalTitles, [""]);
});
