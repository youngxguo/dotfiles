-- render-markdown.nvim draws pipe tables with padded cells and virtual
-- borders. Under 'wrap', neovim breaks the line at the raw-text position,
-- so any table wider than the window renders as scattered borders (see the
-- plugin's doc/limitations.md). There is no wrap-compatible fix, so turn
-- wrap off for a window only when its buffer holds a table that would not
-- fit. Prose-only documents keep wrapping.

local M = {}

local FILETYPES = { markdown = true, octo = true }
local CELL_PADDING = 1 -- render-markdown pipe_table.padding default

local function is_table_row(line)
  return line:match("^%s*|") ~= nil
end

-- Rendered width of a padded table: each column is as wide as its widest
-- cell plus padding on both sides, with one border character per edge.
local function table_width(rows)
  local widths = {}
  for _, row in ipairs(rows) do
    local col = 0
    for cell in row:gmatch("|([^|]*)") do
      col = col + 1
      local text = vim.trim(cell)
      widths[col] = math.max(widths[col] or 0, vim.fn.strdisplaywidth(text))
    end
  end
  local total = 1
  for _, width in ipairs(widths) do
    total = total + width + 2 * CELL_PADDING + 1
  end
  return total
end

local function widest_table(buf)
  local widest = 0
  local rows = {}
  local function flush()
    if #rows >= 2 then
      widest = math.max(widest, table_width(rows))
    end
    rows = {}
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if is_table_row(line) then
      rows[#rows + 1] = line
    else
      flush()
    end
  end
  flush()
  return widest
end

local function text_width(win)
  local info = vim.fn.getwininfo(win)[1]
  return info and (info.width - info.textoff) or vim.api.nvim_win_get_width(win)
end

local function apply(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not FILETYPES[vim.bo[buf].filetype] then
    return
  end
  local widest = widest_table(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and not vim.wo[win].diff then
      vim.wo[win].wrap = widest <= text_width(win)
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("markdown_table_wrap", { clear = true })
  vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "BufWritePost", "TextChanged", "InsertLeave" }, {
    group = group,
    callback = function(args)
      apply(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if FILETYPES[vim.bo[buf].filetype] then
          apply(buf)
        end
      end
    end,
  })
end

return M
