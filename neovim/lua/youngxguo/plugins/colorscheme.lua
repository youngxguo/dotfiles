local theme = require("youngxguo.theme")

return {
  "maxmx03/solarized.nvim",
  lazy = false,
  priority = 1000,
  opts = {
    transparent = {
      enabled = vim.env.NVIM_TRANSPARENT == "1",
      normal = true,
      normalfloat = true,
      nvimtree = true,
      telescope = true,
      lazy = true,
    },
    palette = "solarized",
    variant = "winter",
  },
  config = function(_, opts)
    vim.o.termguicolors = true
    vim.o.background = "dark"
    require("solarized").setup(opts)
    vim.cmd.colorscheme("solarized")
    theme.apply_diff_highlights()
    theme.apply_ui_highlights()
  end,
}
