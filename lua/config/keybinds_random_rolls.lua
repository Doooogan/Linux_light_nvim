
vim.keymap.set("n", "<leader>rae", function()
  local path = vim.fn.expand("~/zettelkasten/Encounter Table-202508052246.md")
  local levels = {
    ["1"] = "### D20 Encounters %(Wonderland Lvl 1%)",
    ["2"] = "### D20 Encounters %(Wonderland Lvl 2%)",
    ["3"] = "### D20 Encounters %(Wonderland Lvl 3%)",
    ["p"] = "### D20 Encounters %(Pandæmonium%)",
  }

  vim.ui.select({ "1", "2", "3", "p" }, {
    prompt = "Which encounter level? (1/2/3/p)",
    format_item = function(item)
      return ({
        ["1"] = "Level 1",
        ["2"] = "Level 2",
        ["3"] = "Level 3",
        ["p"] = "Pandæmonium",
      })[item]
    end
  }, function(choice)
    if not choice then return end

    local file = io.open(path, "r")
    if not file then
      vim.notify("Could not open encounter table file", vim.log.levels.ERROR)
      return
    end

    local lines = {}
    for line in file:lines() do table.insert(lines, line) end
    file:close()

    -- Locate the section header
    local pattern = levels[choice]
    local start_idx = nil
    for i, line in ipairs(lines) do
      if line:match(pattern) then
        start_idx = i
        break
      end
    end

    if not start_idx then
      vim.notify("Could not find selected encounter table", vim.log.levels.ERROR)
      return
    end

    -- Extract rows of the markdown table

    -- Extract rows of the markdown table
    local encounters = {}
    local i = start_idx
    local table_started = false
    local table_row_count = 0

    while i <= #lines and table_row_count < 20 do
      local line = lines[i]
      -- Skip header and divider lines
      if line:match("^|%s*D20%s*|") then
        table_started = true
      elseif table_started and not line:match("^|%s*-") then
        -- Actual data rows
        local cols = vim.split(line, "|", { trimempty = true })
        if #cols >= 2 and tonumber(vim.trim(cols[1])) then
          table.insert(encounters, vim.trim(cols[2]))
          table_row_count = table_row_count + 1
        end
      end
      i = i + 1
    end
    if #encounters < 20 then
      vim.notify("Table does not contain 20 entries", vim.log.levels.WARN)
      return
    end

    -- Roll
    local roll = math.random(1, 20)
    local option_roll = math.random(1, 6)
    local pair = vim.split(encounters[roll], "/", { trimempty = true })
    for j, val in ipairs(pair) do pair[j] = vim.trim(val) end
    local result = pair[option_roll <= 3 and 1 or 2] or pair[1]
    local output = string.format("%d. %s", roll, result)

    vim.fn.setreg('"', output)
    vim.notify("Copied: " .. output, vim.log.levels.INFO, { title = "Encounter Roll" })
  end)
end, { noremap = true, silent = true, desc = "Roll encounter from external file" })



