vim.diagnostic.config({
  underline = true,
  -- Off: recomputing diagnostics on every keystroke is noisy/laggy in large
  -- TS files. They refresh when you stop typing instead.
  update_in_insert = false,
  virtual_text = { spacing = 4, prefix = '●' },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = '✘',
      [vim.diagnostic.severity.WARN] = '▲',
      [vim.diagnostic.severity.HINT] = '⚑',
      [vim.diagnostic.severity.INFO] = '»',
    },
  },
  severity_sort = true,
})

-- blink.cmp auto-injects capabilities on nvim 0.11 via its plugin file

vim.api.nvim_create_autocmd('LspAttach', {
  desc = 'LSP actions',
  callback = function(event)
    local opts = {buffer = event.buf}
    vim.keymap.set('n', '<C-]>', function()
      require('fzf-lua').lsp_definitions()
    end, vim.tbl_extend('force', opts, { desc = 'LSP definitions' }))
    vim.keymap.set('n', 'gd', '<cmd>lua vim.lsp.buf.definition()<cr>', opts)
    vim.keymap.set('n', 'gh', function()
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      if #vim.diagnostic.get(0, { lnum = row }) > 0 then
        vim.diagnostic.open_float()
      else
        vim.lsp.buf.hover()
      end
    end, opts)
    vim.keymap.set('n', 'gr', '<cmd>FzfLua lsp_references<cr>', opts)
    vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, vim.tbl_extend('force', opts, { desc = 'LSP rename' }))
    vim.keymap.set({ 'n', 'v' }, '<leader>ca', function()
      require('fzf-lua').lsp_code_actions()
    end, vim.tbl_extend('force', opts, { desc = 'LSP code action' }))
    vim.keymap.set('n', '<leader>dd', function()
      require("fzf-lua").diagnostics_document()
    end, opts)
    vim.keymap.set('n', '<leader>dw', function()
      require("fzf-lua").diagnostics_workspace()
    end, opts)
    vim.keymap.set('n', '<leader>pr', '<cmd>FzfLua lsp_references<cr>', opts)
  end,
})

-- ts_ls needs a real TypeScript install and exits at startup without one, which
-- projects whose deps aren't installed hit. Point it at a private copy:
-- install.py's ensure_typescript_fallback() keeps that copy in place.
vim.lsp.config('ts_ls', {
  cmd_env = { NODE_OPTIONS = '--max-old-space-size=8192' },
  init_options = {
    preferences = {
      preferGoToSourceDefinition = true,
    },
    maxTsServerMemory = 8192,
    tsserver = {
      path = vim.fn.stdpath('data') .. '/ts-fallback/node_modules/typescript/lib/tsserver.js',
    },
  },
})

local enabled_servers = { 'ts_ls' }

if vim.fn.executable('basedpyright-langserver') == 1 then
  vim.lsp.config('basedpyright', {
    root_markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', '.git' },
  })
  table.insert(enabled_servers, 'basedpyright')
end

vim.lsp.enable(enabled_servers)
