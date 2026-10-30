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
--
-- ---------------------------------------------------------------------
-- v2: MENU, NOT SCHEDULE  (see frontmatter_v2.md)
-- ---------------------------------------------------------------------
--   stage:    needs_breakdown | ready | active   (missing = needs_breakdown)
--   project:  [[project-note]] on tickets promoted from a project step
--   tags:     one PLACE only (TAGS below); a project step may override it
--             inline:  "- [ ] Buy 4 drip emitters :out:"
--
--   ACTIVE    capped at ACTIVE_CAP. Projects take one slot and show their
--             current step (first unchecked leaf). Free slots auto-refill
--             from `ready` (projects first, then priority traded against
--             age). Ready items overdue or due within URGENT_DAYS come in
--             even past the cap, and sort to the top.
--   RECURRING spawned chores; shown separately, not counted in the cap.
--   TO PLAN   needs_breakdown: can't enter ACTIVE until broken down.
--   BACKLOG   ready, waiting for a slot (hidden; 'B' toggles).
--
--   A step promoted to a ticket becomes "- [ ] [[ticket]]". The agenda
--   follows the link: shows the ticket's title/place, skips it while the
--   ticket is snoozed, and treats it as checked once the ticket is
--   done/missed.
--
--   IN THE AGENDA BUFFER (v2 additions)
--     p            plan: "single physical action?" yes → ready,
--                  no → turn into a project and open it to write steps
--     a            pull into ACTIVE (runs the plan prompt first if needed)
--     x            send back to BACKLOG (frees the slot; refill skips it
--                  until tomorrow)
--     dn / dm      done / missed for the item under the cursor
--                  (on a project: ticks its current step)
--     S            someday: archive it and add its title to someday.md
--                  (with a link back to the file, so notes aren't lost)
--     B            toggle backlog
--
--   ON A PROJECT / TICKET
--     ds           someday (same as S in the agenda; archives on close)
--   ON A PROJECT
--     <leader>zt   promote the step under the cursor to its own ticket
--   ON A PROJECT / TICKET
--     ss / sm / sl snoozing an ACTIVE item also sends it to the backlog
-- =====================================================================

local M = {}

-- Reuse the same vault path as the fleeting-note config.
-- (vim.g.zettel_vault overrides the path, e.g. for testing on a copy.)
local vault = vim.g.zettel_vault or vim.fn.expand("~/zettelkasten/")
local done_dir = vault .. "done/"
local shopping_file = vault .. "shopping.md"
-- v2: "not now, but remember it" list. Demoted items are archived to done/
-- with status `someday` and listed here with a link back to the file.
local someday_file = vault .. "someday.md"

-- Forward declaration: defined later, used by the wizard completion handlers.
local append_shopping

local STATUSES   = { "todo", "doing", "blocked", "done" }
local PRIORITIES = { "A", "B", "C" }

-- Your tag vocabulary. Edit this list to add/remove tags. They show up in the
-- promotion/batch wizard as a single-choice step, and the agenda cycles
-- through them with `f` to filter. Keep them short and lowercase.
-- v2: tags mean PLACE only. Untagged = doable anywhere (never filtered out).
local TAGS = { "farm", "home", "out", "computer" }

-- v2: active-list size, and whether free slots fill themselves from `ready`.
local ACTIVE_CAP = 7
local AUTO_REFILL = true

local function is_place(t)
    for _, p in ipairs(TAGS) do
        if p == t then return true end
    end
    return false
end

-- Parse colon-wrapped tags (":tag1: :tag2:") into a list.
local function parse_tags(s)
    local out = {}
    for t in (s or ""):gmatch(":([%w%-_]+):") do
        table.insert(out, t)
    end
    return out
end

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
    return s == "done" or s == "missed" or s == "someday"
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

-- ---------------------------------------------------------------------
-- Small on-disk editors (the agenda edits files that aren't open)
-- ---------------------------------------------------------------------
-- Set (or insert) a frontmatter key in a file on disk. If the file is loaded
-- in a buffer, edit the buffer instead and write it, so nvim never sees the
-- file change underneath it.
local function set_fm_key(file, key, value)
    local bufnr = vim.fn.bufnr(file)
    local loaded = bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr)
    local lines = loaded and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        or vim.fn.readfile(file)
    local fm_start, fm_end
    for i, line in ipairs(lines) do
        if line:match("^%-%-%-%s*$") then
            if not fm_start then fm_start = i
            elseif not fm_end then fm_end = i; break end
        end
    end
    if not fm_start or not fm_end then return false end
    local new_line = (key .. ": " .. value):gsub("%s+$", "")
    local done = false
    for i = fm_start + 1, fm_end - 1 do
        if lines[i]:match("^" .. key .. ":") then
            lines[i] = new_line
            done = true
            break
        end
    end
    if not done then table.insert(lines, fm_end, new_line) end
    if loaded then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
    else
        vim.fn.writefile(lines, file)
    end
    return true
end

-- Replace one line (1-indexed) of a file, buffer-aware like set_fm_key.
local function set_file_line(file, lnum, text)
    local bufnr = vim.fn.bufnr(file)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { text })
        vim.api.nvim_buf_call(bufnr, function() vim.cmd("silent write") end)
    else
        local lines = vim.fn.readfile(file)
        lines[lnum] = text
        vim.fn.writefile(lines, file)
    end
