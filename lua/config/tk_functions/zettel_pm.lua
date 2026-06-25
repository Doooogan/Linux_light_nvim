-- =====================================================================
-- Lightweight project / ticketing layer for a Telekasten markdown vault
-- =====================================================================
-- Slots in alongside your existing fleeting-note config. It reuses the
-- same `vault` path, the same `start_date` / `snooze_count` frontmatter, and
-- the same buffer-local snooze keymaps (ss / sm / sl). Pure markdown — the
-- files on disk are the single source of truth; the agenda is just a query.
--
-- NOTE TYPES (distinguished by a body marker line):
--   :fleeting:   raw capture (your existing flow)
--   :project:    frontmatter + ordered "- [ ]" steps; next step = first unchecked
--   :ticket:     standalone action; the ticket itself is the step
--
-- The wizard also offers "Shopping list" as a type: it short-circuits (no
-- priority/tag/date prompts) and appends the name as a "- [ ]" checkbox to
-- <vault>/shopping.md (created with a "# Shopping" heading if missing). This
-- is NOT a note and never appears in the agenda. Promoting a fleeting note to
-- a shopping item deletes the fleeting note afterward.
--
-- FRONTMATTER on projects + tickets:
--   title, status (todo/doing/blocked/done), priority (A/B/C),
--   deadline (hard "must be done by", optional),
--   start_date  (start/snooze date — empty or past = visible, future = hidden),
--   tags      (colon-wrapped ":tag:" syntax, chosen from the TAGS list below),
--   snooze_count
--
-- AGENDA (read-only scratch buffer):
--   top line  -> "Fleeting: N unprocessed · M snoozing"
--                unprocessed = fleeting with empty start_date
--                snoozing    = fleeting with future start_date
--   body      -> active projects (title + next unchecked step)
--                active tickets (title)
--   hidden    -> done / future start_date / fully-checked projects
--   sorted    -> by deadline (overdue/soonest first), then priority
--   <CR>      -> jump to file ; r -> refresh ; q -> close
--
-- AUTO-ARCHIVE: when status is terminal (done or missed), the file is moved to
--   <vault>/done/ — but only once you LEAVE the buffer (BufUnload), so the live
--   buffer is never touched or re-pointed. A missed move (crash) is cosmetic:
--   the agenda filters terminal statuses regardless. "missed" is kept for
--   post-tracking — it archives alongside "done" but records a slip, not a win.
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
--     <leader>zr   new recurring ticket (master note; also :RecurNew)
--                  [requires the companion zettel_recur.lua module]
--
--   IN THE AGENDA BUFFER
--     <Tab>        jump to next item (wraps)
--     <S-Tab>      jump to previous item (wraps)
--     <CR>         jump to the project/ticket under the cursor
--     z            toggle show/hide snoozed items
--     f            cycle tag filter (all → tag1 → tag2 → … → all)
--     r            refresh (recompute from disk)
--     q            close the agenda
--
--   ON A FLEETING NOTE
--     <leader>zP   promote → project / ticket / shopping list (Esc aborts)
--     ss / sm / sl snooze 1 / 3 / 7 days   (from your existing config)
--     <leader>zp   process next due fleeting note (your existing config)
--
--   VISUAL SELECTION (any buffer)
--     <leader>zb   batch-create: run the wizard once per selected line.
--                  Each line → its own ticket or project (you choose per line).
--                  Esc on a line skips just that line. Source lines are kept.
--
--   ON A PROJECT / TICKET
--     ss / sm / sl snooze 1 / 3 / 7 days (rewrites start_date forward)
--     dn           mark done + save  (archives to done/ on buffer close)
--     dm           mark missed + save (archives to done/ on buffer close)
--     (set "status: done" + leave the buffer → auto-archived to done/)
-- =====================================================================

local M = {}

-- Reuse the same vault path as the fleeting-note config.
local vault = vim.fn.expand("~/zettelkasten/")
local done_dir = vault .. "done/"
local shopping_file = vault .. "shopping.md"

-- Forward declaration: defined later, used by the wizard completion handlers.
local append_shopping

