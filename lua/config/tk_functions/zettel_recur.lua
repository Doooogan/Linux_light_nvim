-- =====================================================================
-- Recurring-ticket layer for the Telekasten PM setup
-- =====================================================================
-- Companion to zettel_pm.lua. Self-contained: it writes ordinary ticket
-- files in the same frontmatter format the agenda reads, so the main module
-- needs no knowledge of recurrence beyond calling generate() once per agenda
-- render (see "WIRING" at the bottom).
--
-- MASTER NOTES (marker :recurring:) describe a recurrence and the ticket to
-- spawn. They are hidden from the agenda (no :ticket:/:project: marker) but
-- live in the vault to be edited. Spawned instances ARE ordinary tickets.
--
-- Generation is LAZY: it runs when the agenda opens/refreshes. For each
-- master, if the next occurrence date has arrived (or passed), it spawns ONE
-- ticket and advances the master's schedule to the next future occurrence
-- (catch-up collapses many missed occurrences into a single instance, so you
-- never get buried after a break).
--
-- MASTER NOTE FRONTMATTER:
--   title         display name; spawned tickets use this as their title
--   recur_id      unique key tying instances back to this master
--   freq          daily | weekly | monthly
--   interval      integer N (daily: every N days; weekly/monthly: every N
--                 weeks/months). Default 1.
--   weekday       (weekly only) 1=Mon … 7=Sun — the day it fires
--   monthday      (monthly only) 1..31 — day of month, clamped for short months
--   next_date     YYYY-MM-DD the next occurrence is due (the schedule cursor)
--   priority      A/B/C applied to spawned tickets
--   tags          ":tag:" applied to spawned tickets
--   lead_days     optional: spawned ticket's deadline = occurrence + lead_days
--                 (0 or empty = deadline same as occurrence; blank = no deadline)
--
-- The body marker line must be ":recurring:".
-- =====================================================================

local R = {}

local vault = vim.fn.expand("~/zettelkasten/")

-- ---------------------------------------------------------------------
-- Date helpers (YYYY-MM-DD strings; os.time tables for arithmetic)
-- ---------------------------------------------------------------------
local function today_str()
    return os.date("%Y-%m-%d")
end

-- Parse "YYYY-MM-DD" -> os.time (noon, to dodge DST edge cases).
local function parse_date(s)
    local y, m, d = (s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(m),
        day = tonumber(d), hour = 12 })
end

local function fmt_date(t)
    return os.date("%Y-%m-%d", t)
end

-- today < b  ? (string compare is valid for fixed-width ISO dates)
local function date_before(a, b)
    return a < b
end

-- Days in a given month/year (handles leap years).
local function days_in_month(year, month)
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if month == 2 then
        local leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        return leap and 29 or 28
    end
    return days[month]
end

-- ---------------------------------------------------------------------
-- Compute the NEXT occurrence strictly after a given date, per the rule.
-- Returns a YYYY-MM-DD string.
-- ---------------------------------------------------------------------
local function advance(from_str, freq, interval, weekday, monthday)
    interval = math.max(1, interval or 1)
    local t = parse_date(from_str) or os.time()

    if freq == "daily" then
        return fmt_date(t + interval * 86400)

    elseif freq == "weekly" then
        -- Find the next matching weekday strictly after `t`, then add
        -- (interval-1) further weeks so "every N weeks" lands correctly.
        local target = weekday or 1  -- 1=Mon..7=Sun
        local cur = t + 86400
        local found = nil
        for _ = 1, 8 do
            local wd = tonumber(os.date("%u", cur))  -- %u: 1=Mon..7=Sun
            if wd == target then found = cur; break end
            cur = cur + 86400
        end
        found = found or (t + 7 * 86400)
        if interval > 1 then
            found = found + (interval - 1) * 7 * 86400
        end
        return fmt_date(found)

    elseif freq == "monthly" then
        local y = tonumber(os.date("%Y", t))
        local m = tonumber(os.date("%m", t))
        -- Advance `interval` months.
        m = m + interval
        while m > 12 do m = m - 12; y = y + 1 end
        local md = math.min(monthday or tonumber(os.date("%d", t)),
            days_in_month(y, m))
        return fmt_date(os.time({ year = y, month = m, day = md, hour = 12 }))
    end

    -- Unknown freq: don't reschedule (returns same date so it won't loop).
    return from_str
end

-- ---------------------------------------------------------------------
-- Read a master note's frontmatter + confirm the :recurring: marker.
-- ---------------------------------------------------------------------
local function read_master(file)
    local fm = {}
    local fence = 0
    local in_fm = false
    local is_recurring = false
    local fh = io.open(file, "r")
    if not fh then return nil end
    for line in fh:lines() do
        if line:match("^%-%-%-%s*$") then
            fence = fence + 1
            in_fm = (fence == 1)
        elseif in_fm then
            local k, v = line:match("^([%w_]+):%s*(.*)$")
            if k then fm[k] = (v:gsub("%s+$", "")) end
        else
            if line:match(":recurring:") then is_recurring = true end
        end
    end
    fh:close()
    if not is_recurring then return nil end
    return fm
