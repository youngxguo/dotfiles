import assert from "node:assert/strict";
import test from "node:test";

import autoSessionTitle, {
	herdrRepoToken,
	herdrTitleRows,
	titleFromPrompt,
} from "./auto-session-title.ts";

function extensionHarness(entries = [], execImplementation) {
	const handlers = new Map();
	const terminalTitles = [];
	const execCalls = [];
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
		async exec(command, args) {
			execCalls.push({ command, args });
			if (execImplementation) return execImplementation(command, args);
			if (args[0] === "agent" && args[1] === "list") {
				return {
					stdout: '{"result":{"agents":[]}}',
					stderr: "",
					code: 0,
					killed: false,
				};
			}
			return { stdout: "", stderr: "", code: 1, killed: false };
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
	return { ctx, execCalls, handlers, pi, terminalTitles };
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

test("wraps Herdr titles into the shared three-row layout", () => {
	assert.deepEqual(herdrTitleRows("Fix blank agents menu in herdr", 12), [
		"Fix blank",
		"agents menu",
		"in herdr",
	]);
	assert.deepEqual(
		herdrTitleRows("one two three four five six seven eight", 10),
		["one two", "three four", "five six…"],
	);
});

test("assigns repositories stable palette colors", () => {
	assert.equal(herdrRepoToken("frontend"), herdrRepoToken("frontend"));
	assert.notEqual(herdrRepoToken("frontend"), herdrRepoToken("backend"));
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
		content: [{ type: "text", text: "Pi and Herdr auto titles" }],
	});
	harness.handlers.get("before_agent_start")(
		{ prompt: "auto session title is not working for pi" },
		harness.ctx,
	);
	harness.handlers.get("agent_settled")({}, harness.ctx);
	await new Promise((resolve) => setImmediate(resolve));

	assert.equal(harness.pi.getSessionName(), "Pi and Herdr auto titles");
	assert.ok(harness.terminalTitles.includes("Pi and Herdr auto titles"));
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

test("clears its terminal and Herdr titles on /new", async () => {
	const originalEnvironment = {
		HERDR_BIN_PATH: process.env.HERDR_BIN_PATH,
		HERDR_ENV: process.env.HERDR_ENV,
		HERDR_PANE_ID: process.env.HERDR_PANE_ID,
	};
	process.env.HERDR_BIN_PATH = "herdr-test";
	process.env.HERDR_ENV = "1";
	process.env.HERDR_PANE_ID = "w1:p2";

	try {
		const harness = extensionHarness();
		await harness.handlers.get("session_shutdown")(
			{ reason: "new" },
			harness.ctx,
		);

		assert.deepEqual(harness.terminalTitles, [""]);
		const reports = harness.execCalls.filter(
			(call) => call.command === "herdr-test" && call.args[0] === "pane",
		);
		assert.equal(reports.length, 3);
		for (const report of reports) {
			const updates = report.args.filter(
				(arg) => arg === "--token" || arg === "--clear-token",
			);
			assert.ok(updates.length <= 16);
		}
		const reportArgs = reports.flatMap((report) => report.args);
		for (const token of [
			"title1",
			"title2",
			"title3",
			"repo",
			"repo_color_1",
			"repo_color_2",
			"repo_color_3",
			"repo_color_4",
			"repo_color_5",
			"repo_color_6",
			"branch",
			"model",
			"subscription",
			"model_fable",
			"model_opus",
			"model_sonnet",
			"model_haiku",
			"model_sol",
			"model_terra",
			"model_luna",
			"model_other",
			"subscription_codex",
			"subscription_c1",
			"subscription_c2",
			"subscription_c3",
			"subscription_c4",
			"subscription_c5",
			"subscription_c6",
			"pr_open",
			"pr_draft",
			"pr_merged",
			"pr_closed",
		]) {
			const tokenIndex = reportArgs.indexOf(token);
			assert.ok(tokenIndex > 0, `missing clear for ${token}`);
			assert.equal(reportArgs[tokenIndex - 1], "--clear-token");
		}
		for (const report of reports) {
			const seq = report.args[report.args.indexOf("--seq") + 1];
			assert.ok(BigInt(seq) > BigInt(Number.MAX_SAFE_INTEGER));
		}
		assert.equal(
			harness.execCalls.some((call) => call.command === "git" || call.command === "gh"),
			false,
		);
	} finally {
		for (const [name, value] of Object.entries(originalEnvironment)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
	}
});

test("publishes runtime details with the shared sidebar tokens", async () => {
	const originalEnvironment = {
		HERDR_BIN_PATH: process.env.HERDR_BIN_PATH,
		HERDR_ENV: process.env.HERDR_ENV,
		HERDR_PANE_ID: process.env.HERDR_PANE_ID,
		HERDR_SOCKET_PATH: process.env.HERDR_SOCKET_PATH,
	};
	process.env.HERDR_BIN_PATH = "herdr-test";
	process.env.HERDR_ENV = "1";
	process.env.HERDR_PANE_ID = "w1:p2";
	delete process.env.HERDR_SOCKET_PATH;

	try {
		const harness = extensionHarness([], async (command, args) => {
			if (command === "herdr-test" && args[0] === "agent") {
				return {
					stdout:
						'{"result":{"agents":[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}',
					stderr: "",
					code: 0,
					killed: false,
				};
			}
			if (command === "git") {
				return {
					stdout: "/repo\nmain\n/repo/.git\n/repo/.git\n",
					stderr: "",
					code: 0,
					killed: false,
				};
			}
			if (command === "gh") {
				return {
					stdout: '[{"number":42,"state":"OPEN","isDraft":false}]',
					stderr: "",
					code: 0,
					killed: false,
				};
			}
			return { stdout: "", stderr: "", code: 0, killed: false };
		});
		harness.ctx.model = { id: "gpt-5.6-sol", provider: "openai-codex" };

		harness.handlers.get("session_start")({ reason: "startup" }, harness.ctx);
		await new Promise((resolve) => setImmediate(resolve));
		const emptySessionReport = harness.execCalls.find(
			(call) => call.command === "herdr-test" && call.args[0] === "pane",
		);
		assert.ok(emptySessionReport);
		assert.ok(emptySessionReport.args.includes("title1"));

		harness.execCalls.length = 0;
		harness.handlers.get("before_agent_start")(
			{ prompt: "Fix blank agents menu in herdr" },
			harness.ctx,
		);
		await new Promise((resolve) => setImmediate(resolve));

		const reports = harness.execCalls.filter(
			(call) => call.command === "herdr-test" && call.args[0] === "pane",
		);
		assert.equal(reports.length, 3);
		const bySource = (source) =>
			reports.find(
				(call) => call.args[call.args.indexOf("--source") + 1] === source,
			);
		const report = bySource("pi-auto-session-title");
		const modelReport = bySource("pi-auto-session-title-model");
		const subscriptionReport = bySource("pi-auto-session-title-subscription");
		assert.ok(report);
		assert.ok(modelReport);
		assert.ok(subscriptionReport);
		assert.ok(report.args.includes("title1=Fix blank agents menu in"));
		assert.ok(report.args.includes("title2=herdr"));
		assert.ok(report.args.includes("repo_color_4=📁 repo"));
		assert.equal(report.args[report.args.indexOf("repo") - 1], "--clear-token");
		assert.ok(report.args.includes("branch= main"));
		assert.ok(modelReport.args.includes("model_sol=gpt-5.6-sol"));
		assert.ok(subscriptionReport.args.includes("subscription_codex=codex"));
		assert.ok(report.args.includes("pr_open= #42"));

		harness.execCalls.length = 0;
		const selectedModel = { id: "gpt-5.6-terra", provider: "openai-codex" };
		harness.handlers.get("model_select")(
			{ model: selectedModel, previousModel: harness.ctx.model, source: "set" },
			harness.ctx,
		);
		await new Promise((resolve) => setImmediate(resolve));

		const changedReports = harness.execCalls.filter(
			(call) => call.command === "herdr-test" && call.args[0] === "pane",
		);
		const changedModelReport = changedReports.find(
			(call) =>
				call.args[call.args.indexOf("--source") + 1] ===
				"pi-auto-session-title-model",
		);
		const changedSubscriptionReport = changedReports.find(
			(call) =>
				call.args[call.args.indexOf("--source") + 1] ===
				"pi-auto-session-title-subscription",
		);
		assert.ok(changedModelReport);
		assert.ok(changedSubscriptionReport);
		assert.ok(changedModelReport.args.includes("model_terra=gpt-5.6-terra"));
		assert.ok(
			changedSubscriptionReport.args.includes("subscription_codex=codex"),
		);
		const oldModelIndex = changedModelReport.args.indexOf("model_sol");
		assert.ok(oldModelIndex > 0);
		assert.equal(changedModelReport.args[oldModelIndex - 1], "--clear-token");
	} finally {
		for (const [name, value] of Object.entries(originalEnvironment)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
	}
});
