-- Diffview navigation helpers: focus an already-open Diffview / file-history
-- tab if one exists (refreshing it), otherwise open a fresh one. Exposed as
-- functions so the diffview spec keys and the command palette share them.

local M = {}

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

-- Open the working-tree diff, or focus + refresh an existing one.
function M.open_diff()
  if focus_view(function(view, ctx)
    return is_view(view, ctx.DiffView)
  end, function()
    pcall(require("diffview.actions").refresh_files)
  end) then
    return
  end

  vim.cmd("DiffviewOpen")
end

function M.close()
  vim.cmd("DiffviewClose")
end

-- Open file history, or focus + refresh an existing (multi-file) history view.
function M.open_history()
  if focus_view(function(view, ctx)
    return is_view(view, ctx.FileHistoryView) and view.panel and not view.panel.single_file
  end, function()
    pcall(require("diffview.actions").refresh_files)
  end) then
    return
  end

  vim.cmd("DiffviewFileHistory --max-count=20")
end

return M
