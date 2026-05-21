-- Human-readable command aliases for <leader> keybindings.
-- Type ":" and fuzzy-search these names via cmdline completion.
-- Each entry: { "CommandName", function, "description" }

local commands = {
  -- search & files
  { "FindFiles",               function() require("fzf-lua").files() end },
  { "GitFiles",                function() require("fzf-lua").git_files() end },
  { "LiveGrep",                function() require("fzf-lua").live_grep({ hidden = true }) end },
  { "GrepPrompt",              function()
    local search = vim.fn.input("Grep > ")
    if search and search ~= "" then require("fzf-lua").grep({ search = search }) end
  end },
  { "DocumentSymbols",         function() require("fzf-lua").lsp_document_symbols() end },
  { "References",              function() require("fzf-lua").lsp_references() end },
  { "DocumentDiagnostics",     function() require("fzf-lua").diagnostics_document() end },
  { "WorkspaceDiagnostics",    function() require("fzf-lua").diagnostics_workspace() end },
  { "ToggleComment",           function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gcc", true, true, true), "m", false)
  end },

  -- edit
  { "Format",                  function() require("conform").format({ lsp_format = "never", timeout_ms = 5000 }) end },

  -- navigation
  { "ToggleFileTree",          function() vim.cmd("NvimTreeToggle") end },
  { "ToggleStickyContext",     function() vim.cmd("TSContext toggle") end },
  { "PickBreadcrumb",          function() require("dropbar.api").pick() end },
  { "VerticalSplit",           function() vim.cmd("vsplit") end },
  { "HorizontalSplit",         function() vim.cmd("split") end },
  { "NewTab",                  function() vim.cmd("tabnew") end },
  { "CloseTab",                function() vim.cmd("tabclose") end },

  -- yank
  { "YankFilePath",            function()
    local text = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":.")
    vim.fn.setreg("+", text)
    vim.notify(text)
  end },
  { "YankGitLink",             function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>yl", true, true, true), "m", false)
  end },

  -- git
  { "GitNextChange",           function() require("gitsigns").nav_hunk("next") end },
  { "GitPrevChange",           function() require("gitsigns").nav_hunk("prev") end },
  { "GitBlameCommit",          function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>gc", true, true, true), "m", false)
  end },
  { "GitOpenCommitRemote",     function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>gC", true, true, true), "m", false)
  end },
  { "GitDiffSplit",            function() vim.cmd("Gdiffsplit") end },
  { "GitStatus",               function() vim.cmd("Neogit") end },
  { "GitBranches",             function() require("fzf-lua").git_branches() end },
  { "GitDiff",                 function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>gd", true, true, true), "m", false)
  end },
  { "GitDiffClose",            function() vim.cmd("DiffviewClose") end },
  { "GitHistory",              function()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<leader>gl", true, true, true), "m", false)
  end },
  { "GitLogFile",              function() require("fzf-lua").git_bcommits() end },

  -- PR review (Octo)
  { "PRNeedsReview",           function() vim.cmd("Octo pr search is:pr sort:updated-desc user-review-requested:@me is:open") end },
  { "PRMyOpen",                function() vim.cmd("Octo pr search author:@me is:open") end },
  { "PRAssignedToMe",          function() vim.cmd("Octo pr search assignee:@me is:open") end },
  { "PRSearch",                function() vim.cmd("Octo pr search") end },
  { "PRCheckout",              function() vim.cmd("Octo pr checkout") end },
  { "PRStartReview",           function() vim.cmd("Octo review start") end },
  { "PRSubmitReview",          function() vim.cmd("Octo review submit") end },
  { "PRResumeReview",          function() vim.cmd("Octo review resume") end },
  { "PRDiff",                  function() vim.cmd("Octo pr diff") end },
}

for _, cmd in ipairs(commands) do
  vim.api.nvim_create_user_command(cmd[1], cmd[2], {})
end
