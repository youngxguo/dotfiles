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

local solarized_ui = {
  base03 = "#002b36",
  base02 = "#073642",
  base01 = "#586e75",
  base0 = "#839496",
  base1 = "#93a1a1",
  base2 = "#eee8d5",
  green = "#859900",
  yellow = "#b58900",
  orange = "#cb4b16",
  red = "#dc322f",
  blue = "#268bd2",
  cyan = "#2aa198",
}

local function apply_diff_highlights()
  -- Background-only diff colors preserve syntax highlighting in Diffview buffers.
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#003a20" })
  vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#3a0a10" })
  vim.api.nvim_set_hl(0, "DiffChange", { bg = "#002a40" })
  vim.api.nvim_set_hl(0, "DiffText", { bg = "#004a55" })
end

local function apply_ui_highlights()
  vim.api.nvim_set_hl(0, "StatusLine", { fg = solarized_ui.base1, bg = solarized_ui.base03 })
  vim.api.nvim_set_hl(0, "StatusLineNC", { fg = solarized_ui.base01, bg = solarized_ui.base03 })
  vim.api.nvim_set_hl(0, "TabLine", { fg = solarized_ui.base0, bg = solarized_ui.base03 })
  vim.api.nvim_set_hl(0, "TabLineSel", { fg = solarized_ui.base03, bg = solarized_ui.blue, bold = true })
  vim.api.nvim_set_hl(0, "TabLineFill", { bg = solarized_ui.base03 })
  vim.api.nvim_set_hl(0, "WinSeparator", { fg = solarized_ui.base01, bg = solarized_ui.base03 })
  vim.api.nvim_set_hl(0, "VertSplit", { fg = solarized_ui.base01, bg = solarized_ui.base03 })
  vim.api.nvim_set_hl(0, "SignColumn", { fg = solarized_ui.base1 })
  vim.api.nvim_set_hl(0, "LineNr", { fg = solarized_ui.base01 })
  vim.api.nvim_set_hl(0, "CursorLineNr", { fg = solarized_ui.cyan, bg = solarized_ui.base02, bold = true })

  local fidget_bg = solarized_ui.base02
  vim.api.nvim_set_hl(0, "YoungFidgetNormal", { fg = solarized_ui.base1, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetGroup", { fg = solarized_ui.blue, bg = fidget_bg, bold = true })
  vim.api.nvim_set_hl(0, "YoungFidgetIcon", { fg = solarized_ui.cyan, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetProgress", { fg = solarized_ui.yellow, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetDone", { fg = solarized_ui.green, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetInfo", { fg = solarized_ui.cyan, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetWarn", { fg = solarized_ui.orange, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetError", { fg = solarized_ui.red, bg = fidget_bg, bold = true })
  vim.api.nvim_set_hl(0, "YoungFidgetDebug", { fg = solarized_ui.base01, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetSeparator", { fg = solarized_ui.base01, bg = fidget_bg })
end

local function bufferline_highlights()
  return {
    fill = { bg = solarized_ui.base03 },
    background = { fg = solarized_ui.base0, bg = solarized_ui.base03 },
    buffer_visible = { fg = solarized_ui.base0, bg = solarized_ui.base03 },
    buffer_selected = { fg = solarized_ui.base03, bg = solarized_ui.blue, bold = true, italic = false },
    indicator_selected = { fg = solarized_ui.base03, bg = solarized_ui.blue },
    tab = { fg = solarized_ui.base0, bg = solarized_ui.base03 },
    tab_selected = { fg = solarized_ui.base03, bg = solarized_ui.blue, bold = true },
    tab_separator = { fg = solarized_ui.base02, bg = solarized_ui.base03 },
    tab_separator_selected = { fg = solarized_ui.blue, bg = solarized_ui.blue },
    separator = { fg = solarized_ui.base02, bg = solarized_ui.base03 },
    separator_visible = { fg = solarized_ui.base02, bg = solarized_ui.base03 },
    separator_selected = { fg = solarized_ui.blue, bg = solarized_ui.blue },
    modified = { fg = solarized_ui.base2, bg = solarized_ui.base03 },
    modified_visible = { fg = solarized_ui.base2, bg = solarized_ui.base03 },
    modified_selected = { fg = solarized_ui.base03, bg = solarized_ui.blue },
    duplicate = { fg = solarized_ui.base01, bg = solarized_ui.base03, italic = false },
    duplicate_visible = { fg = solarized_ui.base01, bg = solarized_ui.base03, italic = false },
    duplicate_selected = { fg = solarized_ui.base02, bg = solarized_ui.blue, bold = true, italic = false },
  }
end

-- Initialize vim.lsp.config['*'] before plugins load (blink.cmp v1.x reads it)
if vim.lsp.config then
  vim.lsp.config('*', {})
end

require("lazy").setup({
  {
    "ibhagwan/fzf-lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      "telescope",
      defaults = {
        formatter = "path.dirname_first",
      },
      winopts = {
        height = 0.95,
        width = 0.95,
        preview = {
          layout = "horizontal",
          horizontal = "right:55%",
        },
      },
      fzf_opts = {
        ["--layout"] = "reverse",
      },
      files = {
        hidden = true,
        rg_opts = [[--color=never --hidden --files -g "!.git" -g "!node_modules/**" -g "!bazel-out/**" -g "!bazel-bin/**" -g "!bazel-testlogs/**" -g "!bazel-applied*/**" -g "!lcov-report/**" -g "!map_tiles/**" -g "!*.generated" -g "!data/py/**"]],
        fd_opts = [[--color=never --hidden --type f --type l --exclude .git --exclude node_modules --exclude bazel-out --exclude bazel-bin --exclude bazel-testlogs --exclude bazel-applied* --exclude lcov-report --exclude map_tiles --exclude data/py --exclude *.generated]],
      },
      grep = {
        rg_opts = [[--column --line-number --no-heading --color=always --smart-case --max-columns=4096 --glob "!.git" --glob "!node_modules/**" --glob "!bazel-out/**" --glob "!bazel-bin/**" --glob "!bazel-testlogs/**" --glob "!bazel-applied*/**" --glob "!lcov-report/**" --glob "!map_tiles/**" --glob "!*.generated" --glob "!data/py/**" -e]],
      },
    },
  },
  {
    "maxmx03/solarized.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      transparent = {
        enabled = vim.env.NVIM_TRANSPARENT ~= "0",
        normal = true,
        normalfloat = true,
        nvimtree = true,
        telescope = true,
        lazy = true,
      },
      palette = "solarized",
      variant = "winter",
    },
    config = function(_, opts)
      vim.o.termguicolors = true
      vim.o.background = "dark"
      require("solarized").setup(opts)
      vim.cmd.colorscheme("solarized")
      apply_diff_highlights()
      apply_ui_highlights()
    end,
  },
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter").setup({
        ensure_installed = { "javascript", "typescript", "tsx", "lua", "c", "cpp" },
        auto_install = true,
      })
    end,
  },
  { "neovim/nvim-lspconfig" },
  { "stevearc/conform.nvim", lazy = false },
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
  },
  {
    "saghen/blink.cmp",
    version = "1.*",
    opts = {
      keymap = {
        preset = "default",
        ["<Up>"] = { "select_prev", "fallback" },
        ["<Down>"] = { "select_next", "fallback" },
        ["<Tab>"] = { "show", "fallback" },
        ["<CR>"] = { "accept", "fallback" },
      },
      completion = {
        documentation = { auto_show = true },
      },
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
  { "lukas-reineke/indent-blankline.nvim" },
  {
    "karb94/neoscroll.nvim",
    opts = {
      duration_multiplier = 0.5,
    },
  },

  {
    "nvim-treesitter/nvim-treesitter-context",
    lazy = false,
    main = "treesitter-context",
    opts = {
      enable = true,
      max_lines = 6,
      multiline_threshold = 1,
      trim_scope = "outer",
      mode = "topline",
      separator = nil,
      zindex = 20,
    },
    keys = {
      { "<leader>ut", "<cmd>TSContext toggle<CR>", desc = "Toggle sticky context" },
    },
  },
  {
    "Bekaboo/dropbar.nvim",
    event = { "BufReadPost", "BufNewFile" },
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {},
    keys = {
      {
        "<leader>;",
        function()
          require("dropbar.api").pick()
        end,
        desc = "Pick breadcrumb",
      },
      {
        "[;",
        function()
          require("dropbar.api").goto_context_start()
        end,
        desc = "Context start",
      },
      {
        "];",
        function()
          require("dropbar.api").select_next_context()
        end,
        desc = "Next context",
      },
    },
  },
  { "lewis6991/gitsigns.nvim" },
  {
    "akinsho/git-conflict.nvim",
    version = "*",
    opts = {
      highlights = {
        incoming = "DiffAdd",
        current = "DiffChange",
        ancestor = "DiffText",
      },
    },
  },
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      disable_netrw = true,
      filters = { dotfiles = false },
      update_focused_file = { enable = true },
    },
  },
  { "nvim-tree/nvim-web-devicons" },
  { "rebelot/heirline.nvim" },
  {
    "akinsho/bufferline.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      highlights = bufferline_highlights(),
      options = {
        themable = false,
        diagnostics = "nvim_lsp",
        diagnostics_indicator = function(_, _, diagnostics_dict)
          local s = " "
          for e, n in pairs(diagnostics_dict) do
            local sym = e == "error" and " "
              or (e == "warning" and " " or " ")
            s = s .. n .. sym
          end
          return s
        end,
        show_close_icon = false,
        show_buffer_close_icons = false,
        separator_style = "thin",
      },
    },
  },
  { "numToStr/Comment.nvim", opts = {} },
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {
      check_ts = true,
      map_cr = false,
    },
  },
  { "tpope/vim-fugitive" },
  {
    "NeogitOrg/neogit",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "sindrets/diffview.nvim",
      "ibhagwan/fzf-lua",
      "nvim-tree/nvim-web-devicons",
    },
    opts = {
      integrations = {
        telescope = false,
        diffview = true,
        fzf_lua = true,
      },
    },
  },
  {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      use_icons = true,
      file_panel = {
        win_config = {
          width = 60,
        },
      },
      hooks = {
        diff_buf_read = function(bufnr)
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(bufnr) then return end
            local ft = vim.bo[bufnr].filetype
            if not ft or ft == "" then
              local name = vim.api.nvim_buf_get_name(bufnr)
              local clean = name:gsub("^diffview://.-/%.git/.-/", "")
              ft = vim.filetype.match({ buf = bufnr, filename = clean })
              if ft then
                vim.bo[bufnr].filetype = ft
              end
            end
            if ft and ft ~= "" then
              pcall(vim.treesitter.start, bufnr, ft)
            end
          end)
        end,
      },
    },
  },
  {
    "folke/noice.nvim",
    event = "VeryLazy",
    dependencies = {
      "MunifTanjim/nui.nvim",
    },
    opts = {
      cmdline = {
        view = "cmdline_popup",
      },
      messages = { enabled = false },
      popupmenu = { enabled = false },
      notify = { enabled = false },
      lsp = {
        override = {
          ["vim.lsp.util.convert_input_to_markdown_lines"] = true,
          ["vim.lsp.util.stylize_markdown"] = true,
        },
        progress = { enabled = false },
      },
    },
  },
  {
    "pwntester/octo.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "ibhagwan/fzf-lua",
      "nvim-tree/nvim-web-devicons",
    },
    cmd = "Octo",
    opts = {
      default_merge_method = "squash",
      picker = "fzf-lua",
    },
  },
}, {
  rocks = {
    enabled = false,
  },
})
