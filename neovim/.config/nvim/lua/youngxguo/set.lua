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

-- Set while a background Diffview poll reloads buffers via :checktime, so the
-- toast below stays quiet. An agent rewriting many files would otherwise spam
-- one notification per file on every poll; interactive reloads still notify.
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

-- Keep an open Diffview in sync with disk. Two triggers feed one refresh:
--   * save / focus-gained, debounced -- the interactive case.
--   * a repeating background poll while a view is open -- the unfocused case,
--     e.g. an agent rewriting files while nvim sits in the background. Neovim's
--     libuv loop keeps ticking without OS focus, but the autocmds below don't
--     fire then, so the diff would otherwise go stale until you click back in.
local uv = vim.uv or vim.loop
local diffview_refresh_timer = uv.new_timer()
local diffview_refresh_delay_ms = 250
local diffview_poll_timer = uv.new_timer()
local diffview_poll_interval_ms = 1000

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

local function is_diff_view(view)
  if not (view and view.instanceof) then
    return false
  end
  local ok, DiffView = pcall(function()
    return require("diffview.scene.views.diff.diff_view").DiffView
  end)
  return ok and DiffView ~= nil and view:instanceof(DiffView)
end

-- Reload working-tree buffers that changed underneath us so the diff *content*
-- is current -- Diffview reuses buffers for unchanged paths and won't re-read
-- them on its own -- then recompute the file list and stats panel. `diff_only`
-- skips the heavier file-history rebuild; `silent` mutes the reload toast.
local function refresh_diffview(opts)
  opts = opts or {}
  local view = current_diffview()
  if not view then
    return
  end
  if opts.diff_only and not is_diff_view(view) then
    return
  end
  diffview_silent_reload = opts.silent or false
  pcall(vim.cmd.checktime)
  diffview_silent_reload = false
  pcall(require("diffview.actions").refresh_files)
end

vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
  callback = function()
    diffview_refresh_timer:stop()
    diffview_refresh_timer:start(
      diffview_refresh_delay_ms,
      0,
      vim.schedule_wrap(function()
        refresh_diffview()
      end)
    )
  end,
})

-- Only poll while a Diffview is open, so an idle session never wakes the loop.
local diffview_poll_group = vim.api.nvim_create_augroup("diffview_poll", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = diffview_poll_group,
  pattern = "DiffviewViewOpened",
  callback = function()
    diffview_poll_timer:stop()
    diffview_poll_timer:start(
      diffview_poll_interval_ms,
      diffview_poll_interval_ms,
      vim.schedule_wrap(function()
        refresh_diffview({ silent = true, diff_only = true })
      end)
    )
  end,
})
vim.api.nvim_create_autocmd("User", {
  group = diffview_poll_group,
  pattern = "DiffviewViewClosed",
  callback = function()
    -- A view may remain on another tab; stop only once the last one is gone.
    vim.schedule(function()
      if not current_diffview() then
        diffview_poll_timer:stop()
      end
    end)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    diffview_refresh_timer:stop()
    diffview_refresh_timer:close()
    diffview_poll_timer:stop()
    diffview_poll_timer:close()
  end,
})
