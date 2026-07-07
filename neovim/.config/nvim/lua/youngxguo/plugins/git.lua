return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      update_debounce = 100,
      watch_gitdir = {
        follow_files = true,
      },
      signs = {
        add = { text = "+" },
        change = { text = "~" },
        delete = { text = "_" },
        topdelete = { text = "^" },
        changedelete = { text = "~" },
      },
      current_line_blame = true,
      current_line_blame_opts = {
        delay = 300,
      },
    },
  },

  {
    "akinsho/git-conflict.nvim",
    version = "*",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      highlights = {
        incoming = "DiffAdd",
        current = "DiffChange",
        ancestor = "DiffText",
      },
    },
  },

  {
    "tpope/vim-fugitive",
    cmd = { "Git", "Gdiffsplit", "Gvdiffsplit", "Gread", "Gwrite", "Gedit", "Gclog", "GBrowse" },
  },

  {
    "NeogitOrg/neogit",
    cmd = "Neogit",
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
    cmd = {
      "DiffviewOpen",
      "DiffviewFileHistory",
      "DiffviewClose",
      "DiffviewToggleFiles",
      "DiffviewFocusFiles",
      "DiffviewRefresh",
    },
    keys = {
      -- Working-tree diff swapped to codediff.nvim (inline). Diffview stays for
      -- history (<leader>gl) and Neogit's integration.
      { "<leader>gl", function() require("youngxguo.diffview_nav").open_history() end, desc = "Git history (Diffview)" },
      { "<leader>gL", function() require("fzf-lua").git_bcommits() end, desc = "Git log current file" },
    },
    opts = {
      use_icons = true,
      hooks = {
        diff_buf_read = function(bufnr)
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(bufnr) then
              return
            end
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

  -- Primary working-tree diff (replaced diffview on <leader>gd).
  {
    "esmuellert/codediff.nvim",
    cmd = "CodeDiff",
    keys = {
      { "<leader>gd", function() require("youngxguo.codediff_nav").open_diff() end, desc = "Git diff (CodeDiff)" },
    },
    opts = {
      diff = {
        layout = "inline", -- fallback; codediff_nav picks per-open by width
        compute_moves = false,
      },
      explorer = {
        width = 32,
        view_mode = "tree",
        auto_refresh = true,
        auto_open_on_cursor = true,
      },
      keymaps = {
        view = {
          next_file = "<Tab>",
          prev_file = "<S-Tab>",
        },
      },
    },
    config = function(_, opts)
      require("youngxguo.codediff_perf").setup(opts)
    end,
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
}
