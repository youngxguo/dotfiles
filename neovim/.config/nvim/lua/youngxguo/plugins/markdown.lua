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

      -- Comparison tables put several images on one buffer line, and Octo
      -- wraps long lines. image.nvim anchors each image at its own column
      -- with a full-width size cap and its own padding block, so siblings
      -- overlap, the gap below doubles, and the picture lands on the wrapped
      -- continuation row. Tile siblings across the line at one shared height,
      -- reserve padding once, and start below the last wrapped row.
      local row_groups = {}

      local function tile_with_row_siblings(img, url, options)
        if not img or img.octo_tiled or not options or not options.buffer then
          return
        end
        local row = tonumber((options.id or ""):match("^%d+:%d+:(%d+):"))
        if not row or not vim.api.nvim_buf_is_valid(options.buffer) then
          return
        end
        local line = vim.api.nvim_buf_get_lines(options.buffer, row, row + 1, false)[1] or ""
        local urls = {}
        for found in line:gmatch("!%[[^%]]*%]%(([^%)%s]+)") do
          urls[#urls + 1] = found
        end
        if #urls < 2 then
          return
        end
        local index
        for i, found in ipairs(urls) do
          if found == url then
            index = i
            break
          end
        end
        if not index then
          return
        end

        local key = options.buffer .. ":" .. row
        local group = row_groups[key] or { images = {} }
        row_groups[key] = group
        group.count = #urls
        group.line = line
        group.images[index] = img
        img.octo_tiled = true
        img.with_virtual_padding = index == 1

        local original_render = img.render
        img.render = function(self, geometry)
          if geometry then
            self.geometry = vim.tbl_deep_extend("force", self.geometry, geometry)
          end
          local win = self.window
          local term = require("image/utils/term").get_size()
          if not win or not vim.api.nvim_win_is_valid(win) or not term then
            return original_render(self)
          end
          local info = vim.fn.getwininfo(win)[1]
          local usable = math.max(1, info.width - info.textoff)
          local tile = math.max(1, math.floor(usable / group.count) - 1)
          local height = math.floor(info.height * (opts.max_height_window_percentage or 100) / 100)
          for _, sibling in pairs(group.images) do
            local aspect = sibling.image_width / sibling.image_height
            local natural = math.floor(tile * term.cell_width / aspect / term.cell_height)
            height = math.max(1, math.min(height, natural))
          end
          self.geometry.x = (index - 1) * (tile + 1)
          self.geometry.width = 0
          self.geometry.height = height
          local wrapped_rows = math.max(1, math.ceil(vim.fn.strdisplaywidth(group.line) / usable))
          self.render_offset_top = wrapped_rows - 1
          return original_render(self)
        end

        -- A later sibling can lower the shared height; bring the others down to it.
        for _, sibling in pairs(group.images) do
          if sibling ~= img and sibling.is_rendered then
            pcall(sibling.render, sibling)
          end
        end
      end

      local github_downloads = {}
      local function download_from_github(url, options, callback)
        local function deliver(path)
          local ok, img = pcall(image.from_file, path, options)
          img = ok and img or nil
          tile_with_row_siblings(img, url, options)
          callback(img)
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
        original_from_url(url, options, function(img)
          tile_with_row_siblings(img, url, options)
          callback(img)
        end)
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
