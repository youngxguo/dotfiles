vim.opt.nu = true
vim.opt.relativenumber = true

vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true

vim.opt.smartindent = true

vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt.breakindent = true
vim.opt.cursorline = true

vim.opt.swapfile = false
vim.opt.backup = false

vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.ignorecase = true
vim.opt.smartcase = true

vim.opt.termguicolors = true
vim.opt.winborder = "single"

vim.opt.splitbelow = true
vim.opt.splitright = true

vim.opt.scrolloff = 8
vim.opt.signcolumn = "yes"
vim.opt.isfname:append("@-@")

vim.opt.updatetime = 50
vim.opt.autoread = true

vim.opt.clipboard = "unnamedplus"

vim.g.clipboard = {
  name = "OSC 52",
  copy = {
    ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
    ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
  },
  paste = {
    ["+"] = require("vim.ui.clipboard.osc52").paste("+"),
    ["*"] = require("vim.ui.clipboard.osc52").paste("*"),
  },
}

vim.api.nvim_create_autocmd("VimResized", {
  command = "wincmd =",
})

local checktime_group = vim.api.nvim_create_augroup("checktime", { clear = true })
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
  group = checktime_group,
  command = "checktime",
})

-- Set while a Diffview refresh reloads buffers via :checktime, so the toast
-- below stays quiet. A bulk external rewrite would otherwise spam one
-- notification per file; interactive reloads still notify.
local diffview_silent_reload = false

vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = checktime_group,
  callback = function()
    if diffview_silent_reload then
      return
    end
    vim.notify("File updated on disk. Reloaded.")
  end,
})

-- Ensure treesitter syntax highlighting in diff buffers (fugitive://, etc.)
vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(args)
    local buf = args.buf
    local ft = vim.bo[buf].filetype
    if vim.wo.diff then
      vim.wo.wrap = true
      vim.wo.linebreak = true
      vim.wo.breakindent = true
    end
    if ft and ft ~= "" and vim.wo.diff then
      pcall(vim.treesitter.start, buf, ft)
    end
  end,
})

local function nowrap_codediff_explorer_windows(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].wrap = false
      vim.wo[win].linebreak = false
      vim.wo[win].breakindent = false
    end
  end
end

vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
  group = vim.api.nvim_create_augroup("codediff_explorer_wrap", { clear = true }),
  callback = function(args)
    local buf = args.buf
    if vim.bo[buf].filetype ~= "codediff-explorer" then
      return
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
        nowrap_codediff_explorer_windows(buf)
      end
    end)
  end,
})

-- Keep an open Diffview in sync with disk without polling git. Two triggers
-- feed one debounced refresh:
--   * save / focus-gained -- the interactive case.
--   * libuv fs_event watches on the working-tree files the diff has loaded --
--     the unfocused case, e.g. an agent rewriting files while nvim sits in the
--     background, when the autocmds below never fire. Idle costs nothing: no
--     timer wakes the loop and no git runs until a watched file changes.
-- Linux inotify isn't recursive and a watch goes stale after a rename-replace,
-- so rather than watch the whole tree we re-arm the watch set on every refresh
-- (and as diff buffers load), which both rebuilds stale handles and tracks the
-- files currently in view.
local uv = vim.uv or vim.loop
local diffview_refresh_timer = uv.new_timer()
local diffview_refresh_delay_ms = 250
local diffview_watchers = {}

-- The diffview tab's current view, or nil. Never force-loads the lazy plugin.
local function current_diffview()
  if not package.loaded["diffview"] then
    return nil
  end
  local ok, view = pcall(function()
    return require("diffview.lib").get_current_view()
  end)
  return ok and view or nil
end

local function stop_diffview_watchers()
  for path, handle in pairs(diffview_watchers) do
    pcall(function()
      handle:stop()
      handle:close()
    end)
    diffview_watchers[path] = nil
  end
end

-- Working-tree files the diff currently has loaded -- real on-disk paths only,
-- skipping diffview://, fugitive:// and other scheme-backed buffers.
local function diffview_watch_paths()
  local paths = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and not name:find("://", 1, true) and uv.fs_stat(name) then
        paths[name] = true
      end
    end
  end
  return paths
end

local arm_diffview_watchers

-- Reload working-tree buffers that changed underneath us so the diff *content*
-- is current -- Diffview reuses buffers for unchanged paths and won't re-read
-- them on its own -- then recompute the file list and stats panel, and re-arm
-- the watch set against the diff's now-current files.
local function refresh_diffview()
  if not current_diffview() then
    stop_diffview_watchers()
    return
  end
  diffview_silent_reload = true
  pcall(vim.cmd.checktime)
  diffview_silent_reload = false
  pcall(require("diffview.actions").refresh_files)
  arm_diffview_watchers()
end

local function schedule_diffview_refresh()
  diffview_refresh_timer:stop()
  diffview_refresh_timer:start(diffview_refresh_delay_ms, 0, vim.schedule_wrap(refresh_diffview))
end

-- Rebuild the fs_event watch set from scratch so no stale handle survives a
-- rename-replace. Cheap: a handful of files, only while a view is open.
arm_diffview_watchers = function()
  stop_diffview_watchers()
  if not current_diffview() then
    return
  end
  for path in pairs(diffview_watch_paths()) do
    local handle = uv.new_fs_event()
    local ok = pcall(function()
      handle:start(path, {}, function(err)
        -- Runs in a fast-event context: only touch libuv here; the refresh
        -- itself is deferred via the timer's schedule_wrap.
        if not err then
          schedule_diffview_refresh()
        end
      end)
    end)
    if ok then
      diffview_watchers[path] = handle
    else
      pcall(function()
        handle:close()
      end)
    end
  end
end

vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
  callback = schedule_diffview_refresh,
})

-- Arm/disarm watchers as views open and close, and keep the set current as the
-- diff lazily loads more file buffers while you browse it.
local diffview_watch_group = vim.api.nvim_create_augroup("diffview_watch", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = diffview_watch_group,
  pattern = "DiffviewViewOpened",
  callback = function()
    vim.schedule(arm_diffview_watchers)
  end,
})
vim.api.nvim_create_autocmd("User", {
  group = diffview_watch_group,
  pattern = "DiffviewViewClosed",
  callback = function()
    -- A view may remain on another tab; stop only once the last one is gone.
    vim.schedule(function()
      if not current_diffview() then
        stop_diffview_watchers()
      end
    end)
  end,
})
vim.api.nvim_create_autocmd("BufReadPost", {
  group = diffview_watch_group,
  callback = function()
    if current_diffview() then
      vim.schedule(arm_diffview_watchers)
    end
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    diffview_refresh_timer:stop()
    diffview_refresh_timer:close()
    stop_diffview_watchers()
  end,
})
