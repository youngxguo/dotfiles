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
    vim.keymap.set('n', '<C-]>', '<cmd>lua vim.lsp.buf.definition()<cr>', opts)
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
    vim.keymap.set({ 'n', 'v' }, '<leader>ca', vim.lsp.buf.code_action, vim.tbl_extend('force', opts, { desc = 'LSP code action' }))
    vim.keymap.set('n', '<leader>dd', function()
      require("fzf-lua").diagnostics_document()
    end, opts)
    vim.keymap.set('n', '<leader>dw', function()
      require("fzf-lua").diagnostics_workspace()
    end, opts)
    vim.keymap.set('n', '<leader>pr', '<cmd>FzfLua lsp_references<cr>', opts)
  end,
})

local function local_tsserver_path(root_dir)
  if not root_dir or root_dir == '' then
    return nil
  end

  local path = root_dir .. '/node_modules/typescript/lib/tsserver.js'
  if vim.uv.fs_stat(path) then
    return path
  end

  return nil
end

local function lsp_root_from_init(init_params, config)
  if config and type(config.root_dir) == 'string' and config.root_dir ~= '' then
    return config.root_dir
  end

  if init_params and init_params.rootPath and init_params.rootPath ~= '' then
    return init_params.rootPath
  end

  if init_params and init_params.rootUri and init_params.rootUri ~= '' then
    return vim.uri_to_fname(init_params.rootUri)
  end

  return nil
end

local ts_lsp_root_markers = { 'pnpm-workspace.yaml', 'pnpm-lock.yaml', 'tsconfig.json', 'package.json', '.git' }

local function ts_lsp_root_dir(bufnr, cb)
  local root_dir = vim.fs.root(bufnr, ts_lsp_root_markers)
  cb(root_dir)
end

-- https://github.com/neovim/nvim-lspconfig/blob/master/doc/configs.md
vim.lsp.config('ts_ls', {
  filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact' },
  root_dir = ts_lsp_root_dir,
  root_markers = ts_lsp_root_markers,
  cmd_env = { NODE_OPTIONS = '--max-old-space-size=8192' },
  before_init = function(init_params, config)
    local root_dir = lsp_root_from_init(init_params, config)
    local tsserver_path = local_tsserver_path(root_dir)
    if not tsserver_path then
      return
    end

    config.init_options = vim.tbl_deep_extend('force', config.init_options or {}, {
      tsserver = {
        path = tsserver_path,
      },
    })
  end,
  init_options = {
    preferences = {
      preferGoToSourceDefinition = true,
    },
    maxTsServerMemory = 8192,
  },
})

local enabled_servers = { 'ts_ls' }

if vim.fn.executable('basedpyright-langserver') == 1 then
  vim.lsp.config('basedpyright', {
    root_markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', '.git' },
  })
  table.insert(enabled_servers, 'basedpyright')
end

-- Keep ESLint LSP disabled by default to avoid extra memory pressure in large
-- worktrees. Run linting manually from the CLI instead.
-- if vim.fn.executable('vscode-eslint-language-server') == 1 then
--   vim.lsp.config('eslint', {
--     cmd = { 'vscode-eslint-language-server', '--stdio' },
--     filetypes = { 'javascript', 'javascriptreact', 'typescript', 'typescriptreact', 'vue', 'svelte', 'astro' },
--     settings = {
--       run = 'onType',
--       validate = 'on',
--       nodePath = vim.fn.exepath('node'),
--       workingDirectories = { mode = 'auto' }
--     },
--     cmd_env = { NODE_OPTIONS = '--max-old-space-size=8192' }
--   })
-- end

vim.lsp.enable(enabled_servers)
