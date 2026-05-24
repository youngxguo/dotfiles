local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end

vim.opt.rtp:prepend(lazypath)

-- Initialize vim.lsp.config['*'] before plugins load (blink.cmp v1.x reads it)
if vim.lsp.config then
  vim.lsp.config("*", {})
end

require("lazy").setup({
  { import = "youngxguo.plugins" },
}, {
  rocks = {
    enabled = false,
  },
})
