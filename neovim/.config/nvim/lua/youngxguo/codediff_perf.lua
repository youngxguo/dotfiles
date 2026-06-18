local M = {}

local FULL_STATUS_REQUESTS = "youngxguo_codediff_full_status_requests"
local STATUS_CACHE_TTL_MS = 2000
local uv = vim.uv or vim.loop
local status_cache = {}

local function now_ms()
  return math.floor(uv.hrtime() / 1000000)
end

local function clone_status(result)
  return result and vim.deepcopy(result) or nil
end

local function pending_full_status_requests()
  return tonumber(vim.g[FULL_STATUS_REQUESTS]) or 0
end

function M.request_full_status()
  if pending_full_status_requests() > 0 then
    return
  end

  vim.g[FULL_STATUS_REQUESTS] = 1

  -- If the request does not get consumed (for example :CodeDiff toggled an
  -- existing tab closed), do not let a later automatic refresh inherit it.
  vim.defer_fn(function()
    local pending = pending_full_status_requests()
    if pending > 0 then
      vim.g[FULL_STATUS_REQUESTS] = pending - 1
    end
  end, 10000)
end

local function consume_full_status_request()
  local pending = pending_full_status_requests()
  if pending <= 0 then
    return false
  end

  vim.g[FULL_STATUS_REQUESTS] = pending - 1
  return true
end

local function unquote_path(path)
  if path:sub(1, 1) ~= '"' or path:sub(-1) ~= '"' then
    return path
  end

  return path:sub(2, -2):gsub("\\(.)", function(char)
    local escapes = {
      a = "\a",
      b = "\b",
      t = "\t",
      n = "\n",
      v = "\v",
      f = "\f",
      r = "\r",
      ["\\"] = "\\",
      ['"'] = '"',
    }
    return escapes[char] or char
  end)
end

local function is_conflict_status(index_status, worktree_status)
  if index_status == "U" or worktree_status == "U" then
    return true
  end
  if index_status == "A" and worktree_status == "A" then
    return true
  end
  if index_status == "D" and worktree_status == "D" then
    return true
  end
  return false
end

local function parse_status(output)
  local result = {
    unstaged = {},
    staged = {},
    conflicts = {},
  }

  for line in output:gmatch("[^\r\n]+") do
    if #line >= 3 then
      local index_status = line:sub(1, 1)
      local worktree_status = line:sub(2, 2)
      local path_part = unquote_path(line:sub(4))
      local old_path, new_path = path_part:match("^(.+) %-> (.+)$")
      local path = old_path and new_path or path_part
      local is_rename = old_path ~= nil

      if is_conflict_status(index_status, worktree_status) then
        table.insert(result.conflicts, {
          path = path,
          status = "!",
          conflict_type = index_status .. worktree_status,
        })
      else
        if index_status ~= " " and index_status ~= "?" then
          table.insert(result.staged, {
            path = path,
            status = index_status,
            old_path = is_rename and old_path or nil,
          })
        end
        if worktree_status ~= " " then
          table.insert(result.unstaged, {
            path = path,
            status = worktree_status == "?" and "??" or worktree_status,
            old_path = is_rename and old_path or nil,
          })
        end
      end
    end
  end

  return result
end

local function run_git(args, git_root, callback)
  if vim.system then
    vim.system(vim.list_extend({ "git" }, args), {
      cwd = git_root,
      text = true,
    }, function(result)
      if result.code == 0 then
        callback(nil, result.stdout or "")
      else
        callback(result.stderr or "Git command failed", nil)
      end
    end)
    return
  end

  local stdout = {}
  local stderr = {}
  local cmd = vim.list_extend({ "git" }, args)
  local job_id = vim.fn.jobstart(cmd, {
    cwd = git_root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data or {}
    end,
    on_stderr = function(_, data)
      stderr = data or {}
    end,
    on_exit = function(_, code)
      if code == 0 then
        callback(nil, table.concat(stdout, "\n"))
      else
        callback(table.concat(stderr, "\n"), nil)
      end
    end,
  })

  if job_id <= 0 then
    callback("Failed to start git command", nil)
  end
end