local STATUSES   = { "todo", "doing", "blocked", "done" }
local PRIORITIES = { "A", "B", "C" }

-- Your tag vocabulary. Edit this list to add/remove tags. They show up in the
-- promotion/batch wizard as a single-choice step, and the agenda cycles
-- through them with `f` to filter. Keep them short and lowercase.
local TAGS = { "farm", "errands", "home" }

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

-- Terminal statuses: items in these states drop off the agenda and get
-- archived to done/. "done" = completed, "missed" = slipped (kept for tracking).
local function is_terminal(fm)
    local s = fm.status or ""
    return s == "done" or s == "missed"
end

-- Is an item snoozed right now? (not terminal AND start_date in the future)
local function is_snoozed(fm)
    if is_terminal(fm) then return false end
    local due = fm.start_date or ""
    if due == "" then return false end
    return date_before(today_str(), due)  -- today < due
end

-- Is an item visible in the (default) agenda right now?
-- Visible when: not terminal AND (start_date empty OR start_date <= today).
local function is_active(fm)
    if is_terminal(fm) then return false end
    local due = fm.start_date or ""
    if due == "" then return true end
    return not date_before(today_str(), due)  -- due <= today
end

-- Find the next actionable step in a project body, supporting arbitrary
-- nesting. The "next step" is the first UNCHECKED LEAF — an unchecked box with
-- no unchecked box nested beneath it (if it had unchecked children, you'd do
-- those first). Returns a display string with the ancestor trail for context,
-- e.g. "Item one > Item one subtask", or nil if nothing is left.
--
-- Checked boxes ("[x]") are ignored for display but still parsed so depth/
-- structure is understood correctly.
local function next_step(body)
    -- Parse every checkbox into {depth, checked, text}.
    local boxes = {}
    for _, line in ipairs(body) do
        local indent, mark = line:match("^(%s*)%-%s*%[([%sxX])%]")
        if indent ~= nil then
            local text = line:gsub("^%s*%-%s*%[[%sxX]%]%s*", "")
            table.insert(boxes, {
                depth = #indent,
                checked = (mark ~= " "),
                text = text,
            })
        end
    end
    if #boxes == 0 then return nil end

    -- A box is a leaf if the next box (if any) is NOT deeper than it.
    local function is_leaf(i)
        local nxt = boxes[i + 1]
        if not nxt then return true end
        return nxt.depth <= boxes[i].depth
    end

    -- Walk in order; first unchecked leaf is the next step.
    for i, box in ipairs(boxes) do
        if not box.checked and is_leaf(i) then
            -- Build the ancestor trail: the nearest shallower box at each
            -- decreasing depth above this one (skipping checked ancestors is
            -- unnecessary — an unchecked leaf's parents are unchecked too).
            local trail = {}
            local depth_floor = box.depth
            for j = i - 1, 1, -1 do
                if boxes[j].depth < depth_floor then
                    table.insert(trail, 1, boxes[j].text)
                    depth_floor = boxes[j].depth
                    if depth_floor == 0 then break end
                end
            end
            table.insert(trail, box.text)  -- the leaf itself, last
            return table.concat(trail, " > ")
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
local function collect(show_snoozed, filter_tag)
    local items = {}        -- {file, kind, title, step, priority, deadline, status, snoozed, tags}
    local fleeting_unprocessed = 0
    local fleeting_snoozing = 0
    local today = today_str()

    -- Parse colon-wrapped tags (":tag1: :tag2:") into a trimmed list.
    local function parse_tags(s)
        local out = {}
        for t in (s or ""):gmatch(":([%w%-_]+):") do
            table.insert(out, t)
        end
        return out
    end

    -- Does this item's tag list contain filter_tag? (nil filter = match all)
    local function tag_matches(tags)
        if not filter_tag then return true end
        for _, t in ipairs(tags) do
            if t == filter_tag then return true end
        end
        return false
    end

    for _, file in ipairs(vim.fn.glob(vault .. "*.md", false, true)) do
        local fm, marker = read_note(file)

        if marker == "fleeting" then
            local due = fm.start_date or ""
            if due == "" then
                fleeting_unprocessed = fleeting_unprocessed + 1
            elseif date_before(today, due) then
                fleeting_snoozing = fleeting_snoozing + 1
            end

        elseif marker == "project" or marker == "ticket" then
            local snoozed = is_snoozed(fm)
            local tags = parse_tags(fm.tags)
            -- Include if active (or snoozed when shown) AND passes tag filter.
            local include = (is_active(fm) or (show_snoozed and snoozed))
                and tag_matches(tags)
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
                            start_date = fm.start_date or "", tags = tags,
                        })
                    end
                else
                    table.insert(items, {
                        file = file, kind = "ticket", title = title,
                        step = nil, priority = fm.priority or "",
                        deadline = fm.deadline or "",
                        status = fm.status or "", snoozed = snoozed,
                        start_date = fm.start_date or "", tags = tags,
                        recur_id = fm.recur_id or "",
                    })
                end
            end
        end
    end

    -- Sort by priority, then deadline, then start_date (orders recurring
    -- instances chronologically), then title. Section grouping at render time.
    table.sort(items, function(a, b)
        local pa, pb = prio_rank(a.priority), prio_rank(b.priority)
        if pa ~= pb then return pa < pb end
        local ka, kb = deadline_key(a.deadline), deadline_key(b.deadline)
        if ka ~= kb then return ka < kb end
        local da, db = deadline_key(a.start_date), deadline_key(b.start_date)
        if da ~= db then return da < db end
        return a.title < b.title
    end)

    return items, fleeting_unprocessed, fleeting_snoozing
