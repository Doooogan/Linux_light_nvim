-- Learn Harness keybinds: drop-in file.
--
-- Install:  copy this file to  ~/.config/nvim/plugin/learnharness.lua
-- Neovim loads everything in plugin/ automatically; nothing to add to init.lua.
-- To change paths or the key prefix, edit the setup() call at the very bottom.
--
-- Self-contained on purpose: it runs no code from the learn_harness project folder, so
-- edits made there (including by Claude) can't run inside your editor. Updates arrive as a
-- new copy of this file that you look over and drop in.
--
-- Purely additive:
--   * only buffer-local maps, only in markdown files inside the wiki
--   * never replaces a mapping you already have: a clash is skipped and reported once
--   * doesn't modify Telekasten; it calls Telekasten's own link picker when available
--
-- Keys (normal mode, prefix <leader>l):
--   <prefix>f   new "from:: " line + link picker       (this note follows from ...)
--   <prefix>+   add " + " and another premise to the current from:: line
--   <prefix>e / c / s   new "example:: " / "contra:: " / "see:: " line + link picker
--   <prefix>v   toggle :verified: in the tags line
--   <prefix>d   quickfix list of notes whose from:: lines point at this one
--   <prefix>n   next unfinished note: a :draft: note in the wiki, otherwise move the next blank
--               stub from staging (learn_harness/workspace/stubs) into the wiki and open it
--   <prefix>w   mark this note finished: remove :draft: and the "your node" reminder
--   <prefix>u   quickfix list of every unfinished note
-- Commands that work anywhere:  :LHNext  :LHFinish  :LHUnfinished

local M = {}

local defaults = {
  prefix = "<leader>l",
  wiki = "~/zettelkasten",
  harness = "~/proj/learn_harness",
  verified_tag = "verified",
  draft_tag = "draft",
  stubs = nil,            -- default: <harness>/workspace/stubs
}

local opts = {}

local function pick_link()
  local ok, tk = pcall(require, "telekasten")
  if ok and tk.insert_link then
    vim.cmd("startinsert!")
    vim.schedule(function() tk.insert_link({ i = true }) end)
  else
    vim.api.nvim_put({ "[[]]" }, "c", true, true)
    vim.cmd("normal! h")
    vim.cmd("startinsert")
  end
end

