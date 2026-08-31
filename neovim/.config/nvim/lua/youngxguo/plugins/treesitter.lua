return {
  {
    "nvim-treesitter/nvim-treesitter",
    -- `main` is the branch that supports Neovim 0.12; `master` is frozen at 0.11.
    branch = "main",
    lazy = false, -- `main` does not support lazy-loading
    build = ":TSUpdate",
    config = function()
      local ts = require("nvim-treesitter")
      local available = ts.get_available()

      -- `main` dropped the module system, so highlighting is started per buffer.
      -- Install the parser first if we don't have it yet; install() returns
      -- immediately for parsers that are already there.
      vim.api.nvim_create_autocmd("FileType", {
        callback = function(ev)
          local lang = vim.treesitter.language.get_lang(ev.match)
          if not lang or not vim.list_contains(available, lang) then
            return
          end
          ts.install({ lang }):await(vim.schedule_wrap(function()
            if vim.api.nvim_buf_is_valid(ev.buf) then
              pcall(vim.treesitter.start, ev.buf, lang)
            end
          end))
        end,
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
