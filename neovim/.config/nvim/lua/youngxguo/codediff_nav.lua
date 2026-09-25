local M = {}

local DEFAULT_LAYOUT = "inline"

local function apply_view_defaults()
  local layout = DEFAULT_LAYOUT

  local ok, config = pcall(require, "codediff.config")
  if ok and config.options then
    if config.options.diff then
      config.options.diff.layout = layout
    end
    if config.options.explorer then
      config.options.explorer.hidden = false
    end
  end

  return layout
end

local COMPACT_POLL_INTERVAL_MS = 50
local COMPACT_POLL_MAX_ATTEMPTS = 40
local INLINE_WRAP_POLL_INTERVAL_MS = 50
local INLINE_WRAP_POLL_MAX_ATTEMPTS = 40

local function codediff_session(tabpage)
  if not package.loaded["codediff.ui.lifecycle"] then
    return nil
  end
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  return ok and lifecycle.get_session(tabpage) or nil
end

local function wrap_inline_diff(tabpage)
  local session = codediff_session(tabpage)
  if not session or session.layout ~= "inline" then
    return
  end

  local win = session.modified_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].breakindent = true
  end
end

-- CodeDiff forces nowrap whenever it renders or enters a diff pane. That is
-- required by side-by-side scroll synchronization, but inline has only one
-- pane. Wait for asynchronous file rendering, then restore normal wrapping.
local function wrap_after_inline_render(tabpage, previous_result, attempts)
  attempts = attempts or 0
  local session = codediff_session(tabpage)
  if session and session.layout ~= "inline" then
    return
  end

  local result = session and session.stored_diff_result
  if result and result ~= previous_result and result.changes then
    wrap_inline_diff(tabpage)
    return
  end

  if attempts < INLINE_WRAP_POLL_MAX_ATTEMPTS and vim.api.nvim_tabpage_is_valid(tabpage) then
    vim.defer_fn(function()
      wrap_after_inline_render(tabpage, previous_result, attempts + 1)
    end, INLINE_WRAP_POLL_INTERVAL_MS)
  else
    wrap_inline_diff(tabpage)
  end
end

-- codediff computes the diff asynchronously, so `stored_diff_result.changes` is
-- briefly nil after CodeDiffOpen fires; calling compact.enable() too early bails
-- with "No changes to compact". There's no diff-ready event, so poll for it.
local function enable_compact(tabpage, attempts)
  attempts = attempts or 0
  local ok_lifecycle, lifecycle = pcall(require, "codediff.ui.lifecycle")
  local ok_compact, compact = pcall(require, "codediff.ui.view.compact")
  if not (ok_lifecycle and ok_compact) then
    return
  end

  local session = lifecycle.get_session(tabpage)
  if session and session.stored_diff_result and session.stored_diff_result.changes then
    pcall(compact.enable, tabpage)
  elseif attempts < COMPACT_POLL_MAX_ATTEMPTS then
    vim.defer_fn(function()
      enable_compact(tabpage, attempts + 1)
    end, COMPACT_POLL_INTERVAL_MS)
  end
end

local function find_codediff_tab()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return nil
  end
  for _, tabpage in ipairs(vim.api.nvim_list_tabpages()) do
    if lifecycle.get_session(tabpage) ~= nil then
      return tabpage
    end
  end
  return nil
end

-- codediff renamed `get_explorer` to `get_panel_view`. A plain working-tree
-- session also records an `original_revision` (`:0` or HEAD), so the panel is
-- authoritative when it exists.
local function session_revision(lifecycle, tabpage)
  local get_panel = lifecycle.get_panel_view or lifecycle.get_explorer
  if get_panel then
    local panel = get_panel(tabpage)
    if panel then
      return panel.base_revision
    end
  end

  local context = lifecycle.get_git_context(tabpage)
  return context and context.original_revision or nil
end

local function activate_existing(layout, revision)
  local current = vim.api.nvim_get_current_tabpage()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return false
  end

  if lifecycle.get_session(current) ~= nil then
    if session_revision(lifecycle, current) == revision then
      vim.cmd("CodeDiff --" .. layout)
      return true
    end
    return not lifecycle.close(current)
  end

  local existing = find_codediff_tab()
  if existing then
    if session_revision(lifecycle, existing) == revision then
      vim.api.nvim_set_current_tabpage(existing)
      return true
    end
    return not lifecycle.close(existing)
  end

  return false
end

local function command(layout, revision)
  if activate_existing(layout, revision) then
    return
  end

  if not revision then
    require("youngxguo.codediff_perf").request_full_status()
  end

  local args = {}
  if revision then
    table.insert(args, revision)
  end
  table.insert(args, "--" .. layout)
  vim.api.nvim_cmd({ cmd = "CodeDiff", args = args }, {})
end

