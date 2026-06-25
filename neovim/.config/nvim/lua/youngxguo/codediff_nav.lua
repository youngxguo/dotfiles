-- codediff navigation helpers: open the working-tree diff with a layout + an
-- explorer state chosen to fit the current editor width. codediff reads
-- `codediff.config.options` at open time, so we mutate it just before opening
-- (the same trick `diffview_nav` uses for Diffview's default layout).
--
-- codediff exposes no public API to toggle layout / explorer or query an open
-- view, so this is an open-time decision only: a view does NOT reflow on
-- resize. Reopen (<leader>gd) to re-pick after resizing the pane.

local M = {}

-- Width budget. The window splits into `explorer (~32) + diff area`.
--   * Side-by-side wants two code panes of ~50 cols each beside the explorer,
--     so it reads well once there's room for the smaller explorer + 2 panes.
local MIN_COLUMNS_FOR_SIDE_BY_SIDE = 132

-- Decide the tier for the current editor width:
--   < 132        -> inline,        explorer shown
--   >= 132       -> side-by-side,  explorer shown
local function plan()
  local cols = vim.o.columns
  local layout = cols >= MIN_COLUMNS_FOR_SIDE_BY_SIDE and "side-by-side" or "inline"
  return layout
end

-- Steer the layout + explorer state codediff uses for the next view it opens.
-- Returns the chosen layout so callers can also pass the matching flag.
local function apply()
  local layout = plan()

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

local function command(layout)
  local current = vim.api.nvim_get_current_tabpage()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")

  -- Already sitting in the CodeDiff tab: re-run :CodeDiff, which toggles the
  -- session closed (its normal in-session behaviour). No fresh git status.
  if ok and lifecycle.get_session(current) ~= nil then
    vim.cmd("CodeDiff --" .. layout)
    return
  end

  -- A CodeDiff tab is open in another tab: focus it instead of spawning a
  -- second one. Repeated <leader>gd from a file tab otherwise piles up
  -- duplicate diff tabs.
  local existing = find_codediff_tab()
  if existing then
    vim.api.nvim_set_current_tabpage(existing)
    return
  end

  -- No CodeDiff tab yet: warm the git-status cache, then open a fresh one.
  require("youngxguo.codediff_perf").request_full_status()
  vim.cmd("CodeDiff --" .. layout)
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

-- Open the working-tree diff sized for the current width.
function M.open_diff()
  local layout = apply()
  command(layout)
end

return M