local function relation_line(rel)
  return function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(0, row, row, false, { rel .. ":: " })
    vim.api.nvim_win_set_cursor(0, { row + 1, #rel + 3 })
    pick_link()
  end
end

local function add_premise()
  local line = vim.api.nvim_get_current_line()
  vim.api.nvim_set_current_line((line:gsub("%s+$", "")) .. " + ")
  vim.api.nvim_win_set_cursor(0, { vim.api.nvim_win_get_cursor(0)[1], #vim.api.nvim_get_current_line() })
  pick_link()
end

local function toggle_verified()
  local tag = ":" .. opts.verified_tag .. ":"
  local lines = vim.api.nvim_buf_get_lines(0, 0, math.min(20, vim.api.nvim_buf_line_count(0)), false)
  for i, l in ipairs(lines) do
    local indent, rest = l:match("^(%s*)tags:%s*(.-)%s*$")
    if indent then
      local new
      if rest:find(tag, 1, true) then
        new = rest:gsub(vim.pesc(tag), ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        vim.notify("verified tag removed")
      else
        new = (rest == "" and tag) or (rest .. " " .. tag)
        vim.notify("marked verified")
      end
      vim.api.nvim_buf_set_lines(0, i - 1, i, false, { indent .. "tags: " .. new })
      return
    end
  end
  vim.notify("No tags: line in the frontmatter; add " .. tag .. " where you keep tags.", vim.log.levels.WARN)
end

local function follows_from_this()
  -- pure Lua: scan the wiki's from:: lines for links to this note (runs no project code)
  local stem = vim.fn.expand("%:t:r")
  local items = {}
  for _, p in ipairs(vim.fn.globpath(vim.fn.expand(opts.wiki), "*.md", false, true)) do
    for i, l in ipairs(vim.fn.readfile(p)) do
      local rest = l:match("^%s*[-*]?%s*[Ff][Rr][Oo][Mm]::%s*(.*)$")
      if rest and rest:find("[[" .. stem .. "]]", 1, true) then
        local others = {}
        for link in rest:gmatch("%[%[([^%]|#]+)") do
          if link ~= stem then table.insert(others, link) end
        end
        table.insert(items, { filename = p, lnum = i,
          text = #others > 0 and ("with " .. table.concat(others, " + ")) or "follows from this" })
      end
    end
  end
  if #items == 0 then
    vim.notify("Nothing lists this note in a from:: line yet.")
    return
  end
  vim.fn.setqflist({}, " ", { title = "Follows from " .. stem, items = items })
  vim.cmd("copen")
end

-- ---------------------------------------------------------------- unfinished notes
local function stamp(path)  -- Telekasten-style YYYYMMDDHHMM at the end of the name, for ordering
  return vim.fn.fnamemodify(path, ":t:r"):match("(%d%d%d%d%d%d%d%d%d%d%d%d)$") or path
end

local function by_stamp(list)
  table.sort(list, function(a, b) return stamp(a) < stamp(b) end)
  return list
end

local function is_draft(path)
  local tag = ":" .. opts.draft_tag .. ":"
  for _, l in ipairs(vim.fn.readfile(path, "", 15)) do
    if (l:match("^%s*tags:") or l:match("^%s*:[%w_:-]+:%s*$")) and l:find(tag, 1, true) then return true end
  end
  return false
end

local function wiki_drafts()
  local out = {}
  for _, p in ipairs(vim.fn.globpath(vim.fn.expand(opts.wiki), "*.md", false, true)) do
    if is_draft(p) then table.insert(out, p) end
  end
  return by_stamp(out)
end

local function staged()
  return by_stamp(vim.fn.globpath(vim.fn.expand(opts.stubs), "*.md", false, true))
end

local function goto_body()
  local lines = vim.api.nvim_buf_get_lines(0, 0, 30, false)
  local seen = 0
  for i, l in ipairs(lines) do
    if l:match("^%s*%-%-%-%s*$") then
      seen = seen + 1
      if seen == 2 then
        vim.api.nvim_win_set_cursor(0, { math.min(i + 2, vim.api.nvim_buf_line_count(0)), 0 })
        return
      end
    end
  end
end

local function next_unfinished()
  local here = vim.fn.resolve(vim.fn.expand("%:p"))
  for _, p in ipairs(wiki_drafts()) do
    if vim.fn.resolve(p) ~= here then
      vim.cmd("edit " .. vim.fn.fnameescape(p))
      goto_body()
      return
    end
  end
  local s = staged()[1]
  if not s then
    vim.notify("Nothing unfinished: no drafts in the wiki and no stubs waiting.")
    return
  end
  local dest = vim.fn.expand(opts.wiki) .. "/" .. vim.fn.fnamemodify(s, ":t")
  if vim.fn.filereadable(dest) == 1 then
    vim.notify("A note named " .. vim.fn.fnamemodify(s, ":t") .. " already exists in the wiki; leaving the stub in staging.",
      vim.log.levels.WARN)
    return
  end
  if vim.fn.rename(s, dest) ~= 0 then
    vim.notify("Couldn't move " .. s .. " into the wiki.", vim.log.levels.ERROR)
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(dest))
  goto_body()
  vim.notify(#staged() .. " more stub(s) waiting in staging.")
end

local function finish()
  local tag = ":" .. opts.draft_tag .. ":"
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local changed = false
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l:match("^<!%-%- your node") then
      table.remove(lines, i)
      if lines[i] == "" and lines[i - 1] == "" then table.remove(lines, i) end
      changed = true
    elseif i <= 15 and l:find(tag, 1, true) then
      local new = l:gsub(vim.pesc(tag), ""):gsub("%s+$", "")
      if new:match("^%s*$") then table.remove(lines, i) else lines[i] = new end
      changed = true
    end
  end
  if changed then
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.notify("Marked finished (:draft: and the reminder removed). Save to keep it.")
  else
    vim.notify("This note isn't marked as a draft.")
  end
end

local function list_unfinished()
  local items = {}
  for _, p in ipairs(wiki_drafts()) do table.insert(items, { filename = p, lnum = 1, text = "draft in the wiki" }) end
  for _, p in ipairs(staged()) do
    table.insert(items, { filename = p, lnum = 1, text = "blank stub in staging (" .. opts.prefix .. "n moves it in)" })
  end
  if #items == 0 then
    vim.notify("Nothing unfinished.")
    return
  end
  vim.fn.setqflist({}, " ", { title = "Unfinished notes", items = items })
  vim.cmd("copen")
end

local function map(buf, lhs, fn, desc, skipped)
  local full = opts.prefix .. lhs
  local existing = vim.fn.maparg(full, "n", false, true)
  if next(existing) ~= nil and not (existing.desc or ""):match("^LH:") then
    table.insert(skipped, full)
    return
  end
  vim.keymap.set("n", full, fn, { buffer = buf, desc = "LH: " .. desc, silent = true })
end

local warned = false

local function attach(buf)
  local skipped = {}
  map(buf, "f", relation_line("from"), "follows from (link)", skipped)
  map(buf, "+", add_premise, "add premise to this from::", skipped)
  map(buf, "e", relation_line("example"), "example (link)", skipped)
  map(buf, "c", relation_line("contra"), "contra (link)", skipped)
  map(buf, "s", relation_line("see"), "see also (link)", skipped)
  map(buf, "v", toggle_verified, "toggle :verified:", skipped)
  map(buf, "d", follows_from_this, "notes that follow from this", skipped)
  map(buf, "n", next_unfinished, "next unfinished note", skipped)
  map(buf, "w", finish, "mark note finished", skipped)
  map(buf, "u", list_unfinished, "list unfinished notes", skipped)
  if #skipped > 0 and not warned then
    warned = true
    vim.notify("Learn Harness: kept your existing mappings for " .. table.concat(skipped, ", ")
      .. ". Pass a different prefix to setup() to get these.", vim.log.levels.WARN)
  end
end

function M.setup(user)
  opts = vim.tbl_extend("force", defaults, user or {})
  opts.stubs = opts.stubs or (opts.harness .. "/workspace/stubs")
  vim.api.nvim_create_user_command("LHNext", next_unfinished, { desc = "Learn Harness: next unfinished note" })
  vim.api.nvim_create_user_command("LHFinish", finish, { desc = "Learn Harness: mark note finished" })
  vim.api.nvim_create_user_command("LHUnfinished", list_unfinished, { desc = "Learn Harness: list unfinished notes" })
  local wiki = vim.fn.resolve(vim.fn.expand(opts.wiki))
  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = vim.api.nvim_create_augroup("LearnHarness", { clear = true }),
    pattern = "*.md",
    callback = function(ev)
      local path = vim.fn.resolve(vim.fn.fnamemodify(ev.file, ":p"))
      if path:sub(1, #wiki) == wiki and not vim.b[ev.buf].lh_attached then
        vim.b[ev.buf].lh_attached = true
        attach(ev.buf)
      end
    end,
  })
end

M.setup({
  -- wiki = "~/zettelkasten",
  -- harness = "~/proj/learn_harness",      -- only used to find workspace/stubs
  -- prefix = "<leader>l",
})
