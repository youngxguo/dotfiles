local actions = require("youngxguo.actions")

-- all project files with open buffers + recent files pinned to the top
vim.keymap.set("n", "<C-p>", function()
  local fzf = require("fzf-lua")
  local fzf_config = require("fzf-lua.config")
  local files_mod = require("fzf-lua.providers.files")
  local bufs_mod = require("fzf-lua.providers.buffers")

  -- resolve the fd/rg command fzf-lua would normally use
  local fopts = fzf_config.normalize_opts({}, "files")
  local files_cmd = files_mod.get_files_cmd(fopts)

  local pinned = {}
  local seen = {}

  -- open buffers sorted by last used (most recent first)
  for _, bufnr in ipairs(bufs_mod.list_bufs_sorted()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" then
        local rel = vim.fn.fnamemodify(name, ":.")
        if not rel:match("^/") and not seen[rel] then
          seen[rel] = true
          table.insert(pinned, rel)
        end
      end
    end
  end

  -- oldfiles for cross-session persistence (via shada)
  local cwd = vim.fn.getcwd() .. "/"
  for _, f in ipairs(vim.v.oldfiles) do
    if f:sub(1, #cwd) == cwd then
      local rel = f:sub(#cwd + 1)
      if not seen[rel] and vim.uv.fs_stat(f) then
        seen[rel] = true
        table.insert(pinned, rel)
      end
    end
  end

  local raw
  if #pinned > 0 then
    local escaped = {}
    for _, b in ipairs(pinned) do
      table.insert(escaped, vim.fn.shellescape(b))
    end
    -- print pinned paths first, then all files, deduplicate preserving order
    raw = "{ printf '%s\\n' " .. table.concat(escaped, " ") .. " ; " .. files_cmd .. " ; } | awk '!seen[$0]++'"
  else
    raw = files_cmd
  end

  fzf.global({
    raw_cmd = raw,
    formatter = { "path.filename_first", 2 },
    fzf_opts = {
      ["--tiebreak"] = "index",
    },
  })
end, { silent = true })

-- splits
vim.api.nvim_set_keymap("n", "<leader>\\", ":vsplit<CR>", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<leader>-", ":split<CR>", { noremap = true, silent = true })

-- zoom: toggle maximizing the current split (tmux prefix-z style); per-tab
vim.keymap.set("n", "<leader>z", function()
  if vim.t.zoom_restore then
    vim.cmd(vim.t.zoom_restore)
    vim.t.zoom_restore = nil
  elseif vim.fn.winnr("$") > 1 then
    local restore = vim.fn.winrestcmd()
    vim.cmd("wincmd _")
    vim.cmd("wincmd |")
    vim.t.zoom_restore = restore
  end
end, { silent = true, desc = "Toggle zoom current split" })

-- j/k move by display line over wraps, but honor a count (e.g. 5j) so
-- relativenumber jumps still land on real lines
vim.keymap.set({ "n", "v" }, "j", "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })
vim.keymap.set({ "n", "v" }, "k", "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })

-- search: center + open folds after jumping (neoscroll animates the zz)
vim.keymap.set("n", "n", "nzzzv")
vim.keymap.set("n", "N", "Nzzzv")

-- tabs
vim.keymap.set("n", "<leader>tn", "<cmd>tabnew<CR>", { silent = true })
vim.keymap.set("n", "<leader>tc", "<cmd>tabclose<CR>", { silent = true })

-- yank file path (relative to cwd)
vim.keymap.set("n", "<leader>yf", actions.yank_file_path, { silent = true, desc = "Yank file path" })

-- yank remote line link (current line or visual range), anchored at HEAD
vim.keymap.set({ "n", "v" }, "<leader>yl", actions.yank_git_link, { silent = true, desc = "Yank git line link" })

-- git hunk navigation (gitsigns)
vim.keymap.set("n", "<leader>gj", function() require("gitsigns").nav_hunk("next") end, { silent = true, desc = "Next git change" })
vim.keymap.set("n", "<leader>gk", function() require("gitsigns").nav_hunk("prev") end, { silent = true, desc = "Previous git change" })

-- git blame: view current line's commit in Diffview
vim.keymap.set("n", "<leader>gc", actions.git_blame_commit_diffview, { silent = true, desc = "Git blame commit in Diffview" })

-- git blame: open current line's commit on remote
vim.keymap.set("n", "<leader>gC", actions.git_blame_commit_remote, { silent = true, desc = "Open line's commit on remote" })

-- git workflow
vim.keymap.set("n", "<leader>gs", "<cmd>Gdiffsplit<CR>", { silent = true })
vim.keymap.set("n", "<leader>gg", "<cmd>Neogit<CR>", { silent = true })
vim.keymap.set("n", "<leader>gb", function()
  require("fzf-lua").git_branches()
end, { silent = true, desc = "Git branches" })
-- octo (GitHub PR review)
vim.keymap.set("n", "<leader>ol", "<cmd>Octo pr search is:pr sort:updated-desc user-review-requested:@me is:open<CR>", { silent = true })
vim.keymap.set("n", "<leader>om", "<cmd>Octo pr search author:@me is:open<CR>", { silent = true })
vim.keymap.set("n", "<leader>oa", "<cmd>Octo pr search assignee:@me is:open<CR>", { silent = true })
vim.keymap.set("n", "<leader>os", "<cmd>Octo pr search<CR>", { silent = true })
vim.keymap.set("n", "<leader>oc", "<cmd>Octo pr checkout<CR>", { silent = true })
vim.keymap.set("n", "<leader>or", "<cmd>Octo review start<CR>", { silent = true })
vim.keymap.set("n", "<leader>oR", "<cmd>Octo review submit<CR>", { silent = true })
vim.keymap.set("n", "<leader>oe", "<cmd>Octo review resume<CR>", { silent = true })
vim.keymap.set("n", "<leader>od", "<cmd>Octo pr diff<CR>", { silent = true })