end

-- ---------------------------------------------------------------------
-- Agenda rendering
-- ---------------------------------------------------------------------
local agenda_buf = nil
local show_snoozed = false  -- agenda toggle: include snoozed items?
local filter_tag = nil      -- active tag filter (nil = show all)

-- Highlight namespace + groups. Linked to sensible defaults so they pick up
-- the user's colorscheme; override these with your own :highlight commands if
-- you want specific shades.
local agenda_ns = vim.api.nvim_create_namespace("zettel_agenda")
local function setup_highlights()
    -- define-default = true: don't clobber user overrides if already set.
    vim.api.nvim_set_hl(0, "ZettelDueOverdue", { fg = "#e06c75", bold = true })  -- red
    vim.api.nvim_set_hl(0, "ZettelDueSoon",    { fg = "#e5a070" })               -- orange
    vim.api.nvim_set_hl(0, "ZettelDueOk",      { fg = "#98c379" })               -- green
    vim.api.nvim_set_hl(0, "ZettelPrio",       { fg = "#61afef", bold = true })  -- priority
    vim.api.nvim_set_hl(0, "ZettelTag",        { fg = "#56b6c2" })               -- tags
    vim.api.nvim_set_hl(0, "ZettelSnooze",     { fg = "#7f848e", italic = true })-- dim
    vim.api.nvim_set_hl(0, "ZettelRecur",      { fg = "#c678dd" })               -- recur date
    vim.api.nvim_set_hl(0, "ZettelSection",    { fg = "#abb2bf", bold = true })  -- headers
    vim.api.nvim_set_hl(0, "ZettelType",       { fg = "#5c6370" })               -- [P]/[T]
end

-- Display width of a string (counts a multibyte UTF-8 char as one column;
-- good enough for the emoji/box chars used here). Byte length is wrong for
-- padding because Lua #s counts bytes, not display columns.
local function disp_width(s)
    local _, count = s:gsub("[%z\1-\127\194-\244]", "")
    return count
end

-- Right-pad a string to `width` display columns (no truncation here).
local function pad_to(s, width)
    local w = disp_width(s)
    if w >= width then return s end
    return s .. string.rep(" ", width - w)
end

-- Truncate to `width` display columns, adding … if cut. UTF-8 safe: walks
-- character boundaries so it never splits a multibyte char.
local function truncate(s, width)
    if disp_width(s) <= width then return s end
    local out, count = {}, 0
    for char in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if count >= width - 1 then break end
        table.insert(out, char)
        count = count + 1
    end
    return table.concat(out) .. "…"