end

-- Resolve a [[link]] to a file in the vault root or done/.
local function resolve_link(name)
    name = name:gsub("%.md$", "")
    for _, p in ipairs({ vault .. name .. ".md", done_dir .. name .. ".md" }) do
        if vim.fn.filereadable(p) == 1 then return p end
    end
    return nil
end

-- Find the next actionable step in a project file, supporting arbitrary
-- nesting. The next step is the first UNCHECKED LEAF: an unchecked box with
-- no unchecked boxes nested beneath it.
--
-- v2 additions:
--   * an inline place tag on a step (":out:") overrides the project's tag
--   * a step that is a [[link]] to a ticket takes that ticket's title/place;
--     it counts as checked once the ticket is done/missed, and is skipped
--     (not a candidate) while the ticket is snoozed
--
-- Returns (step, waiting_until):
--   step = { text = "Parent > Leaf", tag = "out"|nil, lnum = <file line>,
--            link_file = <ticket path>|nil, deadline = ""|date }
--   waiting_until = earliest snooze date when every remaining step is a
--   snoozed ticket (step is nil then); nil otherwise.
local function next_step(file)
    local lines = vim.fn.readfile(file)
    local start, fence = 1, 0
    for i, l in ipairs(lines) do
        if l:match("^%-%-%-%s*$") then
            fence = fence + 1
            if fence == 2 then start = i + 1; break end
        end
    end

    local boxes = {}
    for i = start, #lines do
        local line = lines[i]
        local indent, mark = line:match("^(%s*)[%-%*]%s*%[([%sxX])%]")
        if indent ~= nil then
            local text = line:gsub("^%s*[%-%*]%s*%[[%sxX]%]%s*", "")
            local box = { depth = #indent, checked = (mark ~= " "),
                          text = text, lnum = i, deadline = "" }
            for t in text:gmatch(":([%w%-_]+):") do
                if is_place(t) then box.tag = t end
            end
            if box.tag then
                box.text = vim.trim((box.text:gsub("%s*:" .. vim.pesc(box.tag) .. ":", "")))
            end
            local link = box.text:match("%[%[([^%]|]+)")
            if link and not box.checked then
                local lf = resolve_link(link)
                if lf then
                    local lfm = read_note(lf)
                    box.link_file = lf
                    if is_terminal(lfm) then
                        box.checked = true
                    else
                        if lfm.title and lfm.title ~= "" then box.text = lfm.title end
                        local lt = parse_tags(lfm.tags)
                        if not box.tag and lt[1] then box.tag = lt[1] end
                        box.deadline = lfm.deadline or ""
                        if is_snoozed(lfm) then box.snoozed_until = lfm.start_date end
                    end
                end
            end
            table.insert(boxes, box)
        end
    end
    if #boxes == 0 then return nil, nil end

    -- Leaf = no unchecked descendants (a parent whose children are all ticked
    -- is itself the next step).
    local function is_leaf(i)
        for j = i + 1, #boxes do
            if boxes[j].depth <= boxes[i].depth then break end
            if not boxes[j].checked then return false end
        end
        return true
    end

    local waiting
    for i, box in ipairs(boxes) do
        if not box.checked and is_leaf(i) then
            if box.snoozed_until then
                if not waiting or box.snoozed_until < waiting then
                    waiting = box.snoozed_until
                end
            else
                local trail = {}
                local depth_floor = box.depth
                for j = i - 1, 1, -1 do
                    if boxes[j].depth < depth_floor then
                        table.insert(trail, 1, (boxes[j].text:gsub("%s*:[%w%-_]+:", "")))
                        depth_floor = boxes[j].depth
                        if depth_floor == 0 then break end
                    end
                end
                table.insert(trail, box.text)
                return { text = table.concat(trail, " > "), tag = box.tag,
                         lnum = box.lnum, link_file = box.link_file,
                         deadline = box.deadline }, nil
            end
        end
    end
    return nil, waiting
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
-- v2: collects EVERYTHING (no tag filter) so the active cap counts the whole
-- list; the tag filter is applied at render time.
-- item = {file, kind, title, step, waiting, priority, deadline, status,
--         snoozed, start_date, tags, recur_id, stage, created}
local function collect(show_snoozed)
    local items = {}
    local fleeting_unprocessed = 0
    local fleeting_snoozing = 0
    local today = today_str()

    for _, file in ipairs(vim.fn.glob(vault .. "*.md", false, true)) do
        local fm, marker = read_note(file)

        if marker == "fleeting" then
            -- "Unprocessed" = ready to process now: no start_date, OR a
            -- start_date that has arrived (today or past). "Snoozing" = a
            -- start_date still in the future. This matches what <leader>zp
            -- actually serves up (notes due today or earlier).
            local due = fm.start_date or ""
            if due == "" or not date_before(today, due) then
                fleeting_unprocessed = fleeting_unprocessed + 1
            else
                fleeting_snoozing = fleeting_snoozing + 1
            end

        elseif (marker == "project" or marker == "ticket")
            -- A ticket promoted from a project step shows up through its
            -- project's step line, not as a separate item.
            and not (marker == "ticket" and (fm.project or "") ~= "") then
            local snoozed = is_snoozed(fm)
            if is_active(fm) or (show_snoozed and snoozed) then
                local title = (fm.title and fm.title ~= "" and fm.title)
                    or vim.fn.fnamemodify(file, ":t")
                local stage = fm.stage
                if stage ~= "ready" and stage ~= "active" then
                    stage = "needs_breakdown"
                end
                local item = {
                    file = file, kind = marker, title = title,
                    priority = fm.priority or "",
                    deadline = fm.deadline or "",
                    status = fm.status or "", snoozed = snoozed,
                    start_date = fm.start_date or "",
                    tags = parse_tags(fm.tags),
                    recur_id = fm.recur_id or "",
                    stage = stage,
                    created = fm.created_date or "",
                    parked = fm.parked or "",
                }
                if marker == "project" then
                    item.step, item.waiting = next_step(file)
                    -- The current step's place overrides the project's.
                    if item.step and item.step.tag then
                        item.tags = { item.step.tag }
                    end
                end
                table.insert(items, item)
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

