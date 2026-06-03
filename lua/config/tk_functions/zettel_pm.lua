-- =====================================================================
-- Lightweight project / ticketing layer for a Telekasten markdown vault
-- =====================================================================
-- Slots in alongside your existing fleeting-note config. It reuses the
-- same `vault` path, the same `due_date` / `snooze_count` frontmatter, and
-- the same buffer-local snooze keymaps (ss / sm / sl). Pure markdown — the
-- files on disk are the single source of truth; the agenda is just a query.
--
-- THREE NOTE TYPES (distinguished by a body marker line):
--   :fleeting:   raw capture (your existing flow)
--   :project:    frontmatter + ordered "- [ ]" steps; next step = first unchecked
--   :ticket:     standalone action; the ticket itself is the step
--
-- FRONTMATTER on projects + tickets:
--   title, status (todo/doing/blocked/done), priority (A/B/C),
--   deadline (hard "must be done by", optional),
--   due_date  (start/snooze date — empty or past = visible, future = hidden),
--   snooze_count
--
-- AGENDA (read-only scratch buffer):
--   top line  -> "Fleeting: N unprocessed · M snoozing"
--                unprocessed = fleeting with empty due_date
--                snoozing    = fleeting with future due_date
--   body      -> active projects (title + next unchecked step)
--                active tickets (title)
--   hidden    -> done / future due_date / fully-checked projects
--   sorted    -> by deadline (overdue/soonest first), then priority
--   <CR>      -> jump to file ; r -> refresh ; q -> close
--
-- AUTO-ARCHIVE: when status: done, the file is moved to <vault>/done/ — but
--   only once you LEAVE the buffer (BufUnload), so the live buffer is never
--   touched or re-pointed. A missed move (crash) is cosmetic: the agenda
--   filters status: done regardless.
--
-- PROMOTION: <leader>zP on a fleeting note -> guided wizard (type, priority,
--   due date, deadline). Transforms IN PLACE (same file, backlinks survive).
--   Escape at any prompt aborts; the note stays fleeting, untouched.
--
-- ---------------------------------------------------------------------
-- KEYMAP CHEATSHEET
-- ---------------------------------------------------------------------
--   GLOBAL
--     <leader>za   open the agenda (also :Agenda)
--
--   IN THE AGENDA BUFFER
--     <Tab>        jump to next item (wraps)
--     <S-Tab>      jump to previous item (wraps)
--     <CR>         jump to the project/ticket under the cursor
--     z            toggle show/hide snoozed items
--     r            refresh (recompute from disk)
--     q            close the agenda
--
--   ON A FLEETING NOTE
--     <leader>zP   promote → project/ticket (name, type, priority, dates; Esc aborts)
--     ss / sm / sl snooze 1 / 3 / 7 days   (from your existing config)
--     <leader>zp   process next due fleeting note (your existing config)
--
--   VISUAL SELECTION (any buffer)
--     <leader>zb   batch-create: run the wizard once per selected line.
--                  Each line → its own ticket or project (you choose per line).
--                  Esc on a line skips just that line. Source lines are kept.
--
--   ON A PROJECT / TICKET
--     ss / sm / sl snooze 1 / 3 / 7 days (rewrites due_date forward)
--     (set "status: done" + leave the buffer → auto-archived to done/)
-- =====================================================================

local M = {}

-- Reuse the same vault path as the fleeting-note config.
local vault = vim.fn.expand("~/zettelkasten/")
local done_dir = vault .. "done/"

local STATUSES   = { "todo", "doing", "blocked", "done" }
local PRIORITIES = { "A", "B", "C" }

-- ---------------------------------------------------------------------
-- Small date helpers (all dates are plain YYYY-MM-DD strings)
-- ---------------------------------------------------------------------
local function today_str()
    return os.date("%Y-%m-%d")
end

-- Compare two YYYY-MM-DD strings lexically — valid because the format is
-- fixed-width and zero-padded, so string order == chronological order.
-- Returns true if `a` is strictly before `b`.
local function date_before(a, b)
    return a < b
end

local function offset_date(days)
    return os.date("%Y-%m-%d", os.time() + days * 86400)
