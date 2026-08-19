-- codediff navigation helpers: open working-tree diffs in the inline (unified)
-- layout with the explorer visible. `t` can still toggle an open view to the
-- side-by-side layout.

local M = {}

local DEFAULT_LAYOUT = "inline"

-- Steer the layout + explorer state codediff uses for the next view it opens.
-- Returns the layout so callers can also pass the matching command flag.
local function apply()
  local layout = DEFAULT_LAYOUT

  local ok, config = pcall(require, "codediff.config")
  if ok and config.options then
    if config.options.diff then
      config.options.diff.layout = layout
    end
    if config.options.explorer then
      config.options.explorer.hidden = false
    end
  end

  return layout
end

-- Default to compact mode (folds unchanged regions, like Diffview) so multi-hunk
-- files are obvious at a glance. Toggle back to the full file with `gc`.
--
-- codediff computes the diff asynchronously, so `stored_diff_result.changes` is
-- briefly nil after CodeDiffOpen fires; calling compact.enable() too early bails
-- with "No changes to compact". There's no diff-ready event, so poll for it.
local function enable_compact(tabpage, attempts)
  attempts = attempts or 0
  local ok_lifecycle, lifecycle = pcall(require, "codediff.ui.lifecycle")
  local ok_compact, compact = pcall(require, "codediff.ui.view.compact")
  if not (ok_lifecycle and ok_compact) then
    return
  end

  local session = lifecycle.get_session(tabpage)
  if session and session.stored_diff_result and session.stored_diff_result.changes then
    pcall(compact.enable, tabpage)
  elseif attempts < 40 then -- ~2s cap at 50ms steps
    vim.defer_fn(function()
      enable_compact(tabpage, attempts + 1)
    end, 50)
  end
end

-- codediff keys its sessions by tabpage, so a diff view lives in exactly one
-- tab. Scan the tab list for a CodeDiff session already open anywhere in this
-- Neovim instance.
local function find_codediff_tab()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if lifecycle.get_session(tabpage) ~= nil then
      return tabpage
    end
  end
  return nil
end

local function session_has_revision(lifecycle, tabpage)
  local explorer = lifecycle.get_explorer(tabpage)
  if explorer then
    return explorer.base_revision ~= nil
  end

  local context = lifecycle.get_git_context(tabpage)
  return context and context.original_revision ~= nil or false
end

local function activate_existing(layout, wants_revision)
  local current = vim.api.nvim_get_current_tabpage()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return false
  end

  -- Toggle a matching session when already sitting in its tab. If the shortcut
  -- requests the other diff kind, close this session and let the caller replace
  -- it instead.
  if lifecycle.get_session(current) ~= nil then
    if session_has_revision(lifecycle, current) == wants_revision then
      vim.cmd("CodeDiff --" .. layout)
      return true
    end
    return not lifecycle.close(current)
  end

  -- A matching CodeDiff tab in another tab should be focused instead of
  -- duplicated. Replace a different kind so <leader>gd and <leader>gD can
  -- switch between the working-tree and trunk views.
  local existing = find_codediff_tab()
  if existing then
    if session_has_revision(lifecycle, existing) == wants_revision then
      vim.api.nvim_set_current_tabpage(existing)
      return true
    end
    return not lifecycle.close(existing)
  end

  return false
end

local function command(layout, revision)
  if activate_existing(layout, revision ~= nil) then
    return
  end

  -- The full status is only needed for the ordinary working-tree explorer.
  if not revision then
    require("youngxguo.codediff_perf").request_full_status()
  end

  local args = {}
  if revision then
    table.insert(args, revision)
  end
  table.insert(args, "--" .. layout)
  vim.api.nvim_cmd({ cmd = "CodeDiff", args = args }, {})
end

local function probe_dir()
  local current_file = vim.api.nvim_buf_get_name(0)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = 0 })
  if current_file ~= "" and buftype == "" then
    return vim.fn.fnamemodify(current_file, ":p:h")
  end
  return vim.fn.getcwd()
end

vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("CodeDiffNavCompact", { clear = true }),
  pattern = "CodeDiffOpen",
  callback = function(args)
    local tabpage = args.data and args.data.tabpage
    if tabpage then
      enable_compact(tabpage)
    end
  end,
})

-- Open the working-tree diff in the unified layout.
function M.open_diff()
  local layout = apply()
  command(layout)
end

local function git_ref_exists(dir, ref)
  local result = vim.system({
    "git", "-C", dir, "rev-parse", "--verify", "--quiet", ref .. "^{commit}",
  }):wait()
  return result.code == 0
end

-- Resolve the repository's locally known trunk branch. Prefer origin's default
-- branch, then conventional remote-tracking and local branch names. This stays
-- entirely local; users can fetch separately when they want a newer trunk tip.
local function trunk_ref(dir)
  local remote_head = vim.system({
    "git", "-C", dir, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
  }, { text = true }):wait()
  if remote_head.code == 0 then
    local ref = vim.trim(remote_head.stdout or "")
    if ref ~= "" and git_ref_exists(dir, ref) then
      return ref
    end
  end

  for _, ref in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if git_ref_exists(dir, ref) then
      return ref
    end
  end
end

-- Show committed changes on the current branch since it diverged from trunk.
function M.open_trunk_diff()
  local layout = apply()
  if activate_existing(layout, true) then
    return
  end

  local dir = probe_dir()
  local base_ref = trunk_ref(dir)
  if not base_ref then
    vim.notify("Could not find a local trunk branch", vim.log.levels.ERROR)
    return
  end

  command(layout, base_ref .. "...HEAD")
end

return M
