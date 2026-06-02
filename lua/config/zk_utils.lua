
local M = {}

----------------------------------------------------------
-- Utility Helpers
----------------------------------------------------------

local function get_telekasten_home()
  local tk = require("telekasten")
  local cfg = tk.cfg or tk.CONFIG or {}
  local home = cfg.home or vim.g.telekasten_home or "~/zettelkasten"
  return vim.fn.expand(home)
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local content = f:read("*a")
  f:close()
  return content
end

local function read_frontmatter_title(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end

  local in_frontmatter = false
  for line in f:lines() do
    if line:match("^%s*%-%-%-%s*$") then
      if not in_frontmatter then
        in_frontmatter = true
      else
        break
      end
    elseif in_frontmatter then
      local t = line:match("^%s*title:%s*(.+)")
      if t then
        f:close()
        return vim.trim(t)
      end
    end
  end

  f:close()
  return nil
end

-- Infer all possible link labels for a file
local function derive_labels_for_path(path)
  local labels = {}
  local seen = {}

  local function add(lbl)
    if lbl and lbl ~= "" and not seen[lbl] then
      seen[lbl] = true
      table.insert(labels, lbl)
    end
  end

  -- filename without extension
  local fname = vim.fn.fnamemodify(path, ":t:r")
  add(fname)

  -- filename without UID
  local base = fname:match("^(.*)%-%d%d%d%d%d%d%d%d%d%d%d%d$")
  if base then
    add(base)
  end

  -- title from frontmatter (optional)
  local title = read_frontmatter_title(path)
  if title then
    add(title)
  end

  return labels
end

----------------------------------------------------------
-- Link Index Builder
----------------------------------------------------------

local function build_link_index(home)
  local files = vim.fn.globpath(home, "**/*.md", false, true)

  local contents = {}
  local incoming_by_label = {}  -- label -> { [src_path] = true }

  for _, path in ipairs(files) do
    local text = read_file(path)
    contents[path] = text

    -- find all [[links]] in this file
    for link in text:gmatch("%[%[([^%]]+)%]%]") do
      local lbl = vim.trim(link)
      if lbl ~= "" then
        incoming_by_label[lbl] = incoming_by_label[lbl] or {}
        incoming_by_label[lbl][path] = true
      end
    end
  end

  return files, contents, incoming_by_label
end

----------------------------------------------------------
-- Core Orphan Detection
----------------------------------------------------------

local function get_orphans_for_tag(tag)
  local home = get_telekasten_home()

  -- normalize input
  tag = tag:gsub("^:", ""):gsub(":$", "")
  if tag == "" then
    return {}
  end

  local full_tag = ":" .. tag .. ":"

  -- Full index of files and links
  local files, contents, incoming_by_label = build_link_index(home)

  -- 1) Collect all files containing :tag:
  local tagged_files = {}
  for _, path in ipairs(files) do
    if contents[path]:find(full_tag, 1, true) then
      table.insert(tagged_files, path)
    end
  end

  if #tagged_files == 0 then
    return {}
  end

  -- 2) Determine which of those files have NO incoming links
  local orphans = {}

  for _, path in ipairs(tagged_files) do
    local labels = derive_labels_for_path(path)
    local has_incoming = false

    for _, lbl in ipairs(labels) do
      local incoming_sources = incoming_by_label[lbl]
      if incoming_sources then
        for src_path, _ in pairs(incoming_sources) do
          if src_path ~= path then
            has_incoming = true
            break
          end
        end
      end
      if has_incoming then break end
    end

    if not has_incoming then
      table.insert(orphans, {
        path = path,
        labels = labels,
      })
    end
  end

  return orphans
end

----------------------------------------------------------
-- Public Commands
----------------------------------------------------------

-- 1) Quickfix-style orphan browser
M.orphans_by_tag = function(tag)
  if not tag or tag == "" then
    tag = vim.fn.input("Tag (without colons): ")
  end

  local orphans = get_orphans_for_tag(tag)
  if #orphans == 0 then
    print("No orphan notes found for :" .. tag .. ":")
    return
  end

  local qf = {}
  for _, o in ipairs(orphans) do
    table.insert(qf, {
      filename = o.path,
      lnum = 1,
      col = 1,
      text = "orphan :" .. tag .. ":",
    })
  end

  vim.fn.setqflist({}, " ", {
    title = "Orphan notes for :" .. tag .. ":",
    items = qf,
  })
  vim.cmd("copen")
end

-- 2) Insert orphan links directly into the current file
M.insert_orphan_links_by_tag = function(tag)
  if not tag or tag == "" then
    tag = vim.fn.input("Tag (without colons): ")
  end

  local orphans = get_orphans_for_tag(tag)
  if #orphans == 0 then
    print("No orphan notes found for :" .. tag .. ":")
    return
  end

  local lines = {}

  for _, o in ipairs(orphans) do
    local fname = vim.fn.fnamemodify(o.path, ":t:r")  -- filename without extension
    local link = string.format("[[%s]]", fname)
    table.insert(lines, link)
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]  -- 1-based
  vim.api.nvim_buf_set_lines(0, row, row, true, lines)

  print(string.format("Inserted %d orphan links for :%s:", #orphans, tag))
end

return M
