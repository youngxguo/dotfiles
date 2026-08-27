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
      local image = require("image")
      image.setup(opts)

      -- ImageMagick's SVG parser fails on common badge images, and image.nvim's
      -- asynchronous error escapes its per-image pcall. Skip those decorative
      -- images so one badge cannot prevent bitmap screenshots from rendering.
      local original_from_url = image.from_url
      image.from_url = function(url, options, callback)
        local normalized_url = url:lower()
        local host = normalized_url:match("^https?://([^/]+)")
        local is_svg = normalized_url:match("%.svg$") or normalized_url:match("%.svg[?#]")
        local is_badge = host == "img.shields.io" or host == "badgen.net"
        if is_svg or is_badge then
          callback(nil)
          return
        end
        original_from_url(url, options, callback)
      end

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