end

-- Rewrite a single frontmatter key in a master file (in place on disk).
local function update_master_key(file, key, value)
    local lines = {}
    local fh = io.open(file, "r")
    if not fh then return false end
    for line in fh:lines() do table.insert(lines, line) end
    fh:close()

    local fence, in_fm, done = 0, false, false
    for i, line in ipairs(lines) do
        if line:match("^%-%-%-%s*$") then
            fence = fence + 1
            in_fm = (fence == 1)
        elseif in_fm and line:match("^" .. key .. ":") then
            lines[i] = key .. ": " .. value
            done = true
            break
        end
    end
    if not done then return false end

    local out = io.open(file, "w")
    if not out then return false end
    out:write(table.concat(lines, "\n") .. "\n")
    out:close()
    return true
end

-- ---------------------------------------------------------------------
-- Spawn one ticket instance from a master's parameters, dated to `occ_date`.
-- Writes an ordinary :ticket: file the agenda will pick up.
-- ---------------------------------------------------------------------
local function slugify(s)
    return (s:gsub("%s+", "-"):gsub("[^%w%-]", ""):lower())
end

local function spawn_ticket(fm, occ_date)
    local date = today_str()
    local title = (fm.title and fm.title ~= "") and fm.title or "Recurring task"
    local slug = slugify(title)
    if slug == "" then slug = "recurring" end
    local base = date .. "_" .. slug
    local path = vault .. base .. ".md"
    if vim.fn.filereadable(path) == 1 then
        path = vault .. base .. "_" .. os.date("%H%M%S") .. ".md"
    end

    -- Deadline: occurrence + lead_days, or none if lead_days is blank.
    local deadline = ""
    local lead = fm.lead_days
    if lead ~= nil and lead ~= "" then
        local n = tonumber(lead) or 0
        local t = parse_date(occ_date)
        if t then deadline = fmt_date(t + n * 86400) end
    end

    -- due_date is the occurrence date: the ticket becomes visible that day.
    local content = table.concat({
        "---",
        "title: " .. title,
        "created_date: " .. date,
        "status: todo",
        "priority: " .. (fm.priority or ""),
        "due_date: " .. occ_date,
        "deadline: " .. deadline,
        "tags: " .. (fm.tags or ""),
        "recur_id: " .. (fm.recur_id or ""),
        "snooze_count: 0",
        "---",
        "",
        ":ticket:",
        "",
    }, "\n")

    local fh = io.open(path, "w")
    if not fh then return false end
    fh:write(content)
    fh:close()
    return true
end

-- ---------------------------------------------------------------------
-- generate(): the lazy hook. Scan masters; for any whose next_date has
-- arrived/passed, spawn ONE ticket and advance next_date to the next FUTURE
-- occurrence (collapsing missed ones). Safe to call on every agenda render.
-- ---------------------------------------------------------------------
function R.generate()
    local today = today_str()
    local spawned = 0

    for _, file in ipairs(vim.fn.glob(vault .. "*.md", false, true)) do
        local fm = read_master(file)
        if fm then
            local next_date = fm.next_date or ""
            -- Skip masters with no/blank schedule.
            if next_date ~= "" then
                -- Due if next_date <= today.
                if not date_before(today, next_date) then
                    local freq = fm.freq or "daily"
                    local interval = tonumber(fm.interval) or 1
                    local weekday = tonumber(fm.weekday)
                    local monthday = tonumber(fm.monthday)

                    -- Spawn ONE instance for the due occurrence.
                    if spawn_ticket(fm, next_date) then
                        spawned = spawned + 1
                    end

                    -- Advance the cursor to the next FUTURE occurrence,
                    -- collapsing any further missed ones.
                    local cursor = next_date
                    local guard = 0
                    repeat
                        cursor = advance(cursor, freq, interval, weekday, monthday)
                        guard = guard + 1
                    until date_before(today, cursor) or guard > 1000
                    update_master_key(file, "next_date", cursor)
                end
            end
        end
    end

    if spawned > 0 then
        vim.notify(string.format("Recurring: spawned %d ticket(s).", spawned),
            vim.log.levels.INFO)
    end
    return spawned
end

-- ---------------------------------------------------------------------
-- Create a new recurring master via a small wizard.
-- ---------------------------------------------------------------------
local PRIORITIES = { "A", "B", "C" }
-- Keep this in sync with TAGS in zettel_pm.lua, or edit to taste.
local TAGS = { "farm", "errands", "home" }
local WEEKDAYS = { "Monday", "Tuesday", "Wednesday", "Thursday",
    "Friday", "Saturday", "Sunday" }

-- Forward declarations (defined just below new_master).
local require_advance_first
local write_master