local function probe_dir()
  local current_file = vim.api.nvim_buf_get_name(0)
  local buftype = vim.api.nvim_get_option_value("buftype", { buf = 0 })
  if current_file ~= "" and buftype == "" then
    return vim.fn.fnamemodify(current_file, ":p:h")
  end
  return vim.fn.getcwd()
end

local codediff_nav_group = vim.api.nvim_create_augroup("CodeDiffNav", { clear = true })

vim.api.nvim_create_autocmd("User", {
  group = codediff_nav_group,
  pattern = "CodeDiffOpen",
  callback = function(args)
    local tabpage = args.data and args.data.tabpage
    if tabpage then
      local session = codediff_session(tabpage)
      enable_compact(tabpage)
      wrap_inline_diff(tabpage)
      wrap_after_inline_render(tabpage, session and session.stored_diff_result)
    end
  end,
})

vim.api.nvim_create_autocmd("User", {
  group = codediff_nav_group,
  pattern = "CodeDiffFileSelect",
  callback = function(args)
    local tabpage = args.data and args.data.tabpage
    if tabpage then
      local session = codediff_session(tabpage)
      wrap_inline_diff(tabpage)
      wrap_after_inline_render(tabpage, session and session.stored_diff_result)
    end
  end,
})

vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "WinEnter", "FileType", "TabEnter" }, {
  group = codediff_nav_group,
  callback = function()
    if not package.loaded["codediff.ui.lifecycle"] then
      return
    end
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.schedule(function()
      vim.schedule(function()
        if vim.api.nvim_tabpage_is_valid(tabpage) then
          wrap_inline_diff(tabpage)
        end
      end)
    end)
  end,
})

function M.open_diff()
  local layout = apply_view_defaults()
  command(layout)
end

local function git_ref_oid(dir, ref)
  local result = vim.system({
    "git", "-C", dir, "rev-parse", "--verify", "--quiet", ref .. "^{commit}",
  }, { text = true }):wait()
  if result.code == 0 then
    return vim.trim(result.stdout or "")
  end
end

local function git_ref_exists(dir, ref)
  return git_ref_oid(dir, ref) ~= nil
end

local function github_pr_base_ref(dir)
  if vim.fn.executable("gh") ~= 1 then
    return
  end

  local result = vim.system({
    "gh", "pr", "view", "--json", "baseRefName,baseRefOid",
  }, { cwd = dir, text = true }):wait()
  if result.code ~= 0 then
    return
  end

  local ok, pr = pcall(vim.json.decode, result.stdout or "")
  if not ok or type(pr) ~= "table" or type(pr.baseRefName) ~= "string" or pr.baseRefName == "" then
    return
  end

  local refs = { "refs/remotes/origin/" .. pr.baseRefName }
  local remotes = vim.system({ "git", "-C", dir, "remote" }, { text = true }):wait()
  if remotes.code == 0 then
    for remote in (remotes.stdout or ""):gmatch("[^\r\n]+") do
      local ref = "refs/remotes/" .. remote .. "/" .. pr.baseRefName
      if ref ~= refs[1] then
        table.insert(refs, ref)
      end
    end
  end
  table.insert(refs, "refs/heads/" .. pr.baseRefName)

  -- baseRefOid is GitHub's snapshot of the base branch at the PR's last sync,
  -- not its live tip. The base ref is the answer; the snapshot only corrects
  -- a stale local fetch (see open_base_diff).
  local snapshot = type(pr.baseRefOid) == "string" and pr.baseRefOid ~= "" and pr.baseRefOid or nil
  for _, ref in ipairs(refs) do
    if git_ref_exists(dir, ref) then
      return ref, snapshot
    end
  end
  if snapshot and git_ref_exists(dir, snapshot) then
    return snapshot
  end
  -- A known PR target must not silently become a different comparison.
  return refs[1], snapshot
end

local function configured_base_ref(dir)
  local branch = vim.system({
    "git", "-C", dir, "symbolic-ref", "--quiet", "--short", "HEAD",
  }, { text = true }):wait()
  if branch.code ~= 0 then
    return
  end
  local result = vim.system({
    "git", "-C", dir, "config", "--get", "branch." .. vim.trim(branch.stdout) .. ".gh-merge-base",
  }, { text = true }):wait()
  local ref = result.code == 0 and vim.trim(result.stdout or "") or ""
  if ref == "" then
    return
  end
  if git_ref_exists(dir, "refs/heads/" .. ref) then
    return "refs/heads/" .. ref
  end
  -- Preserve explicit intent when the local parent was deleted; don't silently
  -- infer a different stack if neither the local nor remote parent exists.
  return "refs/remotes/origin/" .. ref
end

