-- CodeDiff's inline view draws deleted lines as virt_lines, and Neovim cannot
-- wrap virtual lines (codediff.nvim#50). In a wrapped window the added lines
-- wrap while the deleted ones run off the edge. Split each long deleted line
-- into rows that break like the window's real lines: after a 'breakat'
-- character under 'linebreak', with the line's indent repeated under
-- 'breakindent'. The originals are kept so a resize or 'nowrap' can reflow.
local M = {}

-- Same name, so the same namespace codediff renders into.
local ns = vim.api.nvim_create_namespace("codediff-inline")
-- Neovim keeps at least this much text beside a 'breakindent' indent
-- ('breakindentopt' min:20).
local BREAKINDENT_MIN_TEXT = 20

local state = {} -- buf -> { marks = { [id] = details }, key = layout key }

local function text_window(buf)
  local current = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_get_tabpage(win) == current then
      return win
    end
  end
end

-- codediff ends every deleted line with a run of spaces in the line's
-- background group, which stands in for hl_eol.
local function split_padding(chunks)
  local last = chunks[#chunks]
  if #chunks > 1 and last[1]:match("^ +$") then
    return vim.list_slice(chunks, 1, #chunks - 1), last[2]
  end
  return chunks, nil
end

local function cells(chunks, tabstop)
  local result, col = {}, 0
  for _, chunk in ipairs(chunks) do
    for char in chunk[1]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      if char == "\t" then
        local width = tabstop - col % tabstop
        for _ = 1, width do
          table.insert(result, { " ", chunk[2], 1, tab = true })
        end
        col = col + width
      else
        local width = char:byte() < 128 and 1 or vim.api.nvim_strwidth(char)
        table.insert(result, { char, chunk[2], width })
        col = col + width
      end
    end
  end
  return result, col
end

local function row_chunks(row, indent, pad_hl, width)
  local chunks, used = {}, indent
  for _, cell in ipairs(row) do
    local last = chunks[#chunks]
    if last and last[2] == cell[2] then
      last[1] = last[1] .. cell[1]
    else
      table.insert(chunks, { cell[1], cell[2] })
    end
    used = used + cell[3]
  end
  if indent > 0 then
    table.insert(chunks, 1, { string.rep(" ", indent), pad_hl or row[1][2] })
  end
  if pad_hl and used < width then
    table.insert(chunks, { string.rep(" ", width - used), pad_hl })
  end
  return chunks
end

local function wrap_line(chunks, width, opts)
  local content, pad_hl = split_padding(chunks)
  local line, total = cells(content, opts.tabstop)
  if total <= width then
    return { chunks }
  end

  local indent = 0
  if opts.breakindent then
    for _, cell in ipairs(line) do
      if cell[1] ~= " " then
        break
      end
      indent = indent + cell[3]
    end
    indent = math.max(0, math.min(indent, width - BREAKINDENT_MIN_TEXT))
  end

  local rows, start = {}, 1
  while start <= #line do
    local row_indent = #rows > 0 and indent or 0
    local available = width - row_indent
    local stop, used = start - 1, 0
    while stop < #line and used + line[stop + 1][3] <= available do
      stop = stop + 1
      used = used + line[stop][3]
    end
    stop = math.max(stop, start)
    if opts.linebreak and stop < #line then
      for i = stop, start + 1, -1 do
        local cell = line[i]
        if opts.breakat[cell.tab and "\t" or cell[1]] then
          stop = i
          break
        end
      end
    end
    table.insert(rows, row_chunks(vim.list_slice(line, start, stop), row_indent, pad_hl, width))
    start = stop + 1
  end
  return rows
end

local function layout(win, buf)
  if not (win and vim.wo[win].wrap) then
    return nil
  end
  local info = vim.fn.getwininfo(win)[1]
  local breakat = {}
  for char in vim.o.breakat:gmatch(".") do
    breakat[char] = true
  end
  return {
    width = info.width - info.textoff,
    tabstop = vim.bo[buf].tabstop,
    linebreak = vim.wo[win].linebreak,
    breakindent = vim.wo[win].breakindent,
    breakat = breakat,
  }
end

local function layout_key(opts)
  if not opts then
    return "nowrap"
  end
  return table.concat({ opts.width, opts.tabstop, tostring(opts.linebreak), tostring(opts.breakindent), vim.o.breakat }, ":")
end

function M.reflow(buf)
  local entry = state[buf]
  if not entry or not vim.api.nvim_buf_is_valid(buf) then
    state[buf] = nil
    return
  end
  local win = text_window(buf)
  if not win then
    -- Nothing shows the buffer here; its window decides when it comes back.
    return
  end
  local opts = layout(win, buf)
  local key = layout_key(opts)
  if key == entry.key or (opts and opts.width < 1) then
    return
  end
  entry.key = key

  for id, details in pairs(entry.marks) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, id, {})
    if #pos == 0 then
      entry.marks[id] = nil
    else
      local virt_lines = details.virt_lines
      if opts then
        virt_lines = {}
        for _, line in ipairs(details.virt_lines) do
          vim.list_extend(virt_lines, wrap_line(line, opts.width, opts))
        end
      end
      vim.api.nvim_buf_set_extmark(buf, ns, pos[1], pos[2], {
        id = id,
        virt_lines = virt_lines,
        virt_lines_above = details.virt_lines_above,
        virt_lines_overflow = details.virt_lines_overflow,
        priority = details.priority,
      })
    end
  end
end

local function capture(buf)
  local marks = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true, type = "virt_lines" })
  for _, mark in ipairs(extmarks) do
    marks[mark[1]] = mark[4]
  end
  state[buf] = { marks = marks, key = "nowrap" }
end

function M.setup()
  local inline = require("codediff.ui.inline")
  local render = inline.render_inline_diff
  inline.render_inline_diff = function(bufnr, ...)
    local result = { render(bufnr, ...) }
    if vim.api.nvim_buf_is_valid(bufnr) then
      capture(bufnr)
      M.reflow(bufnr)
    end
    return unpack(result)
  end

  local group = vim.api.nvim_create_augroup("codediff_inline_wrap", { clear = true })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, win in ipairs(vim.v.event.windows or {}) do
        if vim.api.nvim_win_is_valid(win) then
          M.reflow(vim.api.nvim_win_get_buf(win))
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "wrap", "linebreak", "breakindent", "tabstop" },
    callback = function()
      M.reflow(vim.api.nvim_get_current_buf())
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      state[args.buf] = nil
    end,
  })
end

return M
