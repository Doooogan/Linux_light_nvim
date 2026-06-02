
-- telekasten_insert_visible_links.lua

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local function iter_visible(manager)
  if manager and type(manager.iter) == "function" then
    return manager:iter()
  elseif manager and type(manager.iterate) == "function" then
    return manager:iterate()
  end
  local i, n = 0, (manager and manager:size and manager:size()) or 0
  return function()
    i = i + 1
    if i <= n then return manager:get_entry(i) end
  end
end

local function entry_to_path(e)
  return e.path or e.filename or e.value or (type(e[1]) == "string" and e[1]) or nil
end

local function make_telekasten_link(path)
  -- Remove extension and directory to get the filename only
  local name = vim.fn.fnamemodify(path, ":t:r")
  return string.format("[[%s]]", name)
end

local function insert_links_for_visible(prompt_bufnr)
  local picker = action_state.get_current_picker(prompt_bufnr)
  local manager = picker and picker.manager
  if not manager then
    actions.close(prompt_bufnr)
    vim.notify("No Telescope results found.", vim.log.levels.WARN)
    return
  end

  local paths = {}
  for entry in iter_visible(manager) do
    local p = entry_to_path(entry)
    if p and vim.fn.filereadable(p) == 1 then
      table.insert(paths, p)
    end
  end

  actions.close(prompt_bufnr)

  if #paths == 0 then
    vim.notify("No visible results to insert.", vim.log.levels.INFO)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]

  local out = {}
  for _, p in ipairs(paths) do
    table.insert(out, make_telekasten_link(p))
  end

  vim.api.nvim_buf_set_lines(buf, row, row, false, out)
end

-- Attach to Telekasten Telescope pickers
require("telekasten").setup({
  -- your existing Telekasten config ...
  mappings = {
    ["<C-i>"] = insert_links_for_visible,
  },
})
