-- Run from the repo root: nvim --headless -u NONE -l neovim/tests/codediff_base.lua
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
  git("update-ref", "-d", "refs/remotes/origin/explicit-parent")
  local notified = false
  vim.notify = function() notified = true end
  selected = nil
  nav.open_base_diff()
  assert(selected == nil and notified, "missing explicit parent must not guess another base")
end)
vim.fn.delete(root, "rf")
if not ok then error(err) end
print("codediff base regression tests passed")
