local theme = require("youngxguo.theme")

return {
  { "nvim-tree/nvim-web-devicons", lazy = true },

  {
    "rebelot/heirline.nvim",
    config = function()
      require("youngxguo.statusline")
    end,
  },

  {
    "akinsho/bufferline.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {
      highlights = theme.bufferline_highlights(),
      options = {
        themable = false,
        diagnostics = "nvim_lsp",
        diagnostics_indicator = function(_, _, diagnostics_dict)
          local s = " "
          for e, n in pairs(diagnostics_dict) do
            local sym = e == "error" and " "
              or (e == "warning" and " " or " ")
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

  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    cmd = { "NvimTreeToggle", "NvimTreeFindFile", "NvimTreeOpen", "NvimTreeFocus" },
    keys = {
      { "<leader>b", "<cmd>NvimTreeToggle<CR>", silent = true, desc = "Toggle file tree" },
    },
    opts = {
      disable_netrw = true,
      filters = { dotfiles = false },
      update_focused_file = { enable = true },
    },
  },

  {
    "Bekaboo/dropbar.nvim",
    event = { "BufReadPost", "BufNewFile" },
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = {},
    keys = {
      { "<leader>;", function() require("dropbar.api").pick() end, desc = "Pick breadcrumb" },
      { "[;", function() require("dropbar.api").goto_context_start() end, desc = "Context start" },
      { "];", function() require("dropbar.api").select_next_context() end, desc = "Next context" },
    },
  },

  { "lukas-reineke/indent-blankline.nvim", main = "ibl", event = { "BufReadPost", "BufNewFile" }, opts = {} },

  {
    "karb94/neoscroll.nvim",
    event = "VeryLazy",
    opts = {
      duration_multiplier = 0.5,
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
}
