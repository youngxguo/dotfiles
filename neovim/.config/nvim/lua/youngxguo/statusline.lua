local ok, heirline = pcall(require, "heirline")
if not ok then
  return
end

local has_devicons, devicons = pcall(require, "nvim-web-devicons")

local mode_names = {
  n = "NORMAL",
  no = "O-PEND",
  nov = "O-PEND",
  noV = "O-PEND",
  ["no\22"] = "O-PEND",
  niI = "NORMAL",
  niR = "NORMAL",
  niV = "NORMAL",
  nt = "NORMAL",
  v = "VISUAL",
  vs = "VISUAL",
  V = "V-LINE",
  Vs = "V-LINE",
  ["\22"] = "V-BLOCK",
  ["\22s"] = "V-BLOCK",
  s = "SELECT",
  S = "S-LINE",
  ["\19"] = "S-BLOCK",
  i = "INSERT",
  ic = "INSERT",
  ix = "INSERT",
  R = "REPLACE",
  Rc = "REPLACE",
  Rx = "REPLACE",
  Rv = "V-REPL",
  c = "COMMAND",
  cv = "EX",
  ce = "EX",
  r = "PROMPT",
  rm = "MORE",
  ["r?"] = "CONFIRM",
  ["!"] = "SHELL",
  t = "TERMINAL",
}

local mode_highlights = {
  n = "DiagnosticInfo",
  no = "DiagnosticInfo",
  niI = "DiagnosticInfo",
  niR = "DiagnosticInfo",
  niV = "DiagnosticInfo",
  nt = "DiagnosticInfo",
  v = "Visual",
  vs = "Visual",
  V = "Visual",
  Vs = "Visual",
  ["\22"] = "Visual",
  ["\22s"] = "Visual",
  s = "Type",
  S = "Type",
  ["\19"] = "Type",
  i = "String",
  ic = "String",
  ix = "String",
  R = "WarningMsg",
  Rc = "WarningMsg",
  Rx = "WarningMsg",
  Rv = "WarningMsg",
  c = "Statement",
  cv = "Statement",
  ce = "Statement",
  r = "Special",
  rm = "Special",
  ["r?"] = "Special",
  ["!"] = "DiagnosticError",
  t = "DiagnosticError",
}

local function statusline_win()
  local winid = tonumber(vim.g.statusline_winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
  return vim.api.nvim_get_current_win()
end

local function statusline_buf(winid)
  winid = winid or statusline_win()
  if vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_buf(winid)
  end
  return vim.api.nvim_get_current_buf()
end

local function is_active()
  local winid = tonumber(vim.g.statusline_winid)
  if winid == nil then
    -- With a global statusline (laststatus=3), Neovim may not expose statusline_winid
    -- the same way. Treat it as active so the mode block still renders.
    return vim.o.laststatus == 3
  end
  return vim.api.nvim_get_current_win() == winid
end

local function win_width(winid)
  winid = winid or statusline_win()
  if vim.api.nvim_win_is_valid(winid) then
    return vim.api.nvim_win_get_width(winid)
  end
  return vim.o.columns
end

local function get_file_label(bufnr, winid)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local bt = vim.bo[bufnr].buftype
  local ft = vim.bo[bufnr].filetype
  if name == "" then
    if ft == "NvimTree" then
      return "Files"
    end
    if ft == "TelescopePrompt" then
      return "Telescope"
    end
    if bt == "terminal" then
      return "Terminal"
    end
    if bt == "quickfix" then
      return "Quickfix"
    end
    if bt == "help" then
      return "Help"
    end
    if ft ~= "" then
      return ft
    end
    return "[No Name]"
  end
  return vim.fn.fnamemodify(name, ":~:.")
end

local Align = { provider = "%=" }
local Space = { provider = " " }

local ViMode = {
  init = function(self)
    self.mode = vim.fn.mode(1)
  end,
  provider = function(self)
    local name = mode_names[self.mode] or mode_names[self.mode:sub(1, 1)] or self.mode
    return " " .. name .. " "
  end,
  hl = function(self)
    return mode_highlights[self.mode] or mode_highlights[self.mode:sub(1, 1)] or "StatusLine"
  end,
  update = { "ModeChanged", "BufEnter", "WinEnter" },
}

local FileBlock = {
  init = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    self.filename = vim.api.nvim_buf_get_name(self.bufnr)
    self.file_label = get_file_label(self.bufnr, self.winid)
    self.modified = vim.bo[self.bufnr].modified
    self.readonly = vim.bo[self.bufnr].readonly or not vim.bo[self.bufnr].modifiable

    local ext = vim.fn.fnamemodify(self.filename, ":e")
    if has_devicons then
      self.icon, self.icon_color = devicons.get_icon_color(self.filename, ext, { default = true })
    end
  end,
  {
    provider = " ",
  },
  {
    provider = function(self)
      if not self.icon then
        return ""
      end
      return self.icon .. " "
    end,
    hl = function(self)
      return { fg = self.icon_color }
    end,
  },
  {
    provider = function(self)
      return self.file_label
    end,
    hl = function(self)
      if self.modified then
        return "WarningMsg"
      end
      return "StatusLine"
    end,
  },
  {
    provider = function(self)
      local parts = {}
      if self.modified then
        table.insert(parts, "[+]")
      end
      if self.readonly then
        table.insert(parts, "")
      end
      if #parts == 0 then
        return ""
      end
      return " " .. table.concat(parts, " ")
    end,
    hl = function(self)
      if self.modified then
        return "WarningMsg"
      end
      return "StatusLine"
    end,
  },
}

local Git = {
  condition = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    return vim.b[self.bufnr].gitsigns_head ~= nil
  end,
  init = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    self.git = vim.b[self.bufnr].gitsigns_status_dict or {}
    self.head = vim.b[self.bufnr].gitsigns_head
  end,
  {
    provider = "  ",
  },
  {
    provider = function(self)
      if not self.head or self.head == "" then
        return ""
      end
      return " " .. self.head
    end,
    hl = "Identifier",
  },
  {
    provider = function(self)
      local parts = {}
      if (self.git.added or 0) > 0 then
        table.insert(parts, "+" .. self.git.added)
      end
      if (self.git.changed or 0) > 0 then
        table.insert(parts, "~" .. self.git.changed)
      end
      if (self.git.removed or 0) > 0 then
        table.insert(parts, "-" .. self.git.removed)
      end
      if #parts == 0 then
        return ""
      end
      return " (" .. table.concat(parts, " ") .. ")"
    end,
    hl = "StatusLine",
  },
}

local Diagnostics = {
  init = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    self.errors = #vim.diagnostic.get(self.bufnr, { severity = vim.diagnostic.severity.ERROR })
    self.warns = #vim.diagnostic.get(self.bufnr, { severity = vim.diagnostic.severity.WARN })
    self.infos = #vim.diagnostic.get(self.bufnr, { severity = vim.diagnostic.severity.INFO })
    self.hints = #vim.diagnostic.get(self.bufnr, { severity = vim.diagnostic.severity.HINT })
  end,
  condition = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    return not vim.tbl_isempty(vim.diagnostic.get(self.bufnr))
  end,
  {
    provider = " ",
  },
  {
    provider = function(self)
      if self.errors == 0 then
        return ""
      end
      return " " .. self.errors .. " "
    end,
    hl = "DiagnosticError",
  },
  {
    provider = function(self)
      if self.warns == 0 then
        return ""
      end
      return " " .. self.warns .. " "
    end,
    hl = "DiagnosticWarn",
  },
  {
    provider = function(self)
      if self.infos == 0 then
        return ""
      end
      return " " .. self.infos .. " "
    end,
    hl = "DiagnosticInfo",
  },
  {
    provider = function(self)
      if self.hints == 0 then
        return ""
      end
      return "󰌵 " .. self.hints .. " "
    end,
    hl = "DiagnosticHint",
  },
}

local Lsp = {
  condition = function(self)
    self.winid = statusline_win()
    if win_width(self.winid) < 100 then
      return false
    end
    self.bufnr = statusline_buf(self.winid)
    return #vim.lsp.get_clients({ bufnr = self.bufnr }) > 0
  end,
  init = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    local names = {}
    local seen = {}
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = self.bufnr })) do
      if client.name and client.name ~= "" and not seen[client.name] then
        seen[client.name] = true
        table.insert(names, client.name)
      end
    end
    table.sort(names)
    self.lsp_names = names
  end,
  provider = function(self)
    return "  " .. table.concat(self.lsp_names, ", ") .. " "
  end,
  hl = "Special",
}