end

-- Days from today until a YYYY-MM-DD date (negative = past). nil if no date.
local function days_until(date_str)
    if not date_str or date_str == "" then return nil end
    local y, m, d = date_str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    local target = os.time({ year = tonumber(y), month = tonumber(m),
        day = tonumber(d), hour = 12 })
    local now = os.time({ year = tonumber(os.date("%Y")),
        month = tonumber(os.date("%m")), day = tonumber(os.date("%d")),
        hour = 12 })
    return math.floor((target - now) / 86400 + 0.5)
end

-- Classify a deadline into a highlight group.
-- THRESHOLDS (edit here): overdue if due today or earlier; soon if within
-- 3 days; ok beyond that.
local function deadline_hl(date_str)
    local d = days_until(date_str)
    if d == nil then return nil end
    if d <= 0 then return "ZettelDueOverdue" end   -- today or past
    if d <= 3 then return "ZettelDueSoon" end       -- within 3 days
    return "ZettelDueOk"
end

local TITLE_WIDTH = 50  -- title column width (truncated past this)

local function render_agenda()
    -- Lazy recurring-ticket generation: spawn any due instances before scanning.
    -- Safe no-op if the recurrence module isn't installed.
    pcall(function() require("config.tk_functions.zettel_recur").generate() end)

    setup_highlights()
    local items, unprocessed, snoozing = collect(show_snoozed, filter_tag)
    local lines = {}
    local line_targets = {}  -- maps buffer line number -> file path
    local header_rows = {}   -- ordered list of item-header line numbers
    local highlights = {}    -- {line0, hl_group, col_start, col_end} (0-indexed)

    local mode = show_snoozed and "showing snoozed" or "hiding snoozed"
    table.insert(lines, string.format(
        "Fleeting: %d unprocessed · %d snoozing   [%s — 'z' to toggle]",
        unprocessed, snoozing, mode))

    -- Tag bar: list all configured tags, marking the active filter. 'f' cycles.
    local tag_parts = {}
    for _, t in ipairs(TAGS) do
        if t == filter_tag then
            table.insert(tag_parts, "[" .. t .. "]")  -- active
        else
            table.insert(tag_parts, t)
        end
    end
    local filter_label = filter_tag and ("filtering: " .. filter_tag) or "all"
    table.insert(lines, string.format(
        "Tags: %s   (%s — 'f' to cycle)",
        table.concat(tag_parts, " · "), filter_label))
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

    -- Render one item: appends its line(s), records jump targets / headers,
    -- and records highlight spans (byte offsets) for color.
    local function emit_item(it)
        local prio = (it.priority ~= "" and it.priority) or "-"
        local tagmark = (it.kind == "project") and "[P]" or "[T]"

        -- Build the line in segments, tracking byte position for highlights.
        -- Layout: "[T] <title padded to TITLE_WIDTH>  (P)  <deadline>  <recur>  <tags>  <snooze>"
        local segments = {}   -- list of {text, hl|nil}
        local function seg(text, hl) table.insert(segments, { text = text, hl = hl }) end

        seg(tagmark .. " ", "ZettelType")
        local disp_title = truncate(it.title, TITLE_WIDTH)
        seg(disp_title, nil)
        -- Pad to TITLE_WIDTH + a 2-space gutter. truncate() guarantees the
        -- title is <= TITLE_WIDTH, so this is always >= 2 (no max() needed,
        -- which previously over-padded exactly-full titles by one column).
        seg(string.rep(" ", (TITLE_WIDTH - disp_width(disp_title)) + 2), nil)

        seg("(" .. prio .. ")", "ZettelPrio")

        -- Deadline column (fixed slot so following columns align even when blank)
        local dl_text, dl_hl = "", nil
        if it.deadline and it.deadline ~= "" then
            dl_text = "⏰ " .. it.deadline
            dl_hl = deadline_hl(it.deadline)
        end
        seg("  ", nil)
        seg(pad_to(dl_text, 16), dl_hl)  -- "⏰ 2026-06-10" ~13 cols, pad to 16

        -- Recurring occurrence date
        if it.recur_id and it.recur_id ~= "" and it.start_date ~= "" then
            seg("↻ " .. it.start_date .. "  ", "ZettelRecur")
        end

        -- Tags
        if it.tags and #it.tags > 0 then
            local wrapped = {}
            for _, t in ipairs(it.tags) do table.insert(wrapped, ":" .. t .. ":") end
            seg(table.concat(wrapped, " ") .. "  ", "ZettelTag")
        end

        -- Snooze annotation
        if it.snoozed then
            local st = (it.status ~= "" and it.status) or "todo"
            seg(string.format("💤 %s until %s", st, it.start_date), "ZettelSnooze")
        end

        -- Assemble line + highlight spans.
        local line = ""
        local line0 = #lines  -- 0-indexed line number this will occupy
        for _, s in ipairs(segments) do
            local start_byte = #line
            line = line .. s.text
            if s.hl then
                table.insert(highlights, { line0, s.hl, start_byte, #line })
            end
        end

        table.insert(lines, line)
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
        table.insert(highlights, { #lines - 1, "ZettelSection", 0, #("━━ " .. title .. " ━━") })
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
        -- No filetype: we apply our own highlights and don't want markdown
        -- syntax competing with them.
    end

    vim.bo[agenda_buf].modifiable = true
    vim.api.nvim_buf_set_lines(agenda_buf, 0, -1, false, lines)
    -- Clear old highlights, then apply the recorded spans.
    vim.api.nvim_buf_clear_namespace(agenda_buf, agenda_ns, 0, -1)
    for _, h in ipairs(highlights) do
        local line0, group, c0, c1 = h[1], h[2], h[3], h[4]
        pcall(vim.api.nvim_buf_add_highlight, agenda_buf, agenda_ns,
            group, line0, c0, c1)
    end
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
    -- 'f' cycles the tag filter: nil -> TAGS[1] -> TAGS[2] -> ... -> nil.
    vim.keymap.set("n", "f", function()
        if filter_tag == nil then
            filter_tag = TAGS[1]
        else
            local idx = nil
            for i, t in ipairs(TAGS) do
                if t == filter_tag then idx = i break end
            end
            if idx == nil or idx >= #TAGS then
                filter_tag = nil          -- past the end -> clear
            else
                filter_tag = TAGS[idx + 1]
            end
        end
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
        -- Archive on either terminal status (done or missed).
        local st = file_status(file)
        if st ~= "done" and st ~= "missed" then return end

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
-- and hands them to on_complete{kind,name,priority,start_date,deadline}; on
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
    vim.ui.select({ "Project", "Ticket", "Shopping list" }, { prompt = "Type:" },
    function(kind_choice)
        if not kind_choice then return on_abort() end

        -- Shopping list short-circuits: no further prompts. The name is the
        -- item; the completion handler appends it to the shopping file.
        if kind_choice == "Shopping list" then
            on_complete({ marker_new = ":shopping:", name = name })
            return
        end

        local marker_new = (kind_choice == "Project") and ":project:" or ":ticket:"

        -- Step 3: priority
        vim.ui.select(PRIORITIES, { prompt = "Priority:" },
        function(priority)
            if not priority then return on_abort() end

            -- Step 4: tag (single choice, with a "(none)" option)
            local tag_choices = { "(none)" }
            for _, t in ipairs(TAGS) do table.insert(tag_choices, t) end
            vim.ui.select(tag_choices, { prompt = "Tag:" },
            function(tag_choice)
                if not tag_choice then return on_abort() end
                local tag = (tag_choice == "(none)") and "" or tag_choice

            -- Step 5: due date (start/snooze date)
            local due_choices = {
                "Today", "Tomorrow", "In 3 days", "In a week", "Pick a date…",
            }
            vim.ui.select(due_choices, { prompt = "Start date:" },
            function(due_choice)
                if not due_choice then return on_abort() end

                local function with_due(start_date)
                    -- Step 6: deadline (hard due-by) with a None option
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
                                start_date = start_date,
                                deadline = deadline,
                                tag = tag,
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
            end)  -- close function(tag_choice)
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
        if choice.marker_new == ":shopping:" then
            if append_shopping(choice.name) then
                -- The fleeting note has served its purpose: delete file + buffer.
                vim.cmd("bdelete!")
                os.remove(file)
                vim.notify("Added to shopping list: " .. choice.name,
                    vim.log.levels.INFO)
            end
            return
        end
        apply_promotion(bufnr, file, choice.marker_new, choice.priority,
            choice.start_date, choice.deadline, choice.name, choice.tag)
    end)
end

-- Transform the buffer in place: keep title/created_date/start_date/snooze_count,
-- add status/priority/deadline, swap the marker, seed a Steps section for
-- projects. Writes the file.
function apply_promotion(bufnr, file, marker_new, priority, start_date, deadline, name, tag)
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
    set_key("start_date", start_date)
    set_key("deadline", deadline)
    set_key("tags", (tag and tag ~= "") and (":" .. tag .. ":") or "")
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
        label, priority, start_date,
        deadline ~= "" and (", deadline " .. deadline) or ""),
        vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------
-- Create a fresh project/ticket file from scratch (used by batch capture).
-- Mirrors the fleeting-note filename convention: <date>_<slug>.md
-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
-- Append an item to the shopping list file as a "- [ ] item" checkbox.
-- Creates the file with a "# Shopping" heading if it doesn't exist yet.
-- Returns true on success.
-- ---------------------------------------------------------------------
function append_shopping(item)
    -- Create with a heading if missing.
    if vim.fn.filereadable(shopping_file) == 0 then
        local fh = io.open(shopping_file, "w")
        if not fh then
            vim.notify("Failed to create " .. shopping_file, vim.log.levels.ERROR)
            return false
        end
        fh:write("# Shopping\n\n")
        fh:close()
    end
    -- Append the checkbox to the end.
    local fh = io.open(shopping_file, "a")
    if not fh then
        vim.notify("Failed to write " .. shopping_file, vim.log.levels.ERROR)
        return false
    end
    fh:write("- [ ] " .. item .. "\n")
    fh:close()
    return true
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
        "start_date: " .. choice.start_date,
        "deadline: " .. choice.deadline,
        "tags: " .. ((choice.tag and choice.tag ~= "")
            and (":" .. choice.tag .. ":") or ""),
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
                if choice.marker_new == ":shopping:" then
                    if append_shopping(choice.name) then
                        created = created + 1
                        vim.notify("Added to shopping list: " .. choice.name,
                            vim.log.levels.INFO)
                    end
                    vim.schedule(function() process(idx + 1) end)
                    return
                end
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
            -- start_date forward and bump snooze_count. (Mirrors your snooze().)
            local function snooze(days)
                local b = vim.api.nvim_get_current_buf()
                local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
                local new_date = offset_date(days)
                for i, line in ipairs(lines) do
                    if line:match("^start_date:") then
                        lines[i] = "start_date: " .. new_date
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

            -- Mark this project/ticket with a terminal status and save. On
            -- buffer leave, the auto-archive autocmd moves the file to done/
            -- (buffer untouched). Both "done" and "missed" are terminal: they
            -- drop off the agenda and archive to the same folder.
            local function mark_status(new_status)
                local b = vim.api.nvim_get_current_buf()
                local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
                local set = false
                for i, line in ipairs(lines) do
                    if line:match("^status:") then
                        lines[i] = "status: " .. new_status
                        set = true
                        break
                    end
                end
                if not set then
                    vim.notify("No status field found.", vim.log.levels.WARN)
                    return
                end
                vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
                vim.cmd("write")
                vim.notify("Marked " .. new_status ..
                    " (archives on buffer close)", vim.log.levels.INFO)
            end
            vim.keymap.set("n", "dn", function() mark_status("done") end, opts)
            vim.keymap.set("n", "dm", function() mark_status("missed") end, opts)
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
