return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    build = ":TSUpdate",
    dependencies = {
      -- Pinned to master to match the classic nvim-treesitter API.
      { "nvim-treesitter/nvim-treesitter-textobjects", branch = "master" },
    },
    config = function()
      -- NOTE: the config table must go to nvim-treesitter.configs; the top-level
      -- require("nvim-treesitter").setup() takes no arguments and silently drops it.
      require("nvim-treesitter.configs").setup({
        ensure_installed = { "javascript", "typescript", "tsx", "lua", "c", "cpp" },
        auto_install = true,
        highlight = { enable = true },
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = "<C-space>",
            node_incremental = "<C-space>",
            node_decremental = "<bs>",
            scope_incremental = false,
          },
        },
        textobjects = {
          select = {
            enable = true,
            lookahead = true,
            keymaps = {
              ["af"] = "@function.outer",
              ["if"] = "@function.inner",
              ["ac"] = "@class.outer",
              ["ic"] = "@class.inner",
              ["aa"] = "@parameter.outer",
              ["ia"] = "@parameter.inner",
            },
          },
          move = {
            enable = true,
            set_jumps = true,
            goto_next_start = { ["]f"] = "@function.outer" },
            goto_previous_start = { ["[f"] = "@function.outer" },
          },
        },
      })
    end,
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
}
