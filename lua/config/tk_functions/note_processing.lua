-- Fleeting notes vault path
local vault = vim.fn.expand("~/zettelkasten/")

-- Find and open the next due fleeting note
local function open_next_due()
    local today = os.date("%Y-%m-%d")
    local candidates = {}
    for _, file in ipairs(vim.fn.glob(vault .. "*.md", false, true)) do
        local lines = {}
        for line in io.lines(file) do
            table.insert(lines, line)
        end
        local is_fleeting = false
        local start_date = nil
        local in_frontmatter = false
        for _, line in ipairs(lines) do
            if line:match("^---") then
                in_frontmatter = not in_frontmatter
            end
            if in_frontmatter and line:match("^start_date:%s*$") then
                start_date = today
            elseif in_frontmatter and line:match("^start_date:%s*(.+)") then
                start_date = line:match("^start_date:%s*(.+)")
            end
            if line:match(":fleeting:") then
                is_fleeting = true
            end
        end
        if is_fleeting and start_date and start_date <= today then
            table.insert(candidates, file)
        end
    end
    if #candidates == 0 then
        vim.notify("No fleeting notes due", vim.log.levels.INFO)
        return
    end
    table.sort(candidates)
    vim.cmd("edit " .. vim.fn.fnameescape(candidates[1]))
end
--
-- Delete current fleeting note and move to next
local function delete_and_next()
    local file = vim.api.nvim_buf_get_name(0)
    local name = vim.fn.fnamemodify(file, ":t")
    vim.cmd("bdelete!")
    os.remove(file)
    vim.notify("Deleted: " .. name, vim.log.levels.INFO)
    vim.schedule(function()
        open_next_due()
    end)
end


-- Snooze helper
local function snooze(days)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local today = os.time()
    local new_date = os.date("%Y-%m-%d", today + (days * 86400))
    for i, line in ipairs(lines) do
        if line:match("^start_date:") then
            lines[i] = "start_date: " .. new_date
        end
        if line:match("^snooze_count:") then
            local count = tonumber(line:match("^snooze_count:%s*(%d+)")) or 0
            lines[i] = "snooze_count: " .. (count + 1)
        end
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.cmd("write")
    vim.cmd("bdelete")
    vim.notify("Snoozed " .. days .. " day(s) → " .. new_date, vim.log.levels.INFO)
    vim.schedule(function()
        open_next_due()
    end)
end

-- Buffer-local snooze keymaps for fleeting notes only
vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = vault .. "*.md",
    callback = function()
        local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        for _, line in ipairs(lines) do
            if line:match(":fleeting:") then
                local opts = { buffer = 0 }
                vim.keymap.set("n", "ss", function() snooze(1) end, opts)
                vim.keymap.set("n", "sm", function() snooze(3) end, opts)
                vim.keymap.set("n", "sl", function() snooze(7) end, opts)
                vim.keymap.set("n", "xx", delete_and_next, opts)
                return
            end
        end
    end,
})

-- Create a fleeting note from visual selection
vim.keymap.set("v", "<leader>zcf", function()
    vim.cmd('normal! "zy')
    local selection = vim.fn.getreg("z")
    local title = vim.fn.input("Note title: ")
    if title == "" then return end
    local date = os.date("%Y-%m-%d")
    local filename = date .. "_" .. title:gsub("%s+", "-"):lower() .. ".md"
    local path = vault .. filename
    local content = table.concat({
        "---",
        "title: " .. title,
        "created_date: " .. date,
        "start_date: ",
        "snooze_count: 0",
        "---",
        "",
        ":fleeting:",
        "",
        selection,
    }, "\n")
    local file = io.open(path, "w")
    file:write(content)
    file:close()
    vim.notify("Created: " .. filename, vim.log.levels.INFO)
end, { desc = "New fleeting note from selection" })

-- Process the next due fleeting note
vim.keymap.set("n", "<leader>zp", function()
    open_next_due()
end, { desc = "Process fleeting notes" })
