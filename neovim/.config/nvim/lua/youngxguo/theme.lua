-- Shared Solarized palette and highlight overrides.
-- Required by the colorscheme spec (to apply on load) and the bufferline spec
-- (to build its highlight table). Keeping it here lets both reference one source.

local M = {}

M.solarized_ui = {
  base03 = "#002b36",
  base02 = "#073642",
  base01 = "#586e75",
  base0 = "#839496",
  base1 = "#93a1a1",
  base2 = "#eee8d5",
  green = "#859900",
  yellow = "#b58900",
  orange = "#cb4b16",
  red = "#dc322f",
  magenta = "#d33682",
  violet = "#6c71c4",
  blue = "#268bd2",
  cyan = "#2aa198",
}

function M.apply_diff_highlights()
  -- Background-only diff colors preserve syntax highlighting in Diffview buffers.
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#003a20" })
  vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#3a0a10" })
  vim.api.nvim_set_hl(0, "DiffChange", { bg = "#002a40" })
  vim.api.nvim_set_hl(0, "DiffText", { bg = "#004a55" })
end

function M.apply_ui_highlights()
  local c = M.solarized_ui
  vim.api.nvim_set_hl(0, "StatusLine", { fg = c.base1, bg = c.base03 })
  vim.api.nvim_set_hl(0, "StatusLineNC", { fg = c.base01, bg = c.base03 })
  vim.api.nvim_set_hl(0, "StatusModeNormal", { fg = c.base03, bg = c.blue, bold = true })
  vim.api.nvim_set_hl(0, "StatusModeInsert", { fg = c.base03, bg = c.green, bold = true })
  vim.api.nvim_set_hl(0, "StatusModeVisual", { fg = c.base03, bg = c.magenta, bold = true })
  vim.api.nvim_set_hl(0, "StatusModeSelect", { fg = c.base03, bg = c.violet, bold = true })
  vim.api.nvim_set_hl(0, "StatusModeReplace", { fg = c.base03, bg = c.orange, bold = true })
  vim.api.nvim_set_hl(0, "StatusModeCommand", { fg = c.base03, bg = c.yellow, bold = true })
  vim.api.nvim_set_hl(0, "StatusModePrompt", { fg = c.base03, bg = c.cyan, bold = true })
  vim.api.nvim_set_hl(0, "StatusModeShell", { fg = c.base03, bg = c.red, bold = true })
  vim.api.nvim_set_hl(0, "TabLine", { fg = c.base0, bg = c.base03 })
  vim.api.nvim_set_hl(0, "TabLineSel", { fg = c.base03, bg = c.blue, bold = true })
  vim.api.nvim_set_hl(0, "TabLineFill", { bg = c.base03 })
  vim.api.nvim_set_hl(0, "WinSeparator", { fg = c.base01, bg = c.base03 })
  vim.api.nvim_set_hl(0, "VertSplit", { fg = c.base01, bg = c.base03 })
  vim.api.nvim_set_hl(0, "SignColumn", { fg = c.base1 })
  vim.api.nvim_set_hl(0, "LineNr", { fg = c.base01 })
  vim.api.nvim_set_hl(0, "CursorLineNr", { fg = c.cyan, bg = c.base02, bold = true })

  -- Standard float groups are shared by native LSP windows and plugins.
  vim.api.nvim_set_hl(0, "NormalFloat", { fg = c.base1, bg = c.base03 })
  vim.api.nvim_set_hl(0, "FloatBorder", { fg = c.cyan, bg = c.base03 })

  local fidget_bg = c.base03
  vim.api.nvim_set_hl(0, "YoungFidgetGroup", { fg = c.blue, bg = fidget_bg, bold = true })
  vim.api.nvim_set_hl(0, "YoungFidgetIcon", { fg = c.cyan, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetProgress", { fg = c.yellow, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetDone", { fg = c.green, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetInfo", { fg = c.cyan, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetWarn", { fg = c.orange, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetError", { fg = c.red, bg = fidget_bg, bold = true })
  vim.api.nvim_set_hl(0, "YoungFidgetDebug", { fg = c.base01, bg = fidget_bg })
  vim.api.nvim_set_hl(0, "YoungFidgetSeparator", { fg = c.base01, bg = fidget_bg })

  -- indent-blankline active-scope guide, tied to the tabline/bufferline accent.
  vim.api.nvim_set_hl(0, "IblScope", { fg = c.blue })
end

function M.bufferline_highlights()
  local c = M.solarized_ui
  local selected = function()
    return { fg = c.base03, bg = c.blue, bold = true, italic = false }
  end
  return {
    fill = { bg = c.base03 },
    background = { fg = c.base0, bg = c.base03 },
    buffer_visible = { fg = c.base0, bg = c.base03 },
    buffer_selected = selected(),
    indicator_selected = { fg = c.base03, bg = c.blue },
    numbers_selected = selected(),
    diagnostic_selected = selected(),
    hint_selected = selected(),
    hint_diagnostic_selected = selected(),
    info_selected = selected(),
    info_diagnostic_selected = selected(),
    warning_selected = selected(),
    warning_diagnostic_selected = selected(),
    error_selected = selected(),
    error_diagnostic_selected = selected(),
    tab = { fg = c.base0, bg = c.base03 },
    tab_selected = { fg = c.base03, bg = c.blue, bold = true },
    tab_separator = { fg = c.base02, bg = c.base03 },
    tab_separator_selected = { fg = c.blue, bg = c.blue },
    separator = { fg = c.base02, bg = c.base03 },
    separator_visible = { fg = c.base02, bg = c.base03 },
    separator_selected = { fg = c.blue, bg = c.blue },
    modified = { fg = c.base2, bg = c.base03 },
    modified_visible = { fg = c.base2, bg = c.base03 },
    modified_selected = { fg = c.base03, bg = c.blue },
    duplicate = { fg = c.base01, bg = c.base03, italic = false },
    duplicate_visible = { fg = c.base01, bg = c.base03, italic = false },
    duplicate_selected = { fg = c.base02, bg = c.blue, bold = true, italic = false },
  }
end

return M
