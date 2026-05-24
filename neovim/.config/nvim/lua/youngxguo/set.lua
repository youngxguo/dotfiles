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

vim.api.nvim_create_autocmd("FileChangedShellPost", {
  group = checktime_group,
  callback = function()
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

-- Auto-refresh diffview on file save/focus, but debounce rapid bursts.
local uv = vim.uv or vim.loop
local diffview_refresh_timer = uv.new_timer()
local diffview_refresh_delay_ms = 250

local function refresh_diffview_if_open()
  -- Don't force-load lazy diffview: only inspect it if it's already loaded.
  if not package.loaded["diffview"] then
    return
  end
  pcall(function()
    local lib = require("diffview.lib")
    if lib.get_current_view() then
      require("diffview.actions").refresh_files()
    end
  end)
end

vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
  callback = function()
    diffview_refresh_timer:stop()
    diffview_refresh_timer:start(diffview_refresh_delay_ms, 0, vim.schedule_wrap(refresh_diffview_if_open))
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    diffview_refresh_timer:stop()
    diffview_refresh_timer:close()
  end,
})
