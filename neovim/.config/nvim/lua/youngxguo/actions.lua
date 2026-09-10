local M = {}

function M.yank_and_notify(text)
  vim.fn.setreg("+", text)
  vim.notify(text)
end

function M.yank_file_path()
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
  M.yank_and_notify(path)
end

local function normalize_remote_url(remote)
  return (remote:gsub("^git@([^:]+):", "https://%1/"):gsub("%.git$", ""))
end

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

-- Diffview, fugitive and Octo diffs are not gitsigns buffers, so fall back to
-- Vim's own diff navigation whenever the window is in diff mode.
function M.nav_hunk(direction)
  if vim.wo.diff then
    pcall(vim.cmd.normal, { direction == "next" and "]c" or "[c", bang = true })
    return
  end
  require("gitsigns").nav_hunk(direction)
end

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

function M.git_blame_commit_diffview()
  local sha = blame_sha_for_current_line()
  if not sha then
    return
  end
  vim.cmd("DiffviewOpen " .. sha .. "^.." .. sha)
end

function M.git_blame_commit_remote()
  local sha = blame_sha_for_current_line()
  if not sha then
    return
  end
  local remote = vim.fn.system("git remote get-url origin"):gsub("%s+$", "")
  local url = normalize_remote_url(remote) .. "/commit/" .. sha
  M.yank_and_notify(url)
end

function M.octo_with_progress(command, message, filetype)
  local loading = require("fidget.progress").handle.create({
    lsp_client = { name = "Octo" },
    message = message,
  })
  local done = false
  local function finish_loading()
    if done then
      return
    end
    done = true
    loading:finish()
  end

  local autocmd = vim.api.nvim_create_autocmd("FileType", {
    pattern = filetype,
    once = true,
    callback = finish_loading,
  })
  vim.defer_fn(function()
    finish_loading()
    pcall(vim.api.nvim_del_autocmd, autocmd)
  end, 15000)

  vim.cmd(command)
end

return M