local function local_stack_base_ref(dir, trunk)
  local branch_result = vim.system({
    "git", "-C", dir, "symbolic-ref", "--quiet", "--short", "HEAD",
  }, { text = true }):wait()
  if branch_result.code ~= 0 then
    return
  end
  local branch = vim.trim(branch_result.stdout or "")

  local upstream = vim.system({
    "git", "-C", dir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
  }, { text = true }):wait()
  if upstream.code == 0 then
    local ref = vim.trim(upstream.stdout or "")
    if ref ~= branch and not vim.endswith(ref, "/" .. branch) then
      return ref
    end
  end

  -- A branch name on old trunk history is not evidence of a stack parent.
  -- Without a trunk boundary, prefer the normal fallback over guessing.
  if not trunk then
    return
  end

  local refs = vim.system({
    "git", "-C", dir, "for-each-ref", "--format=%(objectname) %(refname:short)", "refs/remotes", "refs/heads",
  }, { text = true }):wait()
  if refs.code ~= 0 then
    return
  end

  local refs_by_oid = {}
  for line in (refs.stdout or ""):gmatch("[^\r\n]+") do
    local oid, ref = line:match("^(%x+)%s+(.+)$")
    if oid and ref and ref ~= branch and not vim.endswith(ref, "/" .. branch) and not ref:match("/HEAD$") then
      refs_by_oid[oid] = refs_by_oid[oid] or ref
    end
  end

  local history = vim.system({
    "git", "-C", dir, "rev-list", "--first-parent", "--max-count=256", "HEAD", "^" .. trunk,
  }, { text = true }):wait()
  if history.code == 0 then
    for oid in (history.stdout or ""):gmatch("[^\r\n]+") do
      if refs_by_oid[oid] then
        return refs_by_oid[oid]
      end
    end
  end
end

local function is_ancestor(dir, ancestor, descendant)
  return vim.system({
    "git", "-C", dir, "merge-base", "--is-ancestor", ancestor, descendant,
  }, { text = true }):wait().code == 0
end

local function merge_base(dir, base_ref, fork_point)
  local args = { "git", "-C", dir, "merge-base" }
  if fork_point then
    table.insert(args, "--fork-point")
  end
  vim.list_extend(args, { base_ref, "HEAD" })

  local result = vim.system(args, { text = true }):wait()
  if result.code == 0 then
    local ref = vim.trim(result.stdout or "")
    if ref ~= "" then
      return ref
    end
  end
end

local function trunk_ref(dir)
  local remote_head = vim.system({
    "git", "-C", dir, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD",
  }, { text = true }):wait()
  if remote_head.code == 0 then
    local ref = vim.trim(remote_head.stdout or "")
    if ref ~= "" and git_ref_exists(dir, ref) then
      return ref
    end
  end

  for _, ref in ipairs({ "origin/main", "origin/master", "main", "master" }) do
    if git_ref_exists(dir, ref) then
      return ref
    end
  end
end

-- Selection contract: PR target > recorded gh base > distinct upstream >
-- nearest unmerged first-parent branch tip > trunk. Explicit targets that are
-- unavailable fail closed. Inference is only a convenience for legacy branches;
-- kickoff records intent with branch.<name>.gh-merge-base.
local function comparison_base(dir)
  local trunk = trunk_ref(dir)
  local pr_base_ref, pr_base_snapshot = github_pr_base_ref(dir)
  local stack_base_ref = not pr_base_ref
    and (configured_base_ref(dir) or local_stack_base_ref(dir, trunk)) or nil
  local base_ref = pr_base_ref or stack_base_ref or trunk
  if not base_ref then
    return nil, "Could not find a comparison base; configure branch.<name>.gh-merge-base"
  end

  local base_oid
  if pr_base_ref or stack_base_ref then
    base_oid = merge_base(dir, base_ref, true)
  end
  -- Fork-point preserves the old parent boundary after a force-push/rebase.
  -- Without reflog evidence, use common ancestry, never an unrelated ref tip.
  base_oid = base_oid or merge_base(dir, base_ref, false)
  if not base_oid then
    return nil, "Could not resolve comparison base " .. base_ref .. "; fetch or correct the base branch"
  end
  -- The snapshot is newer than the local base ref when the fetch is stale,
  -- and older when the branch was rebased past it. Keep whichever
  -- merge-base the other one leads to.
  if pr_base_snapshot and git_ref_exists(dir, pr_base_snapshot) then
    local snapshot_oid = merge_base(dir, pr_base_snapshot, false)
    if snapshot_oid and snapshot_oid ~= base_oid and is_ancestor(dir, base_oid, snapshot_oid) then
      base_oid = snapshot_oid
    end
  end
  return base_oid
end

function M.open_base_diff()
  local base_oid, err = comparison_base(probe_dir())
  if not base_oid then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end
  command(apply_view_defaults(), base_oid)
end

return M