function R.new_master()
    vim.ui.input({ prompt = "Recurring task name: " }, function(name)
        if not name or name == "" then return end
        name = name:gsub("%s+$", "")

    vim.ui.select({ "daily", "weekly", "monthly" }, { prompt = "Frequency:" },
    function(freq)
        if not freq then return end

    vim.ui.input({ prompt = "Interval (every N " .. freq .. " units, default 1): " },
    function(interval_in)
        local interval = tonumber(interval_in) or 1

        -- Frequency-specific anchor (weekday or monthday), chained.
        local function with_anchor(weekday, monthday)
            vim.ui.select(PRIORITIES, { prompt = "Priority:" }, function(priority)
                if not priority then return end
                local tag_choices = { "(none)" }
                for _, t in ipairs(TAGS) do table.insert(tag_choices, t) end
                vim.ui.select(tag_choices, { prompt = "Tag:" }, function(tag_choice)
                    if not tag_choice then return end
                    local tag = (tag_choice == "(none)") and ""
                        or (":" .. tag_choice .. ":")

                    -- First occurrence: compute the next matching date from today.
                    local first = require_advance_first(freq, interval,
                        weekday, monthday)

                    write_master(name, freq, interval, weekday, monthday,
                        priority, tag, first)
                end)
            end)
        end

        if freq == "weekly" then
            vim.ui.select(WEEKDAYS, { prompt = "Which weekday?" }, function(wd)
                if not wd then return end
                local idx = nil
                for i, d in ipairs(WEEKDAYS) do if d == wd then idx = i break end end
                with_anchor(idx, nil)  -- idx: 1=Mon..7=Sun
            end)
        elseif freq == "monthly" then
            vim.ui.input({ prompt = "Day of month (1-31): " }, function(md_in)
                local md = tonumber(md_in)
                if not md then return end
                with_anchor(nil, md)
            end)
        else  -- daily
            with_anchor(nil, nil)
        end
    end)
    end)
    end)
end

-- Compute the first occurrence date from today for a freshly created master.
-- The first occurrence is the soonest matching slot (interval governs the gap
-- BETWEEN occurrences, not when the series starts).
function require_advance_first(freq, interval, weekday, monthday)
    local today = today_str()
    if freq == "monthly" and monthday then
        -- Try this month's target day; if it's today or later, use it.
        local y = tonumber(os.date("%Y"))
        local m = tonumber(os.date("%m"))
        local md = math.min(monthday, days_in_month(y, m))
        local cand = fmt_date(os.time({ year = y, month = m, day = md, hour = 12 }))
        if not date_before(cand, today) then  -- cand >= today
            return cand
        end
        -- Otherwise advance one month from this month's slot.
        return advance(cand, "monthly", 1, nil, monthday)
    end
    -- daily/weekly: start from yesterday so a match today is allowed.
    local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
    return advance(yesterday, freq, 1, weekday, monthday)
end

-- Write a new master note to disk.
function write_master(name, freq, interval, weekday, monthday, priority, tag, first)
    local date = today_str()
    local slug = slugify(name)
    if slug == "" then slug = "recurring" end
    -- Prefix so masters are easy to spot in the vault.
    local base = "recur_" .. date .. "_" .. slug
    local path = vault .. base .. ".md"
    if vim.fn.filereadable(path) == 1 then
        path = vault .. base .. "_" .. os.date("%H%M%S") .. ".md"
    end

    local recur_id = base  -- unique enough as a stable key

    local fm = {
        "---",
        "title: " .. name,
        "recur_id: " .. recur_id,
        "freq: " .. freq,
        "interval: " .. interval,
        "weekday: " .. (weekday or ""),
        "monthday: " .. (monthday or ""),
        "next_date: " .. first,
        "priority: " .. priority,
        "tags: " .. tag,
        "lead_days: ",
        "---",
        "",
        ":recurring:",
        "",
        "Master note for a recurring ticket. Edit the frontmatter to change the",
        "schedule. `next_date` is the schedule cursor — the next time a ticket",
        "will spawn. This note is hidden from the agenda.",
    }

    local fh = io.open(path, "w")
    if not fh then
        vim.notify("Failed to write master note.", vim.log.levels.ERROR)
        return
    end
    fh:write(table.concat(fm, "\n") .. "\n")
    fh:close()
    vim.notify(string.format("Created recurring '%s' (%s); first on %s",
        name, freq, first), vim.log.levels.INFO)
end

-- ---------------------------------------------------------------------
-- Keymap + command to create a master.
-- ---------------------------------------------------------------------
vim.api.nvim_create_user_command("RecurNew", R.new_master, {})
vim.keymap.set("n", "<leader>zcr", R.new_master,
    { desc = "New recurring ticket (master note)" })

return R

-- =====================================================================
-- WIRING (do this in zettel_pm.lua):
--   At the top of render_agenda(), before it scans the vault, add:
--
--       pcall(function() require("zettel_recur").generate() end)
--
--   That runs lazy generation every time the agenda opens or refreshes.
--   Adjust "zettel_recur" to whatever name you require this file under.
-- =====================================================================
