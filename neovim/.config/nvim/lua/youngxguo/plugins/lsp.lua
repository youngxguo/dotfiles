-- Server setup, keymaps and diagnostics config live in after/plugin/lsp.lua:
-- they are event-driven (LspAttach) and must run after nvim-lspconfig loads,
-- so they are not colocated here.
return {
  { "neovim/nvim-lspconfig" },

  {
    "saghen/blink.cmp",
    version = "1.*",
    opts = {
      keymap = {
        preset = "super-tab",
        ["<CR>"] = { "accept", "fallback" },
      },
      completion = {
        documentation = { auto_show = true },
      },
      -- Inline signature help (parameter hints) while typing call arguments.
      signature = { enabled = true },
      cmdline = {
        enabled = true,
        keymap = {
          ["<Up>"] = { "select_prev", "fallback" },
          ["<Down>"] = { "select_next", "fallback" },
          ["<Tab>"] = { "show", "accept", "fallback" },
          ["<S-Tab>"] = { "select_prev", "fallback" },
        },
        completion = {
          list = {
            selection = {
              preselect = true,
              auto_insert = false,
            },
          },
          menu = {
            auto_show = function()
              return vim.fn.getcmdtype() == ":"
            end,
          },
        },
      },
      sources = {
        default = { "lsp", "path", "buffer" },
      },
    },
  },

  {
    "stevearc/conform.nvim",
    event = { "BufReadPost", "BufNewFile" },
    keys = {
      {
        "<leader>f",
        function()
          require("conform").format({ lsp_format = "never", timeout_ms = 5000 })
        end,
        mode = { "n", "v" },
        desc = "Format buffer",
      },
    },
    opts = {
      notify_on_error = true,
      formatters_by_ft = {
        python = { "ruff_fix", "ruff_organize_imports", "ruff_format" },
        javascript = { "prettier" },
        javascriptreact = { "prettier" },
        typescript = { "prettier" },
        typescriptreact = { "prettier" },
        json = { "prettier" },
        css = { "prettier" },
        markdown = { "prettier" },
      },
      format_on_save = {
        timeout_ms = 5000,
        lsp_format = "never",
      },
    },
    config = function(_, opts)
      require("conform").setup(opts)

      -- Run ESLint fix-all on save via the ESLint LSP (like VSCode's
      -- source.fixAll.eslint). Fast because the ESLint LSP keeps the TS project
      -- in memory. Dormant unless an eslint client is attached.
      vim.api.nvim_create_autocmd("BufWritePre", {
        callback = function(args)
          local clients = vim.lsp.get_clients({ bufnr = args.buf, name = "eslint" })
          if #clients > 0 then
            vim.lsp.buf.code_action({
              context = { only = { "source.fixAll.eslint" }, diagnostics = {} },
              apply = true,
            })
          end
        end,
      })
    end,
  },

  {
    "j-hui/fidget.nvim",
    opts = function()
      local default_config = require("fidget.notification").default_config

      return {
        progress = {
          display = {
            done_style = "YoungFidgetDone",
            progress_style = "YoungFidgetProgress",
            group_style = "YoungFidgetGroup",
            icon_style = "YoungFidgetIcon",
          },
        },
        notification = {
          configs = {
            default = vim.tbl_extend("force", default_config, {
              group_style = "YoungFidgetGroup",
              icon_style = "YoungFidgetIcon",
              annote_style = "YoungFidgetInfo",
              debug_style = "YoungFidgetDebug",
              info_style = "YoungFidgetInfo",
              warn_style = "YoungFidgetWarn",
              error_style = "YoungFidgetError",
            }),
          },
          view = {
            group_separator_hl = "YoungFidgetSeparator",
          },
          window = {
            normal_hl = "YoungFidgetNormal",
            winblend = 0,
            avoid = { "NvimTree" },
          },
        },
      }
    end,
    config = function(_, opts)
      require("fidget").setup(opts)
      -- Route general vim.notify messages through fidget's themed surface,
      -- alongside the LSP progress display.
      vim.notify = require("fidget").notify
    end,
  },
}