-- Items that count toward the cap: active, visible now, not recurring.
local function counts_toward_cap(it)
    return it.stage == "active" and not it.snoozed and it.recur_id == ""
end

-- Refill ordering: each priority level is worth PRIORITY_STEP_DAYS of age,
-- so old low-priority items eventually surface. E.g. with 14: a C ticket
-- created 4 weeks ago ties with a brand-new A. Lower score = pulled first.
local PRIORITY_STEP_DAYS = 14

local function age_days(created)
    local y, m, d = (created or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return 0 end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    return math.max(0, math.floor((os.time() - t) / 86400))
end

-- Deadline pressure: a ready item whose deadline is past, or within
-- URGENT_DAYS, is pulled into ACTIVE even if that goes over the cap.
-- (3 matches the orange "due soon" highlight.)
local URGENT_DAYS = 3

-- Days until a YYYY-MM-DD date (negative = past); nil if no/invalid date.
local function days_to(date_str)
    local y, m, d = (date_str or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
    local now = os.time({ year = tonumber(os.date("%Y")), month = tonumber(os.date("%m")),
        day = tonumber(os.date("%d")), hour = 12 })
    return math.floor((t - now) / 86400 + 0.5)
end

-- An item's effective deadline: its own, or its current linked step's.
local function item_deadline(it)
    if it.deadline and it.deadline ~= "" then return it.deadline end
    if it.step and it.step.deadline and it.step.deadline ~= "" then
        return it.step.deadline
    end
    return ""
end

local function is_urgent(it)
    local d = days_to(item_deadline(it))
    return d ~= nil and d <= URGENT_DAYS
end

local function refill_score(it)
    return prio_rank(it.priority) * PRIORITY_STEP_DAYS - age_days(it.created)
end

-- Fill free ACTIVE slots from `ready` items: projects that have a next step
-- first, then tickets; within each, by refill_score (priority traded against
-- age), then deadline. Writes `stage: active` to each pulled file. Items sent
-- back with 'x' carry `parked: <today>` and are skipped until tomorrow.
-- Returns the number pulled.
local function refill(items)
    if not AUTO_REFILL then return 0 end
    local n = 0
    for _, it in ipairs(items) do
        if counts_toward_cap(it) then n = n + 1 end
    end
    local today = today_str()
    local pulled = 0

    -- 1) Deadline pressure: urgent ready items come in regardless of the cap
    --    ('x' still parks one for the day if you really want it gone).
    for _, it in ipairs(items) do
        if it.stage == "ready" and not it.snoozed and it.recur_id == ""
            and it.parked ~= today and is_urgent(it) then
            if set_fm_key(it.file, "stage", "active") then
                it.stage = "active"
                n = n + 1
                pulled = pulled + 1
            end
        end
    end
    if n >= ACTIVE_CAP then return pulled end

    -- 2) Normal refill up to the cap.
    local cands = {}
    for _, it in ipairs(items) do
        if it.stage == "ready" and not it.snoozed and it.recur_id == ""
            and it.parked ~= today  -- sent back with 'x' today
            and (it.kind ~= "project" or it.step ~= nil) then
            table.insert(cands, it)
        end
    end
    table.sort(cands, function(a, b)
        local pa, pb = a.kind == "project", b.kind == "project"
        if pa ~= pb then return pa end
        local sa, sb = refill_score(a), refill_score(b)
        if sa ~= sb then return sa < sb end
        local ka, kb = deadline_key(a.deadline), deadline_key(b.deadline)
        if ka ~= kb then return ka < kb end
        return a.title < b.title
    end)

    for _, it in ipairs(cands) do
        if n >= ACTIVE_CAP then break end
        if set_fm_key(it.file, "stage", "active") then
            it.stage = "active"
            n = n + 1
            pulled = pulled + 1
        end
    end
    return pulled
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

