-- Run from the repo root: nvim --headless --clean -l neovim/tests/codediff_wrap.lua
-- Needs codediff.nvim installed by lazy.nvim.
vim.opt.runtimepath:append(vim.fn.getcwd() .. "/neovim")
vim.opt.runtimepath:append(vim.fn.stdpath("data") .. "/lazy/codediff.nvim")
vim.o.columns = 120
vim.o.lines = 20
require("codediff.config").setup({})
require("youngxguo.codediff_wrap").setup()
local inline = require("codediff.ui.inline")

local old = "\tlocal deleted = 'the old text that is much too long to fit'"
local new = "\tlocal added = 'the new text that is much too long to fit'"
vim.cmd("vsplit")
vim.api.nvim_win_set_width(0, 40)
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "top", new, "bottom" })
vim.bo.tabstop = 4
vim.wo.wrap = true
vim.wo.linebreak = true
vim.wo.breakindent = true
local diff = {
  changes = {
    { original = { start_line = 2, end_line = 3 }, modified = { start_line = 2, end_line = 3 } },
  },
}
inline.render_inline_diff(buf, diff, { "top", old, "bottom" }, { "top", new, "bottom" })

local function screen()
  vim.cmd("redraw")
  local rows = {}
  for r = 1, 8 do
    local row = {}
    for c = 1, vim.api.nvim_win_get_width(0) do
      row[c] = vim.fn.screenstring(r, c)
    end
    rows[r] = (table.concat(row):gsub("%s+$", ""))
  end
  return rows
end

local rows = screen()
-- The deleted line wraps like the added one: at a word boundary, with the
-- continuation indented to the line's indent.
assert(vim.deep_equal(rows, {
  "top",
  "    local deleted = 'the old text that",
  "    is much too long to fit'",
  "    local added = 'the new text that is",
  "    much too long to fit'",
  "bottom",
  "~",
  "~",
}), vim.inspect(rows))

-- 'nowrap' restores the single overflowing deleted line.
vim.wo.wrap = false
rows = screen()
assert(vim.startswith(rows[2], "    local deleted"), vim.inspect(rows))
assert(rows[3]:match("^    local added"), vim.inspect(rows))

-- A wider window reflows to fewer rows.
vim.wo.wrap = true
vim.api.nvim_win_set_width(0, 70)
-- WinResized fires from the main loop, which a script never yields to.
require("youngxguo.codediff_wrap").reflow(buf)
rows = screen()
assert(rows[2] == "    local deleted = 'the old text that is much too long to fit'", vim.inspect(rows))
assert(rows[3] == "    local added = 'the new text that is much too long to fit'", vim.inspect(rows))

-- A reflow from a tab that does not show the buffer leaves its rows alone.
local ns = require("codediff.ui.inline").ns_inline
local function virt_rows()
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true, type = "virt_lines" })
  return #marks[1][4].virt_lines
end
vim.api.nvim_win_set_width(0, 40)
require("youngxguo.codediff_wrap").reflow(buf)
assert(virt_rows() == 2, virt_rows())
vim.cmd("tabnew")
require("youngxguo.codediff_wrap").reflow(buf)
assert(virt_rows() == 2, virt_rows())
vim.cmd("tabclose")

-- Wiping the buffer drops its state.
vim.cmd("enew")
vim.api.nvim_buf_delete(buf, { force = true })
local state
for i = 1, 100 do
  local name, value = debug.getupvalue(require("youngxguo.codediff_wrap").reflow, i)
  if not name then
    break
  end
  if name == "state" then
    state = value
  end
end
assert(state and next(state) == nil, vim.inspect(state))
print("ok")