local function parse_untracked(output, result)
  local seen = {}
  for _, file in ipairs(result.unstaged) do
    if file.status == "??" then
      seen[file.path] = true
    end
  end

  for path in output:gmatch("[^\r\n]+") do
    if path ~= "" and not seen[path] then
      seen[path] = true
      table.insert(result.unstaged, {
        path = path,
        status = "??",
      })
    end
  end
end

local function run_git_status(git_root, callback)
  run_git({ "status", "--porcelain", "-uno", "-M" }, git_root, function(status_err, status_output)
    if status_err then
      callback(status_err, nil)
      return
    end

    local result = parse_status(status_output or "")

    run_git({ "ls-files", "--others", "--exclude-standard" }, git_root, function(untracked_err, untracked_output)
      if untracked_err then
        callback(untracked_err, nil)
        return
      end

      parse_untracked(untracked_output or "", result)
      callback(nil, result)
    end)
  end)
end

local function finish_cached_status(git_root, err, result)
  local entry = status_cache[git_root] or {}
  local callbacks = entry.callbacks or {}

  entry.in_flight = false
  entry.callbacks = {}
  entry.updated_at = now_ms()
  if not err then
    entry.result = result
  end
  status_cache[git_root] = entry

  for _, callback in ipairs(callbacks) do
    callback(err, clone_status(result))
  end
end

local function run_git_status_cached(git_root, callback)
  local entry = status_cache[git_root]
  local current_ms = now_ms()

  if
    entry
    and not entry.in_flight
    and entry.result
    and current_ms - entry.updated_at < STATUS_CACHE_TTL_MS
  then
    vim.schedule(function()
      callback(nil, clone_status(entry.result))
    end)
    return
  end

  if entry and entry.in_flight then
    table.insert(entry.callbacks, callback)
    return
  end

  entry = entry or {}
  entry.in_flight = true
  entry.callbacks = { callback }
  status_cache[git_root] = entry

  run_git_status(git_root, function(err, result)
    finish_cached_status(git_root, err, result)
  end)
end

local function patch_git_status()
  local git = require("codediff.core.git")
  if git._youngxguo_cheap_status_patched then
    return
  end

  local full_get_status = git.get_status
  git._youngxguo_full_get_status = full_get_status
  git.get_status = function(git_root, callback)
    if consume_full_status_request() then
      return full_get_status(git_root, callback)
    end

    run_git_status_cached(git_root, function(err, result)
      if err then
        callback(err, nil)
        return
      end

      callback(nil, result)
    end)
  end
  git._youngxguo_cheap_status_patched = true
end

local function patch_explorer_keymaps()
  local keymaps = require("codediff.ui.explorer.keymaps")
  if keymaps._youngxguo_full_refresh_patched then
    return
  end

  local original_setup = keymaps.setup
  keymaps.setup = function(explorer)
    original_setup(explorer)

    local config = require("codediff.config")
    local explorer_keymaps = (config.options.keymaps or {}).explorer or {}
    local refresh_key = explorer_keymaps.refresh
    if not refresh_key or refresh_key == false then
      return
    end

    vim.keymap.set("n", refresh_key, function()
      M.request_full_status()
      require("codediff.ui.explorer.refresh").refresh(explorer)
    end, {
      buffer = explorer.bufnr,
      desc = "Refresh explorer (full git status)",
      silent = true,
    })
  end

  keymaps._youngxguo_full_refresh_patched = true
end

local function opens_working_tree_status(args)
  local non_flag_args = {}
  for _, arg in ipairs(args or {}) do
    if arg ~= "--inline" and arg ~= "--side-by-side" then
      table.insert(non_flag_args, arg)
    end
  end

  return #non_flag_args == 0
end

local function patch_commands()
  local commands = require("codediff.commands")
  if commands._youngxguo_full_initial_status_patched then
    return
  end

  local original_vscode_diff = commands.vscode_diff
  commands.vscode_diff = function(opts)
    if opts and opens_working_tree_status(opts.fargs) then
      M.request_full_status()
    end

    return original_vscode_diff(opts)
  end

  commands._youngxguo_full_initial_status_patched = true
end

function M.setup(opts)
  require("codediff").setup(opts)
  patch_git_status()
  patch_explorer_keymaps()
  patch_commands()
end

return M
