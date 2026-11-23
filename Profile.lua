-- ImpotPointGouv: light profiling, saved in the saved data (ImpotPointGouvDB.perf).
-- Measures the time spent in the addon's event handlers and OnUpdate scripts, the internal bus
-- (ns.On / ns.Fire), page redraws and a few heavy functions. Every second: FPS, addon
-- time and what cost the most. Calls over 30 ms are kept apart.
-- No global game function is replaced (no taint of secure code).
-- /ipg perf: summary  ·  /ipg perf off / on: stop or restart measuring.
local _, ns = ...
local PR = {}
ns.Profile = PR

local clock = debugprofilestop
local SPIKE_MS = 30
local KEEP_SECONDS = 900   -- 15 min of timeline
local KEEP_SPIKES = 150

local function NewSession()
    return {
        started = time(), version = nil,
        totals = {},     -- [label] = { n, ms, max }
        timeline = {},   -- { t, fps, ms, top, topMs, n }
        spikes = {},     -- { t, label, ms }
    }
end
local cur = NewSession()
local second = { ms = 0, n = 0, by = {} }
PR.enabled = true

function PR.Add(label, ms)
    if not PR.enabled then return end
    local tot = cur.totals[label]
    if not tot then tot = { 0, 0, 0 }; cur.totals[label] = tot end
    tot[1], tot[2] = tot[1] + 1, tot[2] + ms
    if ms > tot[3] then tot[3] = ms end
    second.ms, second.n = second.ms + ms, second.n + 1
    second.by[label] = (second.by[label] or 0) + ms
    if ms >= SPIKE_MS then
        local sp = cur.spikes
        sp[#sp + 1] = { time(), label, math.floor(ms + 0.5) }
        if #sp > KEEP_SPIKES then table.remove(sp, 1) end
    end
end

-- Times a function: PR.Time("Lists:ResolveReagents", fn, ...) returns what fn returns.
local function Done(label, t0, ...)
    PR.Add(label, clock() - t0)
    return ...
end
function PR.Time(label, fn, ...)
    if not PR.enabled or not clock then return fn(...) end
    return Done(label, clock(), fn(...))
end
-- Wraps a function so it is timed on every call.
function PR.Wrap(label, fn)
    return function(...) return PR.Time(label, fn, ...) end
end

-- The addon's event or timer frame: its OnEvent / OnUpdate are timed.
-- (Replaces the SetScript method of THIS frame only, before the file sets its scripts.)
function PR.Frame(f, file)
    if not f or not clock then return f end
    local orig = f.SetScript
    f.SetScript = function(self, what, fn)
        if fn and what == "OnEvent" then
            local inner = fn
            fn = function(s, event, ...)
                if not PR.enabled then return inner(s, event, ...) end
                local t0 = clock()
                inner(s, event, ...)
                PR.Add(file .. ":" .. tostring(event), clock() - t0)
            end
        elseif fn and what == "OnUpdate" then
            local inner, label = fn, file .. ":OnUpdate"
            fn = function(s, elapsed)
                if not PR.enabled then return inner(s, elapsed) end
                local t0 = clock()
                inner(s, elapsed)
                PR.Add(label, clock() - t0)
            end
        end
        return orig(self, what, fn)
    end
    return f
end

-- Calling file (to name the ns.On listeners).
function PR.Caller(level)
    local s = debugstack and debugstack(level or 3, 1, 0) or ""
    return s:match("([%w_]+)%.lua") or "?"
end

-- Timeline: one line per second, with the game's FPS.
local ticker = CreateFrame("Frame")
local acc, frames = 0, 0
ticker:SetScript("OnUpdate", function(_, elapsed)
    acc, frames = acc + elapsed, frames + 1
    if acc < 1 then return end
    if ns.db and ns.db.perf ~= nil and ns.db.perf.cur ~= cur then
        -- Data ready: keep the previous session and write this one.
        local prev = ns.db.perf.cur
        ns.db.perf = { cur = cur, prev = prev }
        cur.version = ns.version
        PR.enabled = not (ns.db.settings and ns.db.settings.profile == false)
    elseif ns.db and ns.db.perf == nil then
        ns.db.perf = { cur = cur }
        cur.version = ns.version
        PR.enabled = not (ns.db.settings and ns.db.settings.profile == false)
    end
    if PR.enabled then
        local top, topMs = nil, 0
        for k, v in pairs(second.by) do if v > topMs then top, topMs = k, v end end
        local tl = cur.timeline
        tl[#tl + 1] = { time(), math.floor(frames / acc + 0.5), math.floor(second.ms + 0.5), top or "",
            math.floor(topMs + 0.5), second.n }
        if #tl > KEEP_SECONDS then table.remove(tl, 1) end
    end
    acc, frames = 0, 0
    second = { ms = 0, n = 0, by = {} }
end)

-- Summary in chat.
function PR.Report(arg)
    if arg == "off" or arg == "on" then
        PR.enabled = arg == "on"
        if ns.db and ns.db.settings then ns.db.settings.profile = PR.enabled end
        ns.Print("profiling " .. (PR.enabled and "on" or "off") .. ".")
        return
    end
    local secs = math.max(1, time() - cur.started)
    local list, total = {}, 0
    for k, v in pairs(cur.totals) do list[#list + 1] = { k, v[1], v[2], v[3] }; total = total + v[2] end
    table.sort(list, function(a, b) return a[3] > b[3] end)
    local fpsSum, fpsN, low = 0, 0, 0
    for _, s in ipairs(cur.timeline) do
        fpsSum, fpsN = fpsSum + s[2], fpsN + 1
        if s[2] < 20 then low = low + 1 end
    end
    ns.Print(("perf since %s (%d s): addon %.0f ms in total (%.1f ms/s), average %d FPS, %d s under 20 FPS, %d spikes over %d ms"):format(
        date("%H:%M:%S", cur.started), secs, total, total / secs, fpsN > 0 and math.floor(fpsSum / fpsN) or 0, low,
        #cur.spikes, SPIKE_MS))
    for i = 1, math.min(12, #list) do
        local e = list[i]
        ns.Print(("  %-34s %6d calls  %8.0f ms  max %5.0f ms"):format(e[1], e[2], e[3], e[4]))
    end
    ns.Print("Saved to your SavedVariables at /reload or logout.")
end
