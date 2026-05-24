-- Shared editor actions. Defined once here so both keymaps (remap.lua) and the
-- command palette (after/plugin/command_menu.lua) call the same functions
-- directly, instead of the palette replaying keystrokes.

local M = {}

-- Yank text to the system clipboard and echo it, forcing an OSC 52 copy so it
-- works over SSH/tmux even when a register write alone would not trigger one.
function M.yank_and_notify(text)
  vim.fn.setreg("+", text)
  local osc52 = vim.g.clipboard and vim.g.clipboard.copy and vim.g.clipboard.copy["+"]
  if osc52 then
    osc52({ text })
  end
  vim.notify(text)
end

-- Yank the current file's path relative to cwd.
function M.yank_file_path()
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  M.yank_and_notify(path)
end

local function normalize_remote_url(remote)
  return (remote:gsub("^git@([^:]+):", "https://%1/"):gsub("%.git$", ""))
end

-- Build and yank a remote blob link for the given path + line suffix, anchored
-- at the current HEAD commit so line numbers match the code you are looking at.
-- (origin/HEAD would point at the remote default branch, where lines have moved.)
local function git_blob_url(path, line_suffix)
  local remote = vim.fn.trim(vim.fn.system("git remote get-url origin"))
  if vim.v.shell_error ~= 0 then
    vim.notify("Not a git repo or no remote", vim.log.levels.ERROR)
    return
  end
  local commit = vim.fn.trim(vim.fn.system("git rev-parse HEAD"))
  if vim.v.shell_error ~= 0 then
    vim.notify("Could not resolve HEAD commit", vim.log.levels.ERROR)
    return
  end
  local url = normalize_remote_url(remote) .. "/blob/" .. commit .. "/" .. path .. line_suffix
  M.yank_and_notify(url)
end

-- Yank a remote link to the current line (or visual range).
function M.yank_git_link()
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local start = vim.fn.line("v")
    local finish = vim.fn.line(".")
    if start > finish then
      start, finish = finish, start
    end
    git_blob_url(path, "#L" .. start .. "-L" .. finish)
  else
    git_blob_url(path, "#L" .. vim.fn.line("."))
  end
end

-- Resolve the commit SHA that last touched the current line via git blame.
local function blame_sha_for_current_line()
  local file = vim.fn.expand("%:p")
  local lnum = vim.fn.line(".")
  local out = vim.fn.system({ "git", "blame", "-L", lnum .. "," .. lnum, "--porcelain", "--", file })
  local sha = out:match("^(%x+)")
  if not sha or sha:match("^0+$") then
    vim.notify("No commit for this line (uncommitted change)", vim.log.levels.WARN)
    return nil
  end
  return sha
end

-- Open the current line's commit in Diffview.
function M.git_blame_commit_diffview()
  local sha = blame_sha_for_current_line()
  if not sha then
    return
  end
  vim.cmd("DiffviewOpen " .. sha .. "^.." .. sha)
end

-- Yank a remote link to the current line's commit.
function M.git_blame_commit_remote()
  local sha = blame_sha_for_current_line()
  if not sha then
    return
  end
  local remote = vim.fn.system("git remote get-url origin"):gsub("%s+$", "")
  local url = normalize_remote_url(remote) .. "/commit/" .. sha
  M.yank_and_notify(url)
end

return M
