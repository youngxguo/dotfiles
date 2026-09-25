-- Run from the repo root: nvim --headless --clean -l neovim/tests/codediff_base.lua
-- (--clean, not -u NONE: the default runtimepath still loads ~/.config/nvim,
-- which is this repo, so -u NONE would test the working tree either way).
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/neovim/.config/nvim")
local nav = require("youngxguo.codediff_nav")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(...)
  local args = { "git", "-C", root }
  vim.list_extend(args, { ... })
  local result = vim.system(args, { text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function commit(name)
  git("commit", "--allow-empty", "-m", name)
  return git("rev-parse", "HEAD")
end
local selected
vim.api.nvim_create_user_command("CodeDiff", function(args)
  selected = args.fargs[1]
end, { nargs = "*" })
-- Exercise offline/local inference, independent of GitHub authentication.
local executable = vim.fn.executable
vim.fn.executable = function(name)
  return name == "gh" and 0 or executable(name)
end
local function check(expected, label)
  selected = nil
  nav.open_base_diff()
  assert(selected == expected, label .. ": expected " .. expected .. ", got " .. tostring(selected))
end
local function check_failure(label)
  local notify = vim.notify
  local message
  vim.notify = function(text) message = text end
  selected = nil
  nav.open_base_diff()
  vim.notify = notify
  assert(selected == nil and message, label .. ": expected a visible failure")
end
local ok, err = pcall(function()
  git("init", "-b", "main")
  git("config", "user.name", "Test")
  git("config", "user.email", "test@example.invalid")
  git("config", "commit.gpgsign", "false")
  vim.cmd.cd(root)
  commit("old trunk")
  git("branch", "stale-branch")
  local base = commit("trunk")
  git("branch", "child")
  commit("newer trunk")
  git("checkout", "child")
  check(base, "behind trunk must not infer an old branch as parent")
  local parent = commit("parent change")
  git("branch", "parent")
  commit("child change")
  check(parent, "unmerged stack parent")
  git("branch", "-D", "parent")
  check(base, "unstacked branch uses trunk merge-base")
  git("branch", "explicit-parent", parent)
  git("branch", "--set-upstream-to=explicit-parent", "child")
  check(parent, "explicit stack upstream")
  -- A linked worktree uses the same ancestry rules.
  git("worktree", "add", root .. "/linked", "-b", "linked-child", parent)
  vim.cmd.cd(root .. "/linked")
  check(parent, "linked worktree stacked on parent")
  -- Kickoff records the parent independently of push/pull tracking. Once that
  -- parent advances, tip-based inference alone can no longer discover it.
  git("config", "branch.linked-child.gh-merge-base", "explicit-parent")
  git("checkout", "explicit-parent")
  local advanced = commit("parent advances")
  check(parent, "recorded parent advances after kickoff")
  git("config", "branch.linked-child.remote", "origin")
  git("config", "branch.linked-child.merge", "refs/heads/linked-child")
  check(parent, "push upstream does not replace recorded parent")
  git("checkout", "main")
  git("update-ref", "refs/remotes/origin/explicit-parent", advanced)
  git("branch", "-D", "explicit-parent")
  check(parent, "deleted local parent uses its remote ref")
  -- A PR's baseRefOid is GitHub's snapshot of the base branch at the PR's
  -- last sync. The live base ref wins when the branch was rebased past the
  -- snapshot; the snapshot wins when the local fetch of the base ref is stale.
  vim.cmd.cd(root)
  local old_main = git("rev-parse", "main")
  local new_main = commit("trunk moves on")
  git("checkout", "-b", "pr-child")
  commit("pr change")
  git("update-ref", "refs/remotes/origin/main", new_main)
  local pr_base_oid = old_main
  local pr_base_name = "main"
  git("config", "branch.pr-child.gh-merge-base", "stale-branch")
  local system = vim.system
  vim.fn.executable = function(name)
    return name == "gh" and 1 or executable(name)
  end
  vim.system = function(cmd, ...)
    if cmd[1] == "gh" then
      local stdout = vim.json.encode({ baseRefName = pr_base_name, baseRefOid = pr_base_oid })
      return { wait = function() return { code = 0, stdout = stdout } end }
    end
    return system(cmd, ...)
  end
  check(new_main, "branch rebased past GitHub's base snapshot uses the live base ref")
  git("update-ref", "refs/remotes/origin/main", old_main)
  pr_base_oid = new_main
  -- Remove reflog evidence so this specifically exercises the snapshot fallback.
  git("reflog", "expire", "--expire=all", "refs/remotes/origin/main")
  check(new_main, "stale local base ref defers to GitHub's newer snapshot")
  pr_base_oid = nil
  check(old_main, "PR target takes precedence over configured base without snapshot")
  git("update-ref", "-d", "refs/remotes/origin/main")
  check(new_main, "PR target resolves through local branch when remote is absent")
  pr_base_name = "unfetched-target"
  pr_base_oid = new_main
  check(new_main, "available PR snapshot resolves an unfetched target")
  pr_base_oid = nil
  check_failure("missing PR target must not fall through to configured base")
  vim.system = system
  vim.fn.executable = function(name)
    return name == "gh" and 0 or executable(name)
  end
  git("config", "--unset", "branch.pr-child.gh-merge-base")
  git("checkout", "--detach")
  check(new_main, "detached HEAD uses trunk ancestry")
  git("checkout", "--orphan", "unrelated")
  commit("unrelated root")
  check_failure("unrelated histories must not compare against trunk tip")
  git("checkout", "pr-child")
  git("config", "branch.pr-child.gh-merge-base", "unrelated")
  check_failure("unrelated explicit base must not compare against its tip")
  -- Rewriting a recorded parent retains the old boundary via its reflog.
  git("branch", "rewritten-parent", new_main)
  git("config", "branch.pr-child.gh-merge-base", "rewritten-parent")
  git("branch", "-f", "rewritten-parent", "unrelated")
  check(new_main, "parent rewrite uses fork-point evidence")
  vim.cmd.cd(root .. "/linked")
  git("update-ref", "-d", "refs/remotes/origin/explicit-parent")
  check_failure("missing explicit parent must not guess another base")
end)
vim.fn.delete(root, "rf")
if not ok then error(err) end
print("codediff base regression tests passed")