end

-- ---------------------------------------------------------------------
-- File scanning
-- ---------------------------------------------------------------------
-- Read a note: returns (frontmatter_table, marker_type, body_lines).
-- marker_type is "fleeting" | "project" | "ticket" | nil.
-- We must scan the whole file because the marker lives in the body.
local function read_note(file)
    local fm = {}
    local body = {}
    local marker = nil
    local fence = 0
    local in_fm = false
    local fh = io.open(file, "r")
    if not fh then return fm, marker, body end
    for line in fh:lines() do
        if line:match("^%-%-%-%s*$") then
            fence = fence + 1
            in_fm = (fence == 1)
            if fence >= 2 then
                -- frontmatter closed; remaining lines are body
                in_fm = false
            end
        elseif in_fm then
            local k, v = line:match("^([%w_]+):%s*(.*)$")
            if k then
                -- trim trailing whitespace from value
                fm[k] = (v:gsub("%s+$", ""))
            end
        else
            table.insert(body, line)
            if line:match(":fleeting:") then marker = "fleeting" end
            if line:match(":project:")  then marker = "project"  end
            if line:match(":ticket:")   then marker = "ticket"   end
        end
    end
    fh:close()
    return fm, marker, body
end

-- Is an item snoozed right now? (status ~= done AND due_date in the future)
local function is_snoozed(fm)
    if (fm.status or "") == "done" then return false end
    local due = fm.due_date or ""
    if due == "" then return false end
    return date_before(today_str(), due)  -- today < due
end

-- Is an item visible in the (default) agenda right now?
-- Visible when: status ~= done AND (due_date empty OR due_date <= today).
local function is_active(fm)
    if (fm.status or "") == "done" then return false end
    local due = fm.due_date or ""
    if due == "" then return true end
    return not date_before(today_str(), due)  -- due <= today
end

-- First unchecked "- [ ]" step in a project body, or nil if none remain.
local function next_step(body)
    for _, line in ipairs(body) do
        if line:match("^%s*%-%s*%[%s%]") then
            -- strip the "- [ ] " prefix for display
            local text = line:gsub("^%s*%-%s*%[%s%]%s*", "")
            return text
        end
    end
    return nil
end

-- Priority sort key: A < B < C < (blank). Blank/unknown sorts last.
local function prio_rank(p)
    for i, v in ipairs(PRIORITIES) do
        if p == v then return i end
    end
    return #PRIORITIES + 1
end

-- Deadline sort key: a real date sorts by date; empty sorts last.
-- Fixed-width YYYY-MM-DD means string order == chronological order.
-- Empty -> "9999-99-99" sentinel so undated items fall to the bottom.
local function deadline_key(d)
    if d == nil or d == "" then return "9999-99-99" end
    return d
end

-- ---------------------------------------------------------------------
-- Agenda data collection
-- ---------------------------------------------------------------------
local function collect(show_snoozed)
    local items = {}        -- {file, kind, title, step, priority, deadline, status, snoozed}
    local fleeting_unprocessed = 0
    local fleeting_snoozing = 0
    local today = today_str()

    for _, file in ipairs(vim.fn.glob(vault .. "*.md", false, true)) do
        local fm, marker = read_note(file)

        if marker == "fleeting" then
            local due = fm.due_date or ""
            if due == "" then
                fleeting_unprocessed = fleeting_unprocessed + 1
            elseif date_before(today, due) then
                fleeting_snoozing = fleeting_snoozing + 1
            end

        elseif marker == "project" or marker == "ticket" then
            local snoozed = is_snoozed(fm)
            -- Include if active, or (if showing snoozed) snoozed.
            local include = is_active(fm) or (show_snoozed and snoozed)
            if include then
                local title = (fm.title and fm.title ~= "" and fm.title)
                    or vim.fn.fnamemodify(file, ":t")
                if marker == "project" then
                    -- need the body again for steps
                    local _, _, body = read_note(file)
                    local step = next_step(body)
                    -- A project with no unchecked steps is effectively done;
                    -- hide it from the agenda.
                    if step ~= nil then
                        table.insert(items, {
                            file = file, kind = "project", title = title,
                            step = step, priority = fm.priority or "",
                            deadline = fm.deadline or "",
                            status = fm.status or "", snoozed = snoozed,
                            due_date = fm.due_date or "",
                        })
                    end
                else
                    table.insert(items, {
                        file = file, kind = "ticket", title = title,
                        step = nil, priority = fm.priority or "",
                        deadline = fm.deadline or "",
                        status = fm.status or "", snoozed = snoozed,
                        due_date = fm.due_date or "",
                    })
                end
            end
        end
    end

    -- Sort by priority, then deadline (soonest/overdue first) as tiebreaker,
    -- then title. Section grouping is applied at render time.
    table.sort(items, function(a, b)
        local pa, pb = prio_rank(a.priority), prio_rank(b.priority)
        if pa ~= pb then return pa < pb end
        local ka, kb = deadline_key(a.deadline), deadline_key(b.deadline)
        if ka ~= kb then return ka < kb end
        return a.title < b.title
    end)

    return items, fleeting_unprocessed, fleeting_snoozing
