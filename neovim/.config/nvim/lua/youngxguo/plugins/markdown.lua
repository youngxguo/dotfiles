return {
  {
    "3rd/image.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      backend = "kitty",
      processor = "magick_cli",
      integrations = {
        markdown = {
          enabled = true,
          download_remote_images = true,
          filetypes = { "markdown", "octo" },
        },
        asciidoc = { enabled = false },
        typst = { enabled = false },
        neorg = { enabled = false },
        syslang = { enabled = false },
        html = { enabled = false },
        css = { enabled = false },
        org = { enabled = false },
      },
      max_width_window_percentage = 90,
      max_height_window_percentage = 80,
    },
    config = function(_, opts)
      require("image").setup(opts)

      -- Octo enters its buffer before assigning the `octo` filetype, while
      -- image.nvim discovers Markdown documents on BufWinEnter. Replay that
      -- event after Octo has populated the issue/PR body and comments.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("octo_images", { clear = true }),
        pattern = "octo",
        callback = function(event)
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(event.buf) then
              vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = event.buf, modeline = false })
            end
          end)
        end,
      })
    end,
  },

  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = "markdown",
    dependencies = {
      "nvim-treesitter/nvim-treesitter",
      "nvim-tree/nvim-web-devicons",
    },
    opts = {},
  },
}
