
local actions      = require("telescope.actions")
local action_state = require("telescope.actions.state")

local M = {}

local function to_abs_if_needed(p, cwd)
  if not p then return nil end
  if cwd and not p:match("^/") and not p:match("^%a:[/\\]") then
    p = (cwd:gsub("[/\\]$", "")) .. "/" .. p
  end
  return (vim.fn.filereadable(p) == 1) and vim.fn.fnamemodify(p, ":p") or nil
end

local function tk_wikilink(p)
  return string.format("[[%s]]", vim.fn.fnamemodify(p, ":t:r"))
end

function M.insert_links_for_all(prompt_bufnr)
  -- Get picker per :h telescope.actions.state.get_current_picker
  local picker = action_state.get_current_picker(prompt_bufnr)  -- :contentReference[oaicite:1]{index=1}
  local cwd    = picker.cwd or vim.loop.cwd()

  -- 1) Make *all* entries multi-selected (doc’d action) then read them
  require("telescope.actions").toggle_all(prompt_bufnr)         -- :contentReference[oaicite:2]{index=2}
  local selected = picker:get_multi_selection() or {}

  -- 2) Collect readable file paths from the selected entries
  local paths = {}
  for _, e in ipairs(selected) do
    local p = e.path or e.filename or e.value or e[1] or e.ordinal
    p = to_abs_if_needed(p, cwd)
    if p then table.insert(paths, p) end
  end

  actions.close(prompt_bufnr)

  if #paths == 0 then
    vim.notify("No results to insert.", vim.log.levels.INFO)
    return
  end

  -- 3) Insert links
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local out = {}
  for _, p in ipairs(paths) do table.insert(out, tk_wikilink(p)) end
  vim.api.nvim_buf_set_lines(buf, row, row, false, out)
end

-- Optional: only insert whatever the user manually multi-selected
function M.insert_links_for_manual(prompt_bufnr)
  local picker  = action_state.get_current_picker(prompt_bufnr)
  local cwd     = picker.cwd or vim.loop.cwd()
  local chosen  = picker:get_multi_selection() or {}
  if vim.tbl_isempty(chosen) then
    -- fall back to just the highlighted entry if nothing is multi-selected
    local cur = action_state.get_selected_entry()
    if cur then table.insert(chosen, cur) end
  end
  actions.close(prompt_bufnr)

  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local out = {}
  for _, e in ipairs(chosen) do
    local p = e.path or e.filename or e.value or e[1] or e.ordinal
    p = to_abs_if_needed(p, cwd)
    if p then table.insert(out, tk_wikilink(p)) end
  end
  if #out == 0 then
    vim.notify("No selected results.", vim.log.levels.INFO)
    return
  end
  vim.api.nvim_buf_set_lines(buf, row, row, false, out)
end

return M