end

-- ---------------------------------------------------------------------
-- Agenda rendering
-- ---------------------------------------------------------------------
local agenda_buf = nil
local show_snoozed = false  -- agenda toggle: include snoozed items?

local function render_agenda()
    local items, unprocessed, snoozing = collect(show_snoozed)
    local lines = {}
    local line_targets = {}  -- maps buffer line number -> file path
    local header_rows = {}   -- ordered list of item-header line numbers

    local mode = show_snoozed and "showing snoozed" or "hiding snoozed"
    table.insert(lines, string.format(
        "Fleeting: %d unprocessed · %d snoozing   [%s — 'z' to toggle]",
        unprocessed, snoozing, mode))
    table.insert(lines, string.rep("─", 60))
    table.insert(lines, "")

    -- Bucket into sections. Active projects, active tickets, and (if shown)
    -- snoozed items of either kind. `items` is already priority-sorted, so
    -- each bucket preserves priority order.
    local projects, tickets, snoozed_items = {}, {}, {}
    for _, it in ipairs(items) do
        if it.snoozed then
            table.insert(snoozed_items, it)
        elseif it.kind == "project" then
            table.insert(projects, it)
        else
            table.insert(tickets, it)
        end
    end

    -- Render one item: appends its line(s) and records jump targets / headers.
    local function emit_item(it)
        local prio = (it.priority ~= "" and it.priority) or "-"
        local dl   = (it.deadline ~= "" and ("  ⏰ due " .. it.deadline)) or ""
        local tag  = (it.kind == "project") and "[P]" or "[T]"
        local extra = ""
        if it.snoozed then
            local st = (it.status ~= "" and it.status) or "todo"
            extra = string.format("  💤 %s until %s", st, it.due_date)
        end
        local header = string.format("%s %s  (%s)%s%s", tag, it.title, prio, dl, extra)
        table.insert(lines, header)
        line_targets[#lines] = it.file
        table.insert(header_rows, #lines)
        if it.kind == "project" and it.step then
            table.insert(lines, "      → " .. it.step)
            line_targets[#lines] = it.file
            table.insert(lines, "")  -- spacer so multi-line entries don't merge
        end
    end

    -- Render a titled section, or a placeholder if empty.
    local function emit_section(title, bucket, empty_msg)
        table.insert(lines, "")
        table.insert(lines, "━━ " .. title .. " ━━")
        table.insert(lines, "")
        if #bucket == 0 then
            if empty_msg then table.insert(lines, "  " .. empty_msg) end
        else
            for _, it in ipairs(bucket) do
                emit_item(it)
            end
        end
    end

    emit_section("PROJECTS", projects, "(none)")
    emit_section("TICKETS",  tickets,  "(none)")
    if show_snoozed then
        emit_section("SNOOZED", snoozed_items, "(none)")
    end

    -- Create or reuse the scratch buffer.
    if not agenda_buf or not vim.api.nvim_buf_is_valid(agenda_buf) then
        agenda_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(agenda_buf, "[Agenda]")
        vim.bo[agenda_buf].buftype = "nofile"
        vim.bo[agenda_buf].bufhidden = "hide"
        vim.bo[agenda_buf].swapfile = false
        vim.bo[agenda_buf].filetype = "markdown"
    end

    vim.bo[agenda_buf].modifiable = true
    vim.api.nvim_buf_set_lines(agenda_buf, 0, -1, false, lines)
    vim.bo[agenda_buf].modifiable = false

    -- Stash the line->file map on the buffer for the <CR> handler.
    vim.b[agenda_buf].line_targets = line_targets
    vim.b[agenda_buf].header_rows = header_rows

    -- Place the cursor on the first item header (if any) on open/refresh.
    if header_rows[1] then
        pcall(vim.api.nvim_win_set_cursor, 0, { header_rows[1], 0 })
    end

    -- Buffer-local keymaps.
    local opts = { buffer = agenda_buf, silent = true }
    vim.keymap.set("n", "<CR>", function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local targets = vim.b[agenda_buf].line_targets or {}
        local target = targets[row]
        if target then
            vim.cmd("edit " .. vim.fn.fnameescape(target))
        end
    end, opts)

    -- Tab / Shift-Tab: jump to next / previous item header, wrapping around.
    local function jump(dir)
        local rows = vim.b[agenda_buf].header_rows or {}
        if #rows == 0 then return end
        local cur = vim.api.nvim_win_get_cursor(0)[1]
        local target
        if dir > 0 then
            for _, r in ipairs(rows) do
                if r > cur then target = r; break end
            end
            target = target or rows[1]            -- wrap to first
        else
            for i = #rows, 1, -1 do
                if rows[i] < cur then target = rows[i]; break end
            end
            target = target or rows[#rows]        -- wrap to last
        end
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
    vim.keymap.set("n", "<Tab>",   function() jump(1)  end, opts)
    vim.keymap.set("n", "<S-Tab>", function() jump(-1) end, opts)

    vim.keymap.set("n", "r", function() render_agenda() end, opts)
    vim.keymap.set("n", "z", function()
        show_snoozed = not show_snoozed
        render_agenda()
    end, opts)
    vim.keymap.set("n", "q", function() vim.cmd("bdelete") end, opts)

    return agenda_buf
end

local function open_agenda()
    local buf = render_agenda()
    -- Open in current window (swap to a split if you prefer: vim.cmd("vsplit")).
    vim.api.nvim_set_current_buf(buf)
end

-- ---------------------------------------------------------------------
-- Auto-archive: move done items to done/ on buffer leave (never the live one)
-- ---------------------------------------------------------------------
-- Returns the value of `status:` from a file's frontmatter, or "".
local function file_status(file)
    local fm = read_note(file)
    return fm.status or ""
end

local function ensure_done_dir()
    if vim.fn.isdirectory(done_dir) == 0 then
        vim.fn.mkdir(done_dir, "p")
    end
end

vim.api.nvim_create_autocmd("BufUnload", {
    pattern = vault .. "*.md",
    callback = function(args)
        local file = args.file
        -- Only touch files directly in the vault root (not already in done/).
        if file:match("/done/") then return end
        if vim.fn.filereadable(file) == 0 then return end

        -- Re-read from disk (the buffer is going away; disk is source of truth).
        if file_status(file) ~= "done" then return end

        ensure_done_dir()
        local name = vim.fn.fnamemodify(file, ":t")
        local target = done_dir .. name
        -- Avoid clobbering an existing archived file of the same name.
        if vim.fn.filereadable(target) == 1 then
            target = done_dir .. os.date("%Y%m%d%H%M%S_") .. name
        end
        local ok = os.rename(file, target)
        if ok then
            vim.schedule(function()
                vim.notify("Archived → done/" .. vim.fn.fnamemodify(target, ":t"),
                    vim.log.levels.INFO)
            end)
        end
    end,
})

-- ---------------------------------------------------------------------
-- Promotion wizard: fleeting -> project | ticket (in place)
-- ---------------------------------------------------------------------
-- vim.ui.select / vim.ui.input are async (callback style). We chain them,
-- and any cancellation (Esc / empty) aborts. run_wizard collects the choices
-- and hands them to on_complete{kind,name,priority,due_date,deadline}; on
-- abort it calls on_abort (used by the batch flow to skip to the next line).
-- ---------------------------------------------------------------------
local function run_wizard(default_name, on_complete, on_abort)
    on_abort = on_abort or function() end

    -- Step 1: name (prefilled with default_name; empty aborts)
    vim.ui.input({ prompt = "Name: ", default = default_name or "" },
    function(name)
        if not name or name == "" then return on_abort() end
        name = name:gsub("%s+$", "")

    -- Step 2: type
    vim.ui.select({ "Project", "Ticket" }, { prompt = "Type:" },
    function(kind_choice)
        if not kind_choice then return on_abort() end
        local marker_new = (kind_choice == "Project") and ":project:" or ":ticket:"

        -- Step 3: priority
        vim.ui.select(PRIORITIES, { prompt = "Priority:" },
        function(priority)
            if not priority then return on_abort() end

            -- Step 4: due date (start/snooze date)
            local due_choices = {
                "Today", "Tomorrow", "In 3 days", "In a week", "Pick a date…",
            }
            vim.ui.select(due_choices, { prompt = "Start (due_date):" },
            function(due_choice)
                if not due_choice then return on_abort() end

                local function with_due(due_date)
                    -- Step 5: deadline (hard due-by) with a None option
                    local dl_choices = {
                        "None", "Today", "Tomorrow", "In 3 days",
                        "In a week", "Pick a date…",
                    }
                    vim.ui.select(dl_choices, { prompt = "Deadline (hard due-by):" },
                    function(dl_choice)
                        if not dl_choice then return on_abort() end

                        local function finish(deadline)
                            on_complete({
                                marker_new = marker_new,
                                name = name,
                                priority = priority,
                                due_date = due_date,
                                deadline = deadline,
                            })
                        end

                        if dl_choice == "None" then
                            finish("")
                        elseif dl_choice == "Today" then
                            finish(today_str())
                        elseif dl_choice == "Tomorrow" then
                            finish(offset_date(1))
                        elseif dl_choice == "In 3 days" then
                            finish(offset_date(3))
                        elseif dl_choice == "In a week" then
                            finish(offset_date(7))
                        else  -- pick a date
                            vim.ui.input({ prompt = "Deadline (YYYY-MM-DD): " },
                            function(input)
                                if not input or input == "" then return on_abort() end
                                finish(input)
                            end)
                        end
                    end)
                end

                if due_choice == "Today" then
                    with_due(today_str())
                elseif due_choice == "Tomorrow" then
                    with_due(offset_date(1))
                elseif due_choice == "In 3 days" then
                    with_due(offset_date(3))
                elseif due_choice == "In a week" then
                    with_due(offset_date(7))
                else  -- pick a date
                    vim.ui.input({ prompt = "Start date (YYYY-MM-DD): " },
                    function(input)
                        if not input or input == "" then return on_abort() end
                        with_due(input)
                    end)
                end
            end)
        end)
    end)
    end)  -- close function(name)
end

local function promote_fleeting()
    local bufnr = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(bufnr)

    -- Confirm this really is a fleeting note before doing anything.
    local _, marker = read_note(file)
    if marker ~= "fleeting" then
        vim.notify("Not a fleeting note — nothing to promote.", vim.log.levels.WARN)
        return
    end

    run_wizard(nil, function(choice)
        apply_promotion(bufnr, file, choice.marker_new, choice.priority,
            choice.due_date, choice.deadline, choice.name)
    end)
end

-- Transform the buffer in place: keep title/created_date/due_date/snooze_count,
-- add status/priority/deadline, swap the marker, seed a Steps section for
-- projects. Writes the file.
function apply_promotion(bufnr, file, marker_new, priority, due_date, deadline, name)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    -- Locate frontmatter fences.
    local fm_start, fm_end = nil, nil
    for i, line in ipairs(lines) do
        if line:match("^%-%-%-%s*$") then
            if not fm_start then fm_start = i
            elseif not fm_end then fm_end = i; break end
        end
    end
    if not fm_start or not fm_end then
        vim.notify("Couldn't find frontmatter; aborting promotion.",
            vim.log.levels.ERROR)
        return
    end

    -- Helper: set or insert a key in the frontmatter region.
    local function set_key(key, value)
        for i = fm_start + 1, fm_end - 1 do
            if lines[i]:match("^" .. key .. ":") then
                lines[i] = key .. ": " .. value
                return
            end
        end
        -- not present: insert just before the closing fence
        table.insert(lines, fm_end, key .. ": " .. value)
        fm_end = fm_end + 1
    end

    set_key("title", name)
    set_key("status", "todo")
    set_key("priority", priority)
    set_key("due_date", due_date)
    set_key("deadline", deadline)
    -- ensure snooze_count exists
    set_key("snooze_count",
        (function()
            for i = fm_start + 1, fm_end - 1 do
                local c = lines[i]:match("^snooze_count:%s*(%d+)")
                if c then return c end
            end
            return "0"
        end)())

    -- Swap the body marker.
    for i = fm_end + 1, #lines do
        if lines[i]:match(":fleeting:") then
            lines[i] = lines[i]:gsub(":fleeting:", marker_new)
        end
    end

    -- For projects, seed an empty Steps section if none exists yet.
    if marker_new == ":project:" then
        local has_step = false
        for i = fm_end + 1, #lines do
            if lines[i]:match("^%s*%-%s*%[%s%]") then has_step = true break end
        end
        if not has_step then
            table.insert(lines, "")
            table.insert(lines, "## Steps")
            table.insert(lines, "")
            table.insert(lines, "- [ ] ")
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.cmd("write")

    local label = (marker_new == ":project:") and "project" or "ticket"
    vim.notify(string.format("Promoted to %s (priority %s, start %s%s)",
        label, priority, due_date,
        deadline ~= "" and (", deadline " .. deadline) or ""),
        vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------
-- Create a fresh project/ticket file from scratch (used by batch capture).
-- Mirrors the fleeting-note filename convention: <date>_<slug>.md
-- ---------------------------------------------------------------------
local function slugify(s)
    return (s:gsub("%s+", "-"):gsub("[^%w%-]", ""):lower())
end

local function create_note_file(choice)
    local date = today_str()
    local slug = slugify(choice.name)
    if slug == "" then slug = "untitled" end
    local base = date .. "_" .. slug
    local path = vault .. base .. ".md"
    -- Avoid clobbering an existing file of the same name.
    if vim.fn.filereadable(path) == 1 then
        path = vault .. base .. "_" .. os.date("%H%M%S") .. ".md"
    end

    local body
    if choice.marker_new == ":project:" then
        body = {
            "",
            ":project:",
            "",
            "## Steps",
            "",
            "- [ ] " .. choice.name,
        }
    else
        body = {
            "",
            ":ticket:",
            "",
        }
    end

    local content = table.concat(vim.list_extend({
        "---",
        "title: " .. choice.name,
        "created_date: " .. date,
        "status: todo",
        "priority: " .. choice.priority,
        "due_date: " .. choice.due_date,
        "deadline: " .. choice.deadline,
        "snooze_count: 0",
        "---",
    }, body), "\n")

    local fh = io.open(path, "w")
    if not fh then
        vim.notify("Failed to write " .. path, vim.log.levels.ERROR)
        return false
    end
    fh:write(content)
    fh:close()
    return true, vim.fn.fnamemodify(path, ":t")
end

-- ---------------------------------------------------------------------
-- Batch capture: run the wizard once per selected line, in sequence.
-- Async chaining via recursion — the next line's wizard fires only when the
-- current one completes OR aborts (abort skips just that line).
-- ---------------------------------------------------------------------
local function batch_from_lines(lines)
    -- Keep only non-blank lines, trimmed.
    local pending = {}
    for _, l in ipairs(lines) do
        local t = l:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then table.insert(pending, t) end
    end
    if #pending == 0 then
        vim.notify("No non-blank lines selected.", vim.log.levels.WARN)
        return
    end

    local created = 0
    local total = #pending

    local function process(idx)
        if idx > total then
            vim.notify(string.format("Batch done: created %d of %d.",
                created, total), vim.log.levels.INFO)
            return
        end
        local line = pending[idx]
        vim.notify(string.format("[%d/%d] %s", idx, total, line),
            vim.log.levels.INFO)
        run_wizard(line,
            function(choice)  -- on_complete
                local ok, name = create_note_file(choice)
                if ok then
                    created = created + 1
                    local label = (choice.marker_new == ":project:")
                        and "project" or "ticket"
                    vim.notify(string.format("Created %s: %s", label, name),
                        vim.log.levels.INFO)
                end
                vim.schedule(function() process(idx + 1) end)
            end,
            function()  -- on_abort: skip this line, continue
                vim.schedule(function() process(idx + 1) end)
            end)
    end

    process(1)
end

-- Visual-mode entry point: grab the selected lines and run the batch.
local function batch_from_selection()
    -- Use the '< and '> marks to get the selected line range.
    local s = vim.fn.line("'<")
    local e = vim.fn.line("'>")
    if s == 0 or e == 0 then
        vim.notify("No visual selection found.", vim.log.levels.WARN)
        return
    end
    if s > e then s, e = e, s end
    local lines = vim.api.nvim_buf_get_lines(0, s - 1, e, false)
    batch_from_lines(lines)
end

-- ---------------------------------------------------------------------
-- Buffer-local keymaps for project/ticket files (snooze reuse + promote off)
-- ---------------------------------------------------------------------
-- Your existing fleeting autocmd already sets ss/sm/sl + the fleeting create
-- flow. Here we add: the same snooze keys for projects/tickets, and the
-- promote keymap on fleeting notes.
vim.api.nvim_create_autocmd("BufReadPost", {
    pattern = vault .. "*.md",
    callback = function()
        local file = vim.api.nvim_buf_get_name(0)
        local _, marker = read_note(file)
        local opts = { buffer = 0 }

        if marker == "fleeting" then
            -- Promote a fleeting note (in place) via the wizard.
            vim.keymap.set("n", "<leader>zP", promote_fleeting,
                vim.tbl_extend("force", opts, { desc = "Promote fleeting → project/ticket" }))

        elseif marker == "project" or marker == "ticket" then
            -- Reuse the same snooze semantics as fleeting notes: rewrite
            -- due_date forward and bump snooze_count. (Mirrors your snooze().)
            local function snooze(days)
                local b = vim.api.nvim_get_current_buf()
                local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
                local new_date = offset_date(days)
                for i, line in ipairs(lines) do
                    if line:match("^due_date:") then
                        lines[i] = "due_date: " .. new_date
                    end
                    if line:match("^snooze_count:") then
                        local count = tonumber(line:match("^snooze_count:%s*(%d+)")) or 0
                        lines[i] = "snooze_count: " .. (count + 1)
                    end
                end
                vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
                vim.cmd("write")
                vim.notify("Snoozed " .. days .. " day(s) → " .. new_date,
                    vim.log.levels.INFO)
            end
            vim.keymap.set("n", "ss", function() snooze(1) end, opts)
            vim.keymap.set("n", "sm", function() snooze(3) end, opts)
            vim.keymap.set("n", "sl", function() snooze(7) end, opts)
        end
    end,
})

-- ---------------------------------------------------------------------
-- Top-level command + keymap to open the agenda
-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command("Agenda", open_agenda, {})
vim.keymap.set("n", "<leader>za", open_agenda, { desc = "Open agenda" })

-- Visual-mode batch capture: run the wizard once per selected line.
vim.keymap.set("v", "<leader>zb", function()
    -- Leave visual mode first so the '< '> marks are set, then run.
    vim.cmd('normal! \27')  -- <Esc>
    batch_from_selection()
end, { desc = "Batch create tickets/projects from selected lines" })

M.open_agenda = open_agenda
M.promote_fleeting = promote_fleeting
M.batch_from_selection = batch_from_selection
return M