local FileType = {
  init = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    self.ft = vim.bo[self.bufnr].filetype
  end,
  provider = function(self)
    local ft = self.ft ~= "" and self.ft or "text"
    return " " .. ft .. " "
  end,
  hl = "StatusLine",
}

local Ruler = {
  init = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    local cursor = vim.api.nvim_win_get_cursor(self.winid)
    self.line = cursor[1]
    self.col = cursor[2] + 1
    self.total = math.max(vim.api.nvim_buf_line_count(self.bufnr), 1)
    self.percent = math.floor((self.line / self.total) * 100)
  end,
  provider = function(self)
    return string.format(" %d:%d %d%% ", self.line, self.col, self.percent)
  end,
  hl = "StatusLine",
}

local ScrollBar = {
  static = {
    bars = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" },
  },
  init = function(self)
    self.winid = statusline_win()
    self.bufnr = statusline_buf(self.winid)
    local line = vim.api.nvim_win_get_cursor(self.winid)[1]
    local total = math.max(vim.api.nvim_buf_line_count(self.bufnr), 1)
    local i = math.floor(((line - 1) / total) * #self.bars) + 1
    self.bar = self.bars[math.min(math.max(i, 1), #self.bars)]
  end,
  provider = function(self)
    return self.bar .. " "
  end,
  hl = "StatusLine",
}

local ActiveStatusline = {
  condition = is_active,
  hl = "StatusLine",
  ViMode,
  FileBlock,
  Git,
  Align,
  Diagnostics,
  Lsp,
  FileType,
  Ruler,
  ScrollBar,
}

local InactiveStatusline = {
  hl = "StatusLineNC",
  Space,
  FileBlock,
  Align,
  FileType,
  {
    provider = function(self)
      self.winid = statusline_win()
      if not vim.api.nvim_win_is_valid(self.winid) then
        return ""
      end
      local cursor = vim.api.nvim_win_get_cursor(self.winid)
      return string.format(" %d:%d ", cursor[1], cursor[2] + 1)
    end,
    hl = "StatusLineNC",
  },
}

vim.o.showmode = false
vim.o.laststatus = 3

heirline.setup({
  statusline = {
    fallthrough = false,
    ActiveStatusline,
    InactiveStatusline,
  },
})
