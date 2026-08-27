import type {
	ExtensionAPI,
	ExtensionContext,
	ReadonlyFooterDataProvider,
	Theme,
} from "@earendil-works/pi-coding-agent";
import type { TUI } from "@earendil-works/pi-tui";
import { hyperlink } from "@earendil-works/pi-tui";

import { findGitStatus, type GitStatus } from "./repository.js";
import { findOpenPullRequest, type OpenPullRequest } from "./github.js";
import { renderGitStatus } from "./render/git.js";
import { alignSides } from "./render/layout.js";
import { renderContextUsage, renderWeeklyUsage } from "./render/usage.js";

const PULL_REQUEST_POLL_INTERVAL_MS = 30_000;

function renderPullRequestChecks(pullRequest: OpenPullRequest, theme: Theme): string {
	let text: string;
	switch (pullRequest.checksStatus) {
		case "success":
			text = theme.fg("success", "✓ CI");
			break;
		case "failure":
			text = theme.fg("error", "✗ CI");
			break;
		case "pending":
			text = theme.fg("warning", "● CI");
			break;
		case "none":
			text = theme.fg("muted", "○ CI");
			break;
	}
	return hyperlink(text, `${pullRequest.url}/checks`);
}

export class CompactFooter {
	private gitStatus: GitStatus | undefined;
	private gitStatusDirty = false;
	private gitStatusLookup = 0;
	private openPullRequest: OpenPullRequest | undefined;
	private pullRequestLookup = 0;
	private readonly pullRequestPoll: ReturnType<typeof setInterval>;
	private readonly unsubscribe: () => void;

	constructor(
		private readonly pi: ExtensionAPI,
		private readonly ctx: ExtensionContext,
		private readonly tui: TUI,
		private readonly theme: Theme,
		private readonly data: ReadonlyFooterDataProvider,
		private weeklyUsedPercent: number | undefined,
	) {
		this.unsubscribe = data.onBranchChange(() => {
			this.gitStatus = undefined;
			this.gitStatusDirty = false;
			this.openPullRequest = undefined;
			this.tui.requestRender();
			this.refreshGitStatus();
			this.refreshPullRequest();
		});
		this.refreshGitStatus();
		this.refreshPullRequest();
		this.pullRequestPoll = setInterval(
			() => this.refreshPullRequest(),
			PULL_REQUEST_POLL_INTERVAL_MS,
		);
		this.pullRequestPoll.unref();
	}

	dispose(): void {
		this.unsubscribe();
		clearInterval(this.pullRequestPoll);
		this.gitStatusLookup++;
		this.pullRequestLookup++;
	}

	invalidate(): void {}

	setWeeklyUsedPercent(value: number | undefined): void {
		this.weeklyUsedPercent = value;
		this.tui.requestRender();
	}

	markRepositoryDirty(): void {
		this.gitStatusDirty = true;
	}

	refreshDirtyRepository(): void {
		if (!this.gitStatusDirty) return;
		this.gitStatusDirty = false;
		this.refreshGitStatus();
		this.refreshPullRequest();
	}

	private refreshGitStatus(): void {
		const lookup = ++this.gitStatusLookup;
		if (!this.data.getGitBranch()) {
			this.gitStatus = undefined;
			this.tui.requestRender();
			return;
		}

		void findGitStatus(this.pi, this.ctx.cwd).then((status) => {
			if (lookup !== this.gitStatusLookup) return;
			this.gitStatus = status;
			this.tui.requestRender();
		});
	}

	private refreshPullRequest(): void {
		const branch = this.data.getGitBranch();
		const lookup = ++this.pullRequestLookup;
		if (!branch) {
			this.openPullRequest = undefined;
			this.tui.requestRender();
			return;
		}

		void findOpenPullRequest(this.pi, this.ctx.cwd).then((pullRequest) => {
			if (lookup !== this.pullRequestLookup || pullRequest === undefined) return;
			this.openPullRequest = pullRequest ?? undefined;
			this.tui.requestRender();
		});
	}

	render(width: number): string[] {
		const statuses = [...this.data.getExtensionStatuses()]
			.flatMap(([id, status]) => (id.startsWith("pi-lens") ? [] : [status]))
			.join(this.theme.fg("dim", " · "));
		const branch = this.data.getGitBranch();
		const pullRequest = this.openPullRequest
			? hyperlink(`🔀 #${this.openPullRequest.number}`, this.openPullRequest.url)
			: "";
		const checks = this.openPullRequest
			? renderPullRequestChecks(this.openPullRequest, this.theme)
			: "";
		const branchText = branch
			? [
					this.theme.fg("accent", ` ${branch}`),
					renderGitStatus(this.gitStatus, this.theme),
					pullRequest,
					checks,
				].filter(Boolean).join("  ")
			: "";

		const thinking =
			this.ctx.thinkingLevel === "off"
				? ""
				: ` ${this.theme.fg("accent", `⚡ ${this.ctx.thinkingLevel}`)}`;
		const model = `${this.theme.fg("accent", `🧠 ${this.ctx.model?.id ?? "no-model"}`)}${thinking}`;

		const weeklyUsage =
			this.ctx.model?.provider === "openai-codex"
				? renderWeeklyUsage(this.weeklyUsedPercent, this.theme)
				: "";
		const usage = [renderContextUsage(this.ctx, this.theme), weeklyUsage]
			.filter(Boolean)
			.join("  ");
		const left = [statuses, branchText].filter(Boolean).join("  ");
		const right = [usage, model].join("  ");
		return [alignSides(left, right, width)];
	}
}
