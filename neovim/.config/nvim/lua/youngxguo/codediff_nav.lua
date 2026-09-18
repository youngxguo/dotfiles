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

vim.api.nvim_create_autocmd("User", {
  group = vim.api.nvim_create_augroup("CodeDiffNavCompact", { clear = true }),
  pattern = "CodeDiffOpen",
  callback = function(args)
    local tabpage = args.data and args.data.tabpage
    if tabpage then
      enable_compact(tabpage)
    end
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
  if not ok or type(pr) ~= "table" or type(pr.baseRefName) ~= "string" then
    return
  end

  local refs = { "origin/" .. pr.baseRefName }
  local remotes = vim.system({ "git", "-C", dir, "remote" }, { text = true }):wait()
  if remotes.code == 0 then
    for remote in (remotes.stdout or ""):gmatch("[^\r\n]+") do
      local ref = remote .. "/" .. pr.baseRefName
      if ref ~= refs[1] then
        table.insert(refs, ref)
      end
    end
  end
  table.insert(refs, pr.baseRefName)

  local fallback
  for _, ref in ipairs(refs) do
    local oid = git_ref_oid(dir, ref)
    if oid then
      fallback = fallback or ref
      if type(pr.baseRefOid) ~= "string" or pr.baseRefOid == "" or oid == pr.baseRefOid then
        return ref
      end
    end
  end

  if type(pr.baseRefOid) == "string" and pr.baseRefOid ~= "" and git_ref_exists(dir, pr.baseRefOid) then
    return pr.baseRefOid
  end
  return fallback
end

local function local_stack_base_ref(dir)
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
    "git", "-C", dir, "rev-list", "--first-parent", "--max-count=256", "HEAD",
  }, { text = true }):wait()
  if history.code == 0 then
    for oid in (history.stdout or ""):gmatch("[^\r\n]+") do
      if refs_by_oid[oid] then
        return refs_by_oid[oid]
      end
    end
  end
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

function M.open_base_diff()
  local layout = apply_view_defaults()
  local dir = probe_dir()
  local pr_base_ref = github_pr_base_ref(dir)
  local stack_base_ref = not pr_base_ref and local_stack_base_ref(dir) or nil
  local base_ref = pr_base_ref or stack_base_ref or trunk_ref(dir)
  if not base_ref then
    vim.notify("Could not find a pull request, stacked branch, or local trunk base", vim.log.levels.ERROR)
    return
  end

  local base_oid
  if pr_base_ref or stack_base_ref then
    base_oid = merge_base(dir, base_ref, true)
  end
  base_oid = base_oid or merge_base(dir, base_ref, false) or git_ref_oid(dir, base_ref)
  if not base_oid then
    vim.notify("Could not resolve the comparison base", vim.log.levels.ERROR)
    return
  end
  command(layout, base_oid)
end

return M
