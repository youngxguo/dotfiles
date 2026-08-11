import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export type GitStatus = {
	additions: number;
	deletions: number;
	staged: number;
	modified: number;
	untracked: number;
	conflicts: number;
	ahead: number;
	behind: number;
};

function emptyStatus(): GitStatus {
	return {
		additions: 0,
		deletions: 0,
		staged: 0,
		modified: 0,
		untracked: 0,
		conflicts: 0,
		ahead: 0,
		behind: 0,
	};
}

export function parsePorcelainStatus(output: string): GitStatus {
	const status = emptyStatus();

	for (const line of output.split("\n")) {
		if (line.startsWith("# branch.ab ")) {
			const match = line.match(/^# branch\.ab \+(\d+) -(\d+)$/);
			if (match) {
				status.ahead = Number(match[1]);
				status.behind = Number(match[2]);
			}
			continue;
		}

		if (line.startsWith("? ")) {
			status.untracked++;
			continue;
		}

		if (line.startsWith("u ")) {
			status.conflicts++;
			continue;
		}

		if (!line.startsWith("1 ") && !line.startsWith("2 ")) continue;
		const xy = line.slice(2, 4);
		if (xy[0] && xy[0] !== ".") status.staged++;
		if (xy[1] && xy[1] !== ".") status.modified++;
	}

	return status;
}

export function addNumstat(output: string, status: GitStatus): void {
	for (const line of output.split("\n")) {
		const [added, deleted] = line.split("\t", 2);
		if (!added || !deleted) continue;
		const additions = Number(added);
		const deletions = Number(deleted);
		if (Number.isFinite(additions)) status.additions += additions;
		if (Number.isFinite(deletions)) status.deletions += deletions;
	}
}

function findComparisonRef(statusOutput: string, refsOutput: string): string | undefined {
	const upstream = statusOutput.match(/^# branch\.upstream (.+)$/m)?.[1];
	const upstreamRemote = upstream?.split("/", 1)[0];
	const refs = refsOutput
		.split("\n")
		.map((line) => line.split("\t", 2))
		.filter(([name]) => Boolean(name));

	for (const remote of [upstreamRemote, "origin"].filter(Boolean)) {
		const remoteHead = refs.find(
			([name, target]) => (name === remote || name === `${remote}/HEAD`) && target,
		);
		if (remoteHead?.[1]) return remoteHead[1];
	}

	for (const branch of ["main", "master", "trunk"]) {
		for (const name of [
			upstreamRemote ? `${upstreamRemote}/${branch}` : undefined,
			`origin/${branch}`,
			branch,
		].filter(Boolean)) {
			if (refs.some(([ref]) => ref === name)) return name;
		}
	}
	return undefined;
}

async function readNumstat(
	pi: ExtensionAPI,
	cwd: string,
	comparisonRef: string | undefined,
): Promise<string> {
	let base = "HEAD";
	if (comparisonRef) {
		const mergeBase = await pi.exec(
			"git",
			["--no-optional-locks", "merge-base", "HEAD", comparisonRef],
			{ cwd, timeout: 3_000 },
		);
		if (mergeBase.code === 0 && mergeBase.stdout.trim()) base = mergeBase.stdout.trim();
	}

	// A single base commit includes committed, staged, and unstaged branch changes.
	const result = await pi.exec(
		"git",
		["--no-optional-locks", "diff", "--no-ext-diff", "--numstat", base, "--"],
		{ cwd, timeout: 3_000 },
	);
	if (result.code === 0) return result.stdout;

	// An unborn branch has no HEAD. Its index is still useful for line totals.
	const staged = await pi.exec(
		"git",
		["--no-optional-locks", "diff", "--cached", "--no-ext-diff", "--numstat", "--"],
		{ cwd, timeout: 3_000 },
	);
	return staged.code === 0 ? staged.stdout : "";
}

export async function findGitStatus(
	pi: ExtensionAPI,
	cwd: string,
): Promise<GitStatus | undefined> {
	try {
		const [porcelain, refs] = await Promise.all([
			pi.exec(
				"git",
				["--no-optional-locks", "status", "--porcelain=v2", "--branch"],
				{ cwd, timeout: 3_000 },
			),
			pi.exec(
				"git",
				[
					"--no-optional-locks",
					"for-each-ref",
					"--format=%(refname:short)%09%(symref:short)",
					"refs/remotes",
					"refs/heads",
				],
				{ cwd, timeout: 3_000 },
			),
		]);
		if (porcelain.code !== 0) return undefined;

		const comparisonRef = refs.code === 0 ? findComparisonRef(porcelain.stdout, refs.stdout) : undefined;
		const numstat = await readNumstat(pi, cwd, comparisonRef);
		const status = parsePorcelainStatus(porcelain.stdout);
		addNumstat(numstat, status);
		return status;
	} catch {
		return undefined;
	}
}
