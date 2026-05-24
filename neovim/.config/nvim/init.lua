vim.g.mapleader = " "

-- nvim-tree loads lazily now, so disable netrw here (before it would load).
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0

require("youngxguo")
