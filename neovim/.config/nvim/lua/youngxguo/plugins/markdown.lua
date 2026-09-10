return {
  {
    "3rd/image.nvim",
    -- Only Octo PR/issue buffers render images; plain Markdown stays text.
    ft = "octo",
    opts = {
      backend = "kitty",
      processor = "magick_cli",
      integrations = {
        markdown = {
          enabled = true,
          download_remote_images = true,
          filetypes = { "octo" },
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

      -- Screenshots attached to private-repo PRs live at
      -- github.com/user-attachments/... and 404 without credentials, while
      -- image.nvim downloads with a bare `curl`. Fetch github.com URLs with the
      -- gh token instead. curl drops the Authorization header when the redirect
      -- lands on S3, and the header goes in via stdin so it never shows in `ps`.
      local gh_token
      local function github_token()
        if gh_token == nil then
          local lines = vim.fn.systemlist({ "gh", "auth", "token" })
          gh_token = (vim.v.shell_error == 0 and lines[1] ~= nil and lines[1] ~= "") and lines[1] or false
        end
        return gh_token or nil
      end

      local github_downloads = {}
      local function download_from_github(url, options, callback)
        local function deliver(path)
          local ok, img = pcall(image.from_file, path, options)
          callback(ok and img or nil)
        end
        local cached = github_downloads[url]
        if cached then
          deliver(cached)
          return
        end
        local path = vim.fn.tempname() .. ".png"
        vim.system({ "curl", "-L", "-s", "-f", "-o", path, "-K", "-", url }, {
          stdin = ('header = "Authorization: token %s"\n'):format(github_token()),
        }, function(result)
          vim.schedule(function()
            if result.code ~= 0 then
              callback(nil)
              return
            end
            github_downloads[url] = path
            deliver(path)
          end)
        end)
      end

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
        if host == "github.com" and github_token() then
          download_from_github(url, options, callback)
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
