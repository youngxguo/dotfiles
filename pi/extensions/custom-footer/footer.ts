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

export class CompactFooter {
	private gitStatus: GitStatus | undefined;
	private gitStatusDirty = false;
	private gitStatusLookup = 0;
	private openPullRequest: OpenPullRequest | undefined;
	private pullRequestLookup = 0;
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
			this.refreshGitStatus();
			this.refreshPullRequest();
		});
		this.refreshGitStatus();
		this.refreshPullRequest();
	}

	dispose(): void {
		this.unsubscribe();
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
		this.openPullRequest = undefined;
		this.tui.requestRender();
		if (!branch) return;

		void findOpenPullRequest(this.pi, this.ctx.cwd).then((pullRequest) => {
			if (lookup !== this.pullRequestLookup) return;
			this.openPullRequest = pullRequest;
			this.tui.requestRender();
		});
	}

	render(width: number): string[] {
		const statuses = [...this.data.getExtensionStatuses().values()].join(
			this.theme.fg("dim", " · "),
		);
		const branch = this.data.getGitBranch();
		const pullRequest = this.openPullRequest
			? hyperlink(`🔀 #${this.openPullRequest.number}`, this.openPullRequest.url)
			: "";
		const branchText = branch
			? [
					this.theme.fg("accent", ` ${branch}`),
					renderGitStatus(this.gitStatus, this.theme),
					pullRequest,
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