-- Open a file for editing. If nvim stops at a swap-file prompt (another nvim
-- has it open, or an old crash left a .swp) and you quit/abort, show a short
-- message instead of a Lua stack trace.
local function safe_edit(path)
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
    if not ok then
        local msg = tostring(err)
        if msg:match("E325") then
            vim.notify("Swap file found for " .. vim.fn.fnamemodify(path, ":t")
                .. " — another nvim has it open, or an old session crashed. "
                .. "Close the other one, or delete the swap file (:h E325).",
                vim.log.levels.WARN)
        else
            vim.notify(msg, vim.log.levels.ERROR)
        end
        return false
    end
    return true
end

-- Move a terminal-status file into done/ (never clobbers). Used by the
-- BufUnload auto-archive and by agenda actions on files that aren't open.
local function archive_file(file)
    if file:match("/done/") or vim.fn.filereadable(file) == 0 then return false end
    if vim.fn.isdirectory(done_dir) == 0 then vim.fn.mkdir(done_dir, "p") end
    local name = vim.fn.fnamemodify(file, ":t")
    local target = done_dir .. name
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
    return ok
end

local show_backlog = false  -- agenda toggle: list the backlog?
local row_items = {}        -- agenda row -> item (for p / a / x / dn / dm)

local render_agenda  -- forward declaration (actions re-render)

