import type {
	ExtensionAPI,
	ExtensionContext,
	ReadonlyFooterDataProvider,
	Theme,
} from "@earendil-works/pi-coding-agent";
import type { TUI } from "@earendil-works/pi-tui";
import { hyperlink } from "@earendil-works/pi-tui";

import { findOpenPullRequest, type OpenPullRequest } from "./github.js";
import { alignSides, renderContextUsage } from "./render.js";

export class CompactFooter {
	private openPullRequest: OpenPullRequest | undefined;
	private pullRequestLookup = 0;
	private readonly unsubscribe: () => void;

	constructor(
		private readonly pi: ExtensionAPI,
		private readonly ctx: ExtensionContext,
		private readonly tui: TUI,
		private readonly theme: Theme,
		private readonly data: ReadonlyFooterDataProvider,
	) {
		this.unsubscribe = data.onBranchChange(() => this.refreshPullRequest());
		this.refreshPullRequest();
	}

	dispose(): void {
		this.unsubscribe();
		this.pullRequestLookup++;
	}

	invalidate(): void {}

	refreshPullRequest(): void {
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
			? `  ${hyperlink(`🔀 #${this.openPullRequest.number}`, this.openPullRequest.url)}`
			: "";
		const branchText = branch ? this.theme.fg("dim", `🌿 ${branch}${pullRequest}`) : "";

		const thinking =
			this.ctx.thinkingLevel === "off"
				? ""
				: ` ${this.theme.fg("accent", `⚡ ${this.ctx.thinkingLevel}`)}`;
		const model = `${this.theme.fg("accent", `🧠 ${this.ctx.model?.id ?? "no-model"}`)}${thinking}`;

		const left = [statuses, branchText].filter(Boolean).join("  ");
		const right = [renderContextUsage(this.ctx, this.theme), model].join("  ");
		return [alignSides(left, right, width)];
	}
}
