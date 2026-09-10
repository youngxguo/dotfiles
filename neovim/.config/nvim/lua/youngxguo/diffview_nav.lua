local M = {}

local MIN_COLUMNS_FOR_SIDE_BY_SIDE = 100

local function want_horizontal()
  return vim.o.columns >= MIN_COLUMNS_FOR_SIDE_BY_SIDE
end

-- Diffview reads `view.default.layout` once, at open time, so this only affects
-- fresh views.
local function apply_layout()
  local ok, config = pcall(require, "diffview.config")
  if not ok then
    return
  end

  local layout = want_horizontal() and "diff2_horizontal" or "diff2_vertical"

  local cfg = config.get_config()
  cfg.view.default.layout = layout
  cfg.view.file_history.layout = layout
end

-- For a live view Diffview's own `cycle_layout` action toggles
-- diff2_horizontal <-> diff2_vertical for standard 2-pane diffs.
local function relayout_open_view()
  local ok_lib, lib = pcall(require, "diffview.lib")
  if not ok_lib then
    return
  end

  local view = lib.get_current_view and lib.get_current_view()
  local cur_layout = view and view.cur_layout
  local class = cur_layout and cur_layout.class
  if not class then
    return
  end

  if class.name ~= "diff2_horizontal" and class.name ~= "diff2_vertical" then
    return
  end

  local want = want_horizontal() and "diff2_horizontal" or "diff2_vertical"
  if class.name == want then
    return
  end

  apply_layout()
  pcall(require("diffview.actions").cycle_layout)
end

vim.api.nvim_create_autocmd("VimResized", {
  group = vim.api.nvim_create_augroup("youngxguo_diffview_relayout", { clear = true }),
  callback = function()
    vim.schedule(relayout_open_view)
  end,
})

local function diffview_ctx()
  local ok_lib, lib = pcall(require, "diffview.lib")
  if not ok_lib or not lib then
    return nil
  end

  local ok_diff, DiffView = pcall(function()
    return require("diffview.scene.views.diff.diff_view").DiffView
  end)
  local ok_history, FileHistoryView = pcall(function()
    return require("diffview.scene.views.file_history.file_history_view").FileHistoryView
  end)

  return {
    lib = lib,
    DiffView = ok_diff and DiffView or nil,
    FileHistoryView = ok_history and FileHistoryView or nil,
  }
end

local function is_view(view, klass)
  return view and klass and view.instanceof and view:instanceof(klass)
end

local function find_view(predicate)
  local ctx = diffview_ctx()
  if not ctx then
    return nil
  end

  local current = ctx.lib.get_current_view and ctx.lib.get_current_view() or nil
  if predicate(current, ctx) then
    return current, ctx
  end

  for _, view in ipairs(ctx.lib.views or {}) do
    if predicate(view, ctx) and view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) then
      return view, ctx
    end
  end
end

local function focus_view(predicate, on_focus)
  local view = find_view(predicate)
  if not view then
    return false
  end

  if view.tabpage and vim.api.nvim_tabpage_is_valid(view.tabpage) then
    vim.api.nvim_set_current_tabpage(view.tabpage)
  end

  if on_focus then
    pcall(on_focus, view)
  end

  return true
end

function M.open_diff()
  if focus_view(function(view, ctx)
    return is_view(view, ctx.DiffView)
  end, function()
    pcall(require("diffview.actions").refresh_files)
  end) then
    return
  end

  apply_layout()
  vim.cmd("DiffviewOpen")
end

function M.close()
  vim.cmd("DiffviewClose")
end

function M.open_history()
  if focus_view(function(view, ctx)
    return is_view(view, ctx.FileHistoryView) and view.panel and not view.panel.single_file
  end, function()
    pcall(require("diffview.actions").refresh_files)
  end) then
    return
  end

  apply_layout()
  vim.cmd("DiffviewFileHistory --max-count=20")
end

return M