-- Set a terminal status on a ticket; archive right away unless it's open in a
-- buffer (then the BufUnload autocmd archives it when you leave).
local function finish_ticket(file, status)
    set_fm_key(file, "status", status)
    local bufnr = vim.fn.bufnr(file)
    if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
        archive_file(file)
    end
end

-- Demote to someday: status `someday`, a line in someday.md linking the
-- archived file (body notes are kept there), then archive like done.
local function send_to_someday(file, title)
    if vim.fn.filereadable(someday_file) == 0 then
        vim.fn.writefile({ "# Someday", "",
            "Ideas parked on purpose. Re-capture one with <leader>zb on its line.",
            "" }, someday_file)
    end
    local stem = vim.fn.fnamemodify(file, ":t:r")
    local lines = vim.fn.readfile(someday_file)
    table.insert(lines, string.format("- %s  [[%s]]  (%s)", title, stem, today_str()))
    vim.fn.writefile(lines, someday_file)
    finish_ticket(file, "someday")
    vim.notify("→ someday: " .. title, vim.log.levels.INFO)
end

-- dn / dm on an agenda item. Tickets get the status; a project ticks its
-- current step (or finishes the step's linked ticket).
local function complete_item(it, status)
    if it.kind == "ticket" then
        finish_ticket(it.file, status)
        vim.notify(string.format("%s: %s", status, it.title), vim.log.levels.INFO)
    elseif it.step then
        if it.step.link_file then
            finish_ticket(it.step.link_file, status)
        else
            local line = vim.fn.readfile(it.file)[it.step.lnum]
            set_file_line(it.file, it.step.lnum,
                (line:gsub("%[%s%]", "[x]", 1)))
        end
        vim.notify("Step done: " .. it.step.text, vim.log.levels.INFO)
    else
        vim.notify("Project has no next step — open it to add one, or set its status.",
            vim.log.levels.WARN)
    end
end

-- The breakdown prompt. Yes → ready. No → ticket becomes a project with a
-- Steps section and opens for writing the steps.
local function plan_item(it, then_activate)
    local q = (it.kind == "project")
        and "Are the steps written, with a concrete first one?"
        or "Is this a single physical action?"
    vim.ui.select({ "Yes", "No" }, { prompt = q }, function(choice)
        if not choice then return end
        if choice == "Yes" then
            set_fm_key(it.file, "stage", then_activate and "active" or "ready")
            render_agenda()
            return
        end
        if it.kind == "ticket" then
            local lines = vim.fn.readfile(it.file)
            local has_steps = false
            for i, line in ipairs(lines) do
                if line:match(":ticket:") then
                    lines[i] = line:gsub(":ticket:", ":project:")
                end
                if line:match("^%s*[%-%*]%s*%[[%sxX]%]") then has_steps = true end
            end
            if not has_steps then
                vim.list_extend(lines, { "", "## Steps", "", "- [ ] " })
            end
            vim.fn.writefile(lines, it.file)
        end
        set_fm_key(it.file, "stage", "ready")
        if safe_edit(it.file) then vim.cmd("normal! G$") end
        vim.notify("Write the steps; the first unchecked one becomes the next action.",
            vim.log.levels.INFO)
    end)
end

render_agenda = function()
    -- Lazy recurring-ticket generation: spawn any due instances before scanning.
    -- Safe no-op if the recurrence module isn't installed.
    pcall(function() require("config.tk_functions.zettel_recur").generate() end)

    setup_highlights()
    local items, unprocessed, snoozing = collect(show_snoozed)
    refill(items)

    local lines = {}
    local line_targets = {}  -- maps buffer line number -> file path
    local header_rows = {}   -- ordered list of item-header line numbers
    local highlights = {}    -- {line0, hl_group, col_start, col_end} (0-indexed)
    row_items = {}

    -- Tag filter (untagged items always match: doable anywhere).
    local function tag_matches(it)
        if not filter_tag or #it.tags == 0 then return true end
        for _, t in ipairs(it.tags) do
            if t == filter_tag then return true end
        end
        return false
    end

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
        "Places: %s   (%s — 'f' to cycle)",
        table.concat(tag_parts, " · "), filter_label))
    table.insert(lines, string.rep("─", 60))

    -- Bucket into sections. `items` is already priority-sorted, so each
    -- bucket preserves priority order. The cap counts all places; the tag
    -- filter only hides rows.
    local active, recurring, to_plan, backlog, snoozed_items = {}, {}, {}, {}, {}
    local n_active, n_backlog = 0, 0
    for _, it in ipairs(items) do
        if counts_toward_cap(it) then n_active = n_active + 1 end
        if it.stage == "ready" and not it.snoozed and it.recur_id == "" then
            n_backlog = n_backlog + 1
        end
        if tag_matches(it) then
            if it.snoozed then
                table.insert(snoozed_items, it)
            elseif it.recur_id ~= "" then
                table.insert(recurring, it)
            elseif it.stage == "active"
                -- unplanned but due soon/overdue: show it where you'll see it
                or (it.stage == "needs_breakdown" and is_urgent(it)) then
                table.insert(active, it)
            elseif it.stage == "needs_breakdown" then
                table.insert(to_plan, it)
            else
                table.insert(backlog, it)
            end
        end
    end

    -- Urgent (overdue / due soon) items first in ACTIVE; stable otherwise.
    do
        local urgent, rest = {}, {}
        for _, it in ipairs(active) do
            table.insert(is_urgent(it) and urgent or rest, it)
        end
        table.sort(urgent, function(a, b) return item_deadline(a) < item_deadline(b) end)
        active = vim.list_extend(urgent, rest)
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
        seg(string.rep(" ", (TITLE_WIDTH - disp_width(disp_title)) + 2), nil)

        seg("(" .. prio .. ")", "ZettelPrio")

        -- Deadline column: the project's, or its current linked step's.
        local dl = it.deadline
        if (dl == nil or dl == "") and it.step and it.step.deadline ~= "" then
            dl = it.step.deadline
        end
        local dl_text, dl_hl = "", nil
        if dl and dl ~= "" then
            dl_text = "⏰ " .. dl
            dl_hl = deadline_hl(dl)
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
        row_items[#lines] = it
        table.insert(header_rows, #lines)
        if it.stage == "needs_breakdown" then
            table.insert(lines, "      → (due soon, not planned yet — 'p' to plan)")
            table.insert(highlights, { #lines - 1, "ZettelDueSoon", 0, -1 })
            line_targets[#lines] = it.file
            row_items[#lines] = it
        elseif it.kind == "project" then
            if it.step then
                table.insert(lines, "      → " .. it.step.text)
                -- <CR> on the step line opens the step's ticket if it has one
                line_targets[#lines] = it.step.link_file or it.file
            elseif it.waiting then
                table.insert(lines, "      → (next step snoozed until " .. it.waiting .. ")")
                table.insert(highlights, { #lines - 1, "ZettelSnooze", 0, -1 })
                line_targets[#lines] = it.file
            else
                table.insert(lines, "      → (no next action — add a step)")
                table.insert(highlights, { #lines - 1, "ZettelDueSoon", 0, -1 })
                line_targets[#lines] = it.file
            end
            row_items[#lines] = it
        end
    end

    -- Render a titled section, or a placeholder if empty.
    local function emit_section(title, bucket, empty_msg)
        table.insert(lines, "")
        table.insert(lines, "━━ " .. title .. " ━━")
        table.insert(highlights, { #lines - 1, "ZettelSection", 0, #("━━ " .. title .. " ━━") })
        if #bucket == 0 then
            if empty_msg then table.insert(lines, "  " .. empty_msg) end
        else
            for _, it in ipairs(bucket) do
                emit_item(it)
            end
        end
    end

    local over = (n_active > ACTIVE_CAP) and "  — over cap, 'x' to send some back" or ""
    emit_section(string.format("ACTIVE %d/%d%s", n_active, ACTIVE_CAP, over), active,
        filter_tag and "(nothing active for this place)"
        or (n_backlog == 0 and "(empty — plan something from TO PLAN with 'p')" or "(none)"))
    if #recurring > 0 then
        emit_section("RECURRING", recurring, nil)
    end
    emit_section("TO PLAN", to_plan, "(none)")
    if show_backlog then
        emit_section("BACKLOG", backlog, "(none)")
    else
        table.insert(lines, "")
        table.insert(lines, string.format("━━ BACKLOG: %d ready — 'B' to show ━━", n_backlog))
        table.insert(highlights, { #lines - 1, "ZettelType", 0, -1 })
    end
    if show_snoozed then
        emit_section("SNOOZED", snoozed_items, "(none)")
    end
    table.insert(lines, "")
    table.insert(lines, "p plan · a activate · x backlog · S someday · dn/dm done/missed · B backlog · z snoozed · f place · r refresh · q quit")
    table.insert(highlights, { #lines - 1, "ZettelType", 0, -1 })

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
    if header_rows[1] and vim.api.nvim_get_current_buf() == agenda_buf then
        pcall(vim.api.nvim_win_set_cursor, 0, { header_rows[1], 0 })
    end

    -- Buffer-local keymaps.
    local opts = { buffer = agenda_buf, silent = true }
    vim.keymap.set("n", "<CR>", function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local targets = vim.b[agenda_buf].line_targets or {}
        local target = targets[row]
        if target then
            safe_edit(target)
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

    -- v2 item actions (act on the item under the cursor).
    local function with_item(fn)
        return function()
            local it = row_items[vim.api.nvim_win_get_cursor(0)[1]]
            if not it then return end
            fn(it)
        end
    end
    vim.keymap.set("n", "p", with_item(function(it) plan_item(it, false) end), opts)
    vim.keymap.set("n", "a", with_item(function(it)
        if it.recur_id ~= "" then
            vim.notify("Recurring items sit outside the cap.", vim.log.levels.INFO)
        elseif it.stage == "needs_breakdown" then
            plan_item(it, true)
        else
            set_fm_key(it.file, "stage", "active")
            render_agenda()
        end
    end), opts)
    vim.keymap.set("n", "x", with_item(function(it)
        set_fm_key(it.file, "stage", "ready")
        -- Keep auto-refill from pulling it straight back in today.
        set_fm_key(it.file, "parked", today_str())
        render_agenda()
    end), opts)
    vim.keymap.set("n", "dn", with_item(function(it)
        complete_item(it, "done"); render_agenda()
    end), opts)
    vim.keymap.set("n", "dm", with_item(function(it)
        complete_item(it, "missed"); render_agenda()
    end), opts)
    vim.keymap.set("n", "S", with_item(function(it)
        local what = (it.kind == "project") and "project" or "ticket"
        vim.ui.select({ "Yes", "No" },
            { prompt = "Move " .. what .. " '" .. it.title .. "' to someday?" },
            function(choice)
                if choice ~= "Yes" then return end
                send_to_someday(it.file, it.title)
                render_agenda()
            end)
    end), opts)
    vim.keymap.set("n", "B", function()
        show_backlog = not show_backlog
        render_agenda()
    end, opts)

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
        if st ~= "done" and st ~= "missed" and st ~= "someday" then return end
        archive_file(file)
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
    -- v2: every new ticket/project starts unplanned (breakdown happens later,
    -- from the agenda's TO PLAN section, never at capture).
    set_key("stage", "needs_breakdown")
    set_key("project", "")
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
        "stage: needs_breakdown",
        "project:",
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
        -- v2: clean list syntax so someday.md / checklist lines work too:
        -- "- [ ] Title  [[link]]  (2026-10-29)" -> "Title"
        t = t:gsub("^[%-%*]%s+", ""):gsub("^%[[%sxX]%]%s*", "")
        t = t:gsub("%s*%(%d%d%d%d%-%d%d%-%d%d%)%s*$", ""):gsub("%s*%[%[[^%]]*%]%]", "")
        t = t:gsub("%s+$", "")
        if t ~= "" and not t:match("^#") then table.insert(pending, t) end
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
-- v2: promote the project step under the cursor to its own ticket file.
-- The step line becomes "- [ ] [[<ticket>]]"; the ticket gets the step's
-- place (or the project's), a project: backlink, and opens for editing so
-- you can add the date/deadline/notes that made it worth a file.
-- ---------------------------------------------------------------------
function promote_step()
    local bufnr = vim.api.nvim_get_current_buf()
    local proj_file = vim.api.nvim_buf_get_name(bufnr)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local prefix, text = line:match("^(%s*[%-%*]%s*%[%s%]%s*)(.*)$")
    if not prefix or vim.trim(text) == "" then
        vim.notify("Put the cursor on an unchecked step.", vim.log.levels.WARN)
        return
    end
    if text:match("%[%[") then
        vim.notify("This step is already a link.", vim.log.levels.WARN)
        return
    end

    local pfm = read_note(proj_file)
    local tag
    for t in text:gmatch(":([%w%-_]+):") do
        if is_place(t) then tag = t end
    end
    local title = vim.trim((text:gsub("%s*:[%w%-_]+:", "")))
    if not tag then tag = parse_tags(pfm.tags)[1] end

    local date = today_str()
    local slug = slugify(title)
    if slug == "" then slug = "step" end
    local base = date .. "_" .. slug
    if vim.fn.filereadable(vault .. base .. ".md") == 1 then
        base = base .. "_" .. os.date("%H%M%S")
    end
    local proj_stem = vim.fn.fnamemodify(proj_file, ":t:r")
    vim.fn.writefile({
        "---",
        "title: " .. title,
        "created_date: " .. date,
        "status: todo",
        "priority: " .. (pfm.priority or ""),
        "start_date: " .. date,
        "deadline: ",
        "tags: " .. (tag and (":" .. tag .. ":") or ""),
        "snooze_count: 0",
        "stage: ready",
        "project: [[" .. proj_stem .. "]]",
        "---",
        "",
        ":ticket:",
        "",
    }, vault .. base .. ".md")

    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false,
        { prefix .. "[[" .. base .. "]]" })
    vim.cmd("write")
    safe_edit(vault .. base .. ".md")
    vim.notify("Step promoted → " .. base, vim.log.levels.INFO)
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
                    -- v2: snoozing an active item frees its slot.
                    if line:match("^stage:%s*active%s*$") then
                        lines[i] = "stage: ready"
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
            -- v2: demote to someday (listed in someday.md, archived on close)
            vim.keymap.set("n", "ds", function()
                local f = vim.api.nvim_buf_get_name(0)
                local fm = read_note(f)
                send_to_someday(f, (fm.title and fm.title ~= "") and fm.title
                    or vim.fn.fnamemodify(f, ":t:r"))
            end, opts)

            if marker == "project" then
                vim.keymap.set("n", "<leader>zt", function() promote_step() end,
                    vim.tbl_extend("force", opts, { desc = "Promote step → ticket" }))
            end
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
