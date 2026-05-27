return {
  "ibhagwan/fzf-lua",
  dependencies = { "nvim-tree/nvim-web-devicons" },
  -- Loaded on first use: the keys below, plus any require("fzf-lua") call
  -- (the <C-p> map, LSP keymaps, command palette) which lazy.nvim resolves.
  cmd = "FzfLua",
  keys = {
    { "<leader><leader>", function() require("fzf-lua").commands() end, desc = "FzfLua commands" },
    { "<leader>pf", function() require("fzf-lua").files() end, desc = "FzfLua find files" },
    { "<leader>pg", function() require("fzf-lua").git_files() end, desc = "FzfLua git files" },
    { "<leader>/", function() require("fzf-lua").live_grep({ hidden = true }) end, desc = "FzfLua live grep (project)" },
    {
      "<leader>/",
      function()
        local fzf = require("fzf-lua")
        fzf.live_grep({ hidden = true, search = fzf.utils.get_visual_selection() })
      end,
      mode = "v",
      desc = "FzfLua live grep (visual selection)",
    },
    { "<leader>po", function() require("fzf-lua").lsp_document_symbols() end, desc = "FzfLua document symbols" },
    {
      "<leader>ps",
      function()
        local search = vim.fn.input("Grep > ")
        if search and search ~= "" then
          require("fzf-lua").grep({ search = search })
        end
      end,
      desc = "FzfLua grep prompt",
    },
  },
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
      ["--no-hscroll"] = true,
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
}