vim.keymap.set("n", "<leader>ra", function()
  local path = vim.fn.expand("~/zettelkasten/Accident Table-202508052249.md")
  local sections = {
    Ceiling = "### D10 Accidents Waiting to Happen %(Ceiling%)",
    Chest   = "### D10 Accidents Waiting to Happen %(Chest%)",
    Door    = "### D10 Accidents Waiting to Happen %(Door%)",
    Floor   = "### D10 Accidents Waiting to Happen %(Floor%)",
  }

  vim.ui.select(vim.tbl_keys(sections), {
    prompt = "Which accident type?",
  }, function(choice)
    if not choice then return end

    local file = io.open(path, "r")
    if not file then
      vim.notify("Could not open accident table file", vim.log.levels.ERROR)
      return
    end

    local lines = {}
    for line in file:lines() do table.insert(lines, line) end
    file:close()

    -- Locate header line
    local pattern = sections[choice]
    local start_idx = nil
    for i, line in ipairs(lines) do
      if line:match(pattern) then
        start_idx = i + 1
        break
      end
    end

    if not start_idx then
      vim.notify("Could not find section for " .. choice, vim.log.levels.ERROR)
      return
    end

    -- Extract 10 numbered entries (supporting wrapped lines)
    local entries = {}
    local i = start_idx
    while i <= #lines and #entries < 10 do
      local num, text = lines[i]:match("^(%d+)%.%s*%*%*(.-)%*%*%s*[–-]%s*(.+)")
      if num and text then
        local full = text .. " – " .. lines[i]:match("–%s*(.+)") or ""
        -- local full = num .. ". " .. text .. " – " .. lines[i]:match("–%s*(.+)") or ""
        i = i + 1
        while i <= #lines and not lines[i]:match("^%d+%.") and lines[i]:match("%S") do
          full = full .. " " .. vim.trim(lines[i])
          i = i + 1
        end
        table.insert(entries, vim.trim(full))
      else
        i = i + 1
      end
    end

    if #entries < 10 then
      vim.notify("Only found " .. #entries .. " accident entries", vim.log.levels.WARN)
      return
    end

    local roll = math.random(1, 10)
    local result = entries[roll]
    vim.fn.setreg('"', result)
    vim.notify("Rolled: " .. result, vim.log.levels.INFO, { title = "Accident: " .. choice })
  end)
end, { noremap = true, silent = true, desc = "Roll random accident from external file" })



local function roll_from_file(path, count)
  local lines = {}
  local f = io.open(path, "r")
  if not f then
    vim.notify("Could not open file: " .. path, vim.log.levels.ERROR)
    return
  end

  for line in f:lines() do
    table.insert(lines, line)
  end
  f:close()

  -- Extract 100 entries
  local entries = {}
  local i = 1
  while i <= #lines and #entries < 100 do
    local number, text = lines[i]:match("^(%d+)%.%s*(.+)")
    if number then
      local entry = text
      i = i + 1
      while i <= #lines and not lines[i]:match("^%d+%.") and lines[i]:match("%S") do
        entry = vim.trim(lines[i])
        i = i + 1
      end
      table.insert(entries, vim.trim(entry))
    else
      i = i + 1
    end
  end

  if #entries < 100 then
    vim.notify("Less than 100 entries found in file", vim.log.levels.WARN)
    return
  end

  local results = {}
  for _ = 1, count do
    local roll = math.random(1, 100)
    table.insert(results, entries[roll])
  end

  local output = table.concat(results, "\n")
  vim.fn.setreg('"', output)
  vim.notify("Rolled " .. count .. " entries from " .. vim.fn.fnamemodify(path, ":t"), vim.log.levels.INFO)
end




vim.keymap.set("n", "<leader>rde", function()
  vim.ui.input({ prompt = "How many rolls? (default 1): " }, function(input)
    local count = tonumber(input) or 1
    roll_from_file(vim.fn.expand("~/zettelkasten/Major Dreamon Eccentricities-202508052313.md"), count)
  end)
end, { noremap = true, silent = true, desc = "Roll Dreamon Eccentricities" })



vim.keymap.set("n", "<leader>rdm", function()
  local path = vim.fn.expand("~/zettelkasten/Minor Dreamons-202508052315.md")

  vim.ui.input({ prompt = "How many Minor Dreamons? (1-100, default 1): " }, function(input)
    local count = tonumber(input) or 1
    if count < 1 or count > 100 then
      vim.notify("Please enter a number between 1 and 100", vim.log.levels.WARN)
      return
    end

    local file = io.open(path, "r")
    if not file then
      vim.notify("Could not open Minor Dreamons file", vim.log.levels.ERROR)
      return
    end

    local lines = {}
    for line in file:lines() do table.insert(lines, line) end
    file:close()

    -- Find the start of the D100 appearance list
    local start_idx = nil
    for i, line in ipairs(lines) do
      if line:match("### D100 Minor Dreamon %(Appearance%)") then
        start_idx = i + 1
        break
      end
    end

    if not start_idx then
      vim.notify("Could not find D100 appearance list", vim.log.levels.ERROR)
      return
    end

    -- Extract entries
    local entries = {}
    local i = start_idx
    while i <= #lines and #entries < 100 do
      local num, desc = lines[i]:match("^(%d+)[%.%-]%s*(.+)")
      if num and desc then
        table.insert(entries, desc)
      elseif lines[i]:match("^00[%.%-]%s*(.+)") then
        table.insert(entries, "100. " .. lines[i]:match("^00[%.%-]%s*(.+)"))
      end
      i = i + 1
    end

    if #entries < 100 then
      vim.notify("Only found " .. #entries .. " dreamon entries", vim.log.levels.WARN)
      return
    end

    -- Roll and copy
    local results = {}
    for _ = 1, count do
      local roll = math.random(1, 100)
      table.insert(results, entries[roll])
    end

    local output = table.concat(results, "\n")
    vim.fn.setreg('"', output)
    vim.notify("Rolled " .. count .. " Minor Dreamon(s)", vim.log.levels.INFO, {
      title = "Minor Dreamons"
    })
  end)
end, { noremap = true, silent = true, desc = "Roll Minor Dreamons" })




vim.keymap.set("n", "<leader>re", function()
  local path = vim.fn.expand("~/zettelkasten/Encounter Random-202508062343.md")

  local file = io.open(path, "r")
  if not file then
    vim.notify("Could not open Encounter Random.md", vim.log.levels.ERROR)
    return
  end

  local lines = {}
  for line in file:lines() do table.insert(lines, line) end
  file:close()

  -- Find the table start
  local start_idx = nil
  for i, line in ipairs(lines) do
    if line:match("^|%s*Roll%s*|%s*Result%s*|") then
      start_idx = i + 2 -- skip header and divider
      break
    end
  end

  if not start_idx then
    vim.notify("Could not find encounter table", vim.log.levels.WARN)
    return
  end

  -- Parse the table into a lookup list
  local table_map = {}
  for i = start_idx, #lines do
    local line = lines[i]
    if not line:match("^|") then break end
    local cols = vim.split(line, "|", { trimempty = true })
    if #cols >= 2 then
      local key = vim.trim(cols[1])
      local result = vim.trim(cols[2])
      if key:match("%d+%s*%–%s*%d+") then
        local low, high = key:match("(%d+)%s*%–%s*(%d+)")
        for r = tonumber(low), tonumber(high) do
          table_map[r] = result
        end
      elseif tonumber(key) then
        table_map[tonumber(key)] = result
      end
    end
  end

  -- Roll
  local roll = math.random(1, 20)
  local result = table_map[roll] or "Unknown Result"

  local output = result
  vim.fn.setreg('"', output)
  vim.notify("Rolled: " .. output, vim.log.levels.INFO, { title = "Random Encounter" })
end, { noremap = true, silent = true, desc = "Roll from Random Encounter Table" })





vim.keymap.set("n", "<leader>rr", function()
  vim.ui.input({ prompt = "Enter dice (e.g. 3d6+2): " }, function(expr)
    if not expr then return end

    -- Extract dice and optional modifier
    local num, sides, mod = expr:lower():match("^(%d+)%s*d%s*(%d+)%s*([%+%-]?%s*%d*)$")
    num = tonumber(num)
    sides = tonumber(sides)
    mod = mod and mod:gsub("%s", "") or ""

    if mod == "" or mod == "+" or mod == "-" then
      mod = 0
    else
      mod = tonumber(mod) or 0
    end

    if not num or not sides or num < 1 or sides < 1 then
      vim.notify("Invalid format. Use e.g. 2d6+1", vim.log.levels.WARN)
      return
    end

    -- Roll the dice
    local results = {}
    for _ = 1, num do
      table.insert(results, math.random(1, sides))
    end

    local sum = 0
    for _, v in ipairs(results) do sum = sum + v end
    local total = sum + mod

    -- Build output
    local mod_str = string.format("%s%d", mod >= 0 and "+" or "-", math.abs(mod))
    local output = string.format(
      "%dd%d%s → [%s] %s %d = %d",
      num, sides, mod_str,
      table.concat(results, ", "),
      mod >= 0 and "+" or "-",
      math.abs(mod),
      total
    )

    vim.fn.setreg('"', output)
    vim.notify(output, vim.log.levels.INFO, { title = "Dice Roll" })
  end)
end, { noremap = true, silent = true, desc = "Roll dice with modifier" })


vim.keymap.set('n', '<leader>ol', function()
  local line = vim.api.nvim_get_current_line()
  -- Match: optional letter + " = " + name, ignoring trailing " (2nd)" etc.
  local name = line:match("^%s*%a?%s*=%s*(.+)$")
  if not name then
    vim.notify("No match on this line", vim.log.levels.WARN)
    return
  end
  -- Strip trailing " (2nd)", " (3rd)", etc.
  name = name:gsub("%s*%(%w+%)%s*$", "")
  local path = "/home/doogan/proj/wonderland/split_levels/" .. name .. ".pdf"
  vim.fn.jobstart({ "xdg-open", path }, { detach = true })
end, { desc = "Open room PDF" })
