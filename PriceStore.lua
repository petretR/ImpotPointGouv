-- ImpotPointGouv: price history storage, in tiers. Prices.lua records into it, History.lua and P.Stats read it.
--
-- One entry per realm and item, in ns.db.prices[realm][itemID]:
--   cur, qty, t     lowest unit price now (nil: nothing listed), quantity listed, time of the last record
--   o               the open day: { day, samples, partial low }. samples = "sec,low,qty,depth;..." where sec
--                   counts from the start of the day. One sample per scan that saw the item's whole listing.
--   lq, lst         quantity and time of the last sample of the previous day (to count sales across midnight)
--   d               daily records, oldest first:  "day,low,high,usual,qty,sold,scans,depth,mkt,gone,new;..."
--   w               weekly records, oldest first: "week,low,high,usual,qty,sold,soldDays,scans,depth;..."
--   s               per-scan points of tracked items, oldest first: "t,low,mkt,qty,gone,new,depth;..."
--   lad, lhi, lat   the previous scan's price ladder (tracked items), to count units gone and added
--
-- In d, w and s the first field is stored as the gap to the previous record (the first one is absolute),
-- and empty trailing fields are dropped. That keeps the saved file small: it is read at every login.
--
-- Daily record: low / high = min and max of the day's lowest prices; usual = their median (ignores a single
-- bait listing); qty = median quantity listed; depth = median of the units listed within 10 % of the lowest
-- price; sold = units that disappeared between consecutive scans (yesterday's last scan included), unknown
-- (empty) when the day had fewer than 2 scans; mkt / gone / new: from the per-scan points (tracked items).
-- A daily record older than the daily window joins its week, once the whole week is out of the window.
local _, ns = ...
local S = {}
ns.Store = S

S.KEEP_SCANS = 7 * 86400      -- per-scan points (tracked items)
S.MAX_SCANS = 400             -- per item
S.KEEP_DAYS_TRACKED = 183     -- daily records of tracked items
S.KEEP_DAYS = 30              -- daily records of every other item
S.KEEP_WEEKS = 53             -- weekly records
S.MERGE = 120                 -- two records less than 2 min apart are the same scan
S.MAX_SAMPLES = 48            -- past this many samples in a day, scans closer than MERGE_BUSY are merged
S.MERGE_BUSY = 900
S.DIFF_MAX_GAP = 48 * 3600    -- beyond that, two scans are not compared (sold / gone / added unknown)
S.LADDER_LEVELS = 60          -- price levels kept to compare with the next scan
S.DEPTH_BAND = 1.10           -- depth: units listed up to 10 % above the lowest price

-- Field positions.
local D_DAY, D_LOW, D_HIGH, D_USUAL, D_QTY, D_SOLD, D_SCANS, D_DEPTH, D_MKT, D_GONE, D_NEW = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
local W_WEEK, W_LOW, W_HIGH, W_USUAL, W_QTY, W_SOLD, W_SOLDDAYS, W_SCANS, W_DEPTH = 1, 2, 3, 4, 5, 6, 7, 8, 9
S.D = { day = D_DAY, low = D_LOW, high = D_HIGH, usual = D_USUAL, qty = D_QTY, sold = D_SOLD, scans = D_SCANS,
    depth = D_DEPTH, mkt = D_MKT, gone = D_GONE, new = D_NEW }
S.W = { week = W_WEEK, low = W_LOW, high = W_HIGH, usual = W_USUAL, qty = W_QTY, sold = W_SOLD, soldDays = W_SOLDDAYS,
    scans = W_SCANS, depth = W_DEPTH }

local floor = math.floor
local function Day(t) return floor(t / 86400) end
-- Weeks start on Monday (day 0, 1 Jan 1970, was a Thursday).
function S.Week(day) return floor((day + 3) / 7) end
function S.WeekStart(week) return week * 7 - 3 end
S.Day = Day

-- ------------------------------------------------------------ packing
-- Numbers are written in base 36 ("-" for negatives), rounded to integers; empty = unknown.
-- Each kind of record says how many fields it has and which prices are stored as a gap to its low
-- (field 2), which keeps them short: a usual price of 4512 next to a low of 4480 is written "w".
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function Enc(v)
    if not v then return "" end
    v = floor(v + 0.5)
    if v == 0 then return "0" end
    local neg = v < 0
    if neg then v = -v end
    local out = ""
    while v > 0 do
        local d = v % 36
        out = DIGITS:sub(d + 1, d + 1) .. out
        v = (v - d) / 36
    end
    return neg and ("-" .. out) or out
end
local function Dec(f)
    if not f or f == "" then return nil end
    if f:sub(1, 1) == "-" then
        local v = tonumber(f:sub(2), 36)
        return v and -v
    end
    return tonumber(f, 36)
end
S.Enc, S.Dec = Enc, Dec

-- Kinds of records: number of fields, prices stored relative to the low.
local DAYS = { n = 11, rel = { 3, 4, 9 } }   -- high, usual, market
local WEEKS = { n = 9, rel = { 3, 4 } }      -- high, usual
local POINTS = { n = 7, rel = { 3 } }        -- market
local SAMPLES = { n = 4, rel = {} }
S.DAYS, S.WEEKS, S.POINTS, S.SAMPLES = DAYS, WEEKS, POINTS, SAMPLES

-- Text fields -> numbers (rel prices back to absolute). The first field is left as stored.
local function Fields(s, kind)
    local out, i = {}, 0
    for f in (s .. ","):gmatch("([^,]*),") do i = i + 1; out[i] = Dec(f) end
    local low = out[2]
    if low then
        for _, k in ipairs(kind.rel) do if out[k] then out[k] = low + out[k] end end
    end
    return out
end

-- One record (array, first field absolute) -> text, with the first field as a gap to prev.
local function PackOne(r, prev, kind)
    local low = r[2]
    local parts = { Enc(prev and (r[1] - prev) or r[1]) }
    for i = 2, kind.n do parts[i] = r[i] end
    if low then
        low = floor(low + 0.5)
        parts[2] = low
        for _, k in ipairs(kind.rel) do if parts[k] then parts[k] = parts[k] - low end end
    end
    for i = 2, kind.n do parts[i] = Enc(parts[i]) end
    return (table.concat(parts, ","):gsub(",+$", ""))
end
S.PackOne = PackOne

-- Records of a packed string, with absolute first fields. minKey: only the records from that key on
-- (the others are skipped without building tables). Not cached: a tracked item's whole history would
-- weigh tens of KB once unpacked, so readers ask only for the window they need.
local function Records(str, minKey, kind)
    local out = {}
    if not str or str == "" then return out end
    local k
    for rec in (str .. ";"):gmatch("([^;]*);") do
        local v = Dec(rec:match("^([^,]*)"))
        if v then
            k = k and (k + v) or v
            if not minKey or k >= minKey then
                local f = Fields(rec, kind)
                f[1] = k
                out[#out + 1] = f
            end
        end
    end
    return out
end
S.Records = Records

local function Pack(list, kind)
    local parts, prev = {}, nil
    for i, r in ipairs(list) do
        parts[i] = PackOne(r, prev, kind)
        prev = r[1]
    end
    return table.concat(parts, ";")
end
S.Pack = Pack

-- Absolute first field of the last record, read without unpacking everything.
local function LastKey(str)
    if not str or str == "" then return nil end
    local k
    for rec in (str .. ";"):gmatch("([^;]*);") do
        local v = Dec(rec:match("^([^,]*)"))
        if v then k = k and (k + v) or v end
    end
    return k
end
S.LastKey = LastKey

local function Append(str, rec, kind)
    local last = LastKey(str)
    local packed = PackOne(rec, last, kind)
    if not str or str == "" then return packed end
    return str .. ";" .. packed
end

-- Replaces the last record (same scan seen twice).
local function ReplaceLast(str, rec, kind)
    local head = str:match("^(.*);[^;]*$")
    if not head then return PackOne(rec, nil, kind) end
    return Append(head, rec, kind)
end

-- Old CSV text (v1.0 hist): decimal numbers.
local function DecimalFields(s)
    local out, i = {}, 0
    for f in (s .. ","):gmatch("([^,]*),") do i = i + 1; out[i] = tonumber(f) end
    return out
end

-- ------------------------------------------------------------ scan analysis
-- ladder: { [unit price] = quantity } -> sorted levels { {price, qty}, ... }
function S.Levels(ladder)
    local lv = {}
    for p, q in pairs(ladder or {}) do if p and p > 0 and q and q > 0 then lv[#lv + 1] = { p, q } end end
    table.sort(lv, function(a, b) return a[1] < b[1] end)
    return lv
end

-- Price at quantile f (0..1) of the units of lv, starting at level first.
local function Quantile(lv, f, first)
    local total = 0
    for i = first, #lv do total = total + lv[i][2] end
    local want, acc = total * f, 0
    for i = first, #lv do
        acc = acc + lv[i][2]
        if acc >= want then return lv[i][1] end
    end
    return lv[#lv] and lv[#lv][1]
end

-- Returns the lowest price (without baits), the market price and the first level kept, from the sorted levels.
-- Bait: a level of at most 2 units (or < 5 % of the total) below 60 % of the reference price;
-- at most three are dropped. Market: at least 15 % of the units, up to 30 % as long as the next level
-- does not jump by more than 20 %; then drop what is more than 1.5 standard deviations away and average.
function S.Analyze(lv)
    if #lv == 0 then return nil, nil end
    local first, total = 1, 0
    for _, l in ipairs(lv) do total = total + l[2] end
    for _ = 1, 3 do
        local l = lv[first]
        if not l or first >= #lv then break end
        local rest = total - l[2]
        local ref = Quantile(lv, 0.15, first + 1)
        if (l[2] <= 2 or l[2] < total * 0.05) and ref and l[1] < ref * 0.6 and rest > 0 then
            first, total = first + 1, rest
        else
            break
        end
    end
    local low = lv[first][1]
    local minU, maxU = total * 0.15, total * 0.30
    local slice, taken, prev = {}, 0, nil
    for i = first, #lv do
        local p, q = lv[i][1], lv[i][2]
        if taken >= minU and prev and p > prev * 1.2 then break end
        local take = math.min(q, math.max(0, maxU - taken))
        if taken < minU then take = math.max(take, math.min(q, minU - taken)) end
        if take <= 0 then break end
        slice[#slice + 1] = { p, take }
        taken, prev = taken + take, p
        if taken >= maxU then break end
    end
    if taken <= 0 then return low, low, first end
    local sum, n = 0, 0
    for _, s in ipairs(slice) do sum, n = sum + s[1] * s[2], n + s[2] end
    local mean = sum / n
    local var = 0
    for _, s in ipairs(slice) do var = var + s[2] * (s[1] - mean) ^ 2 end
    local sd = math.sqrt(var / n)
    if sd > 0 then
        local s2, n2 = 0, 0
        for _, s in ipairs(slice) do
            if math.abs(s[1] - mean) <= 1.5 * sd then s2, n2 = s2 + s[1] * s[2], n2 + s[2] end
        end
        if n2 > 0 then mean = s2 / n2 end
    end
    return low, floor(mean + 0.5), first
end

-- Units listed within DEPTH_BAND of the lowest price, baits left out.
function S.Depth(lv, first)
    first = first or 1
    local l = lv[first]
    if not l then return 0 end
    local cap, n = l[1] * S.DEPTH_BAND, 0
    for i = first, #lv do
        if lv[i][1] > cap then break end
        n = n + lv[i][2]
    end
    return n
end

-- Levels <-> compact text "price:qty,price:qty" (the LADDER_LEVELS cheapest).
local function PackLadder(lv)
    local parts = {}
    for i = 1, math.min(#lv, S.LADDER_LEVELS) do parts[i] = lv[i][1] .. ":" .. lv[i][2] end
    return table.concat(parts, ",")
end
local function UnpackLadder(s)
    local m = {}
    for p, q in (s or ""):gmatch("(%d+):(%d+)") do m[tonumber(p)] = tonumber(q) end
    return m
end

-- Units gone / added between two scans, over the price range both have seen.
function S.Diff(prev, prevHi, now, nowHi)
    local hi = math.min(prevHi or 0, nowHi or 0)
    local gone, new = 0, 0
    for p, q in pairs(prev) do
        if p <= hi then
            local d = (now[p] or 0) - q
            if d < 0 then gone = gone - d else new = new + d end
        end
    end
    for p, q in pairs(now) do
        if p <= hi and not prev[p] then new = new + q end
    end
    return gone, new
end

-- ------------------------------------------------------------ helpers
local function Median(vals)
    local n = #vals
    if n == 0 then return nil end
    table.sort(vals)
    if n % 2 == 1 then return vals[(n + 1) / 2] end
    return (vals[n / 2] + vals[n / 2 + 1]) / 2
end
S.Median = Median

-- Samples of the open day -> { {t, low, qty, depth}, ... } (absolute times).
local sampleCache = setmetatable({}, { __mode = "k" })
local function Samples(o)
    if not o then return {} end
    local c = sampleCache[o]
    if c and c.s == o[2] then return c.list end
    local list, base = {}, o[1] * 86400
    for rec in ((o[2] or "") .. ";"):gmatch("([^;]*);") do
        if rec ~= "" then
            local f = Fields(rec, SAMPLES)
            if f[1] then list[#list + 1] = { base + f[1], f[2], f[3], f[4] } end
        end
    end
    sampleCache[o] = { s = o[2], list = list }
    return list
end
S.Samples = Samples

-- Units that disappeared between consecutive samples (prevQty / prevT: the scan before the first one).
local function SoldOver(list, prevQty, prevT)
    local sold, pq, pt = 0, prevQty, prevT
    for _, s in ipairs(list) do
        local q = s[3]
        if q and pq and pt and s[1] - pt <= S.DIFF_MAX_GAP and pq > q then sold = sold + (pq - q) end
        if q then pq, pt = q, s[1] end
    end
    return sold
end

-- Daily record built from the open day (and the per-scan points of that day, for tracked items).
-- Does not change the entry: also used to show today's figures before the day is closed.
-- withPoints: also read the day's per-scan points (market price, gone, added), slower.
local function DayRecord(e, withPoints)
    local o = e.o
    if not o then return nil end
    local day, list = o[1], Samples(o)
    local lows, qtys, deps = {}, {}, {}
    local low, high = o[3], nil
    for _, s in ipairs(list) do
        if s[2] then
            lows[#lows + 1] = s[2]
            low = low and math.min(low, s[2]) or s[2]
            high = high and math.max(high, s[2]) or s[2]
        end
        if s[3] then qtys[#qtys + 1] = s[3] end
        if s[4] then deps[#deps + 1] = s[4] end
    end
    if #list == 0 and not low then return nil end
    local r = { day }
    r[D_LOW], r[D_HIGH] = low, high
    r[D_USUAL] = Median(lows) or o[3]
    r[D_QTY] = Median(qtys)
    r[D_DEPTH] = Median(deps)
    r[D_SCANS] = #list
    if #list >= 2 then r[D_SOLD] = SoldOver(list, e.lq, e.lst) end
    -- Per-scan points of the day: market price and units gone / added (tracked items with a ladder).
    if withPoints and e.s then
        local ms, mn, g, a
        for _, p in ipairs(Records(e.s, day * 86400, POINTS)) do
            if Day(p[1]) == day then
                if p[3] then ms, mn = (ms or 0) + p[3], (mn or 0) + 1 end
                if p[5] then g = (g or 0) + p[5] end
                if p[6] then a = (a or 0) + p[6] end
            end
        end
        if mn then r[D_MKT] = ms / mn end
        r[D_GONE], r[D_NEW] = g, a
    end
    return r
end
S.DayRecord = DayRecord

-- Weekly record from the daily records of one week.
local function WeekRecord(week, days)
    local r = { week }
    local usual, qty, dep = {}, {}, {}
    local sold, soldDays, scans = 0, 0, 0
    for _, d in ipairs(days) do
        if d[D_LOW] then r[W_LOW] = r[W_LOW] and math.min(r[W_LOW], d[D_LOW]) or d[D_LOW] end
        local hi = d[D_HIGH] or d[D_LOW]
        if hi then r[W_HIGH] = r[W_HIGH] and math.max(r[W_HIGH], hi) or hi end
        local u = d[D_USUAL] or d[D_LOW]
        if u then usual[#usual + 1] = u end
        if d[D_QTY] then qty[#qty + 1] = d[D_QTY] end
        if d[D_DEPTH] then dep[#dep + 1] = d[D_DEPTH] end
        local sd = d[D_SOLD] or d[D_GONE]
        if sd then sold, soldDays = sold + sd, soldDays + 1 end
        scans = scans + (d[D_SCANS] or 0)
    end
    r[W_USUAL], r[W_QTY], r[W_DEPTH] = Median(usual), Median(qty), Median(dep)
    if soldDays > 0 then r[W_SOLD], r[W_SOLDDAYS] = sold, soldDays end
    r[W_SCANS] = scans
    return r
end

-- Drops what is too old: per-scan points past 7 days, daily records past the window (their complete
-- weeks become weekly records), weekly records past a year.
function S.Prune(e, tracked, today)
    local now = today * 86400 + 86399
    if e.s then
        local pts, keep = Records(e.s, nil, POINTS), {}
        -- At the cap, trim to 50 under it so the next scans do not re-pack everything each time.
        local from = #pts >= S.MAX_SCANS and (#pts - (S.MAX_SCANS - 50) + 1) or 1
        for i = from, #pts do
            if now - pts[i][1] <= S.KEEP_SCANS then keep[#keep + 1] = pts[i] end
        end
        if #keep < #pts then e.s = #keep > 0 and Pack(keep, POINTS) or nil end
    end
    if e.d and tracked then
        -- Past 30 days, a tracked day keeps its Sold but no longer the units gone / added.
        local days = Records(e.d, nil, DAYS)
        local cut, changed = today - S.KEEP_DAYS, false
        local copy = {}
        for i, d in ipairs(days) do
            if d[1] < cut and (d[D_GONE] or d[D_NEW]) then
                local c = {}
                for k = 1, D_MKT do c[k] = d[k] end
                if not c[D_SOLD] then c[D_SOLD] = d[D_GONE] end
                d, changed = c, true
            end
            copy[i] = d
        end
        if changed then e.d = Pack(copy, DAYS) end
    end
    if e.d then
        local keepDays = tracked and S.KEEP_DAYS_TRACKED or S.KEEP_DAYS
        local cut = today - keepDays -- days before cut leave the daily window
        local days = Records(e.d, nil, DAYS)
        if days[1] and days[1][1] < cut then
            -- A week moves only once it is entirely before cut.
            local lastFullWeek = S.Week(cut) - 1
            local keep, byWeek, order = {}, {}, {}
            for _, d in ipairs(days) do
                local wk = S.Week(d[1])
                if d[1] < cut and wk <= lastFullWeek then
                    if not byWeek[wk] then byWeek[wk] = {}; order[#order + 1] = wk end
                    table.insert(byWeek[wk], d)
                else
                    keep[#keep + 1] = d
                end
            end
            if #order > 0 then
                local weeks = {}
                for _, w in ipairs(Records(e.w, nil, WEEKS)) do weeks[#weeks + 1] = w end
                for _, wk in ipairs(order) do
                    local rec = WeekRecord(wk, byWeek[wk])
                    if weeks[#weeks] and weeks[#weeks][1] == wk then weeks[#weeks] = rec
                    elseif not weeks[#weeks] or weeks[#weeks][1] < wk then weeks[#weeks + 1] = rec end
                end
                e.w = #weeks > 0 and Pack(weeks, WEEKS) or nil
                e.d = #keep > 0 and Pack(keep, DAYS) or nil
            end
        end
    end
    if e.w then
        local weeks = Records(e.w, nil, WEEKS)
        local cut = S.Week(today) - S.KEEP_WEEKS
        if weeks[1] and weeks[1][1] < cut then
            local keep = {}
            for _, w in ipairs(weeks) do if w[1] >= cut then keep[#keep + 1] = w end end
            e.w = #keep > 0 and Pack(keep, WEEKS) or nil
        end
    end
end

-- Closes the open day: its record joins the daily ones.
function S.Close(e, tracked, today)
    local o = e.o
    if not o then return end
    local rec = DayRecord(e, true)
    -- Nothing listed all day and nothing gone: no record (a missing day reads as "nothing known").
    if rec and not rec[D_LOW] and (rec[D_QTY] or 0) == 0 and (rec[D_SOLD] or 0) == 0 and (rec[D_GONE] or 0) == 0 then
        local list = Samples(o)
        for i = #list, 1, -1 do
            if list[i][3] then e.lq, e.lst = list[i][3], list[i][1]; break end
        end
        rec = nil
    end
    if rec then
        local last = LastKey(e.d)
        if last and last >= rec[1] then
            -- Same day already closed (data merged from another realm key): keep the record with more scans.
            local days = Records(e.d, nil, DAYS)
            local copy = {}
            for i, d in ipairs(days) do copy[i] = d end
            local dl = copy[#copy]
            if dl[1] == rec[1] and (dl[D_SCANS] or 0) <= (rec[D_SCANS] or 0) then copy[#copy] = rec end
            e.d = Pack(copy, DAYS)
        else
            e.d = Append(e.d, rec, DAYS)
        end
        local list = Samples(o)
        for i = #list, 1, -1 do
            if list[i][3] then e.lq, e.lst = list[i][3], list[i][1]; break end
        end
    end
    e.o = nil
    S.Prune(e, tracked, today or o[1] + 1)
end

-- ------------------------------------------------------------ recording
-- One observation of an item.
--   low: lowest unit price (nil: nothing listed); qty: units listed
--   full: the item's whole listing was read (reliable quantity): a sample of the day. Otherwise only the low.
--   ladder (optional): { [unit price] = qty } -> depth; for tracked items also market price, gone and added.
--   tracked: keep per-scan points.
function S.Observe(e, low, qty, full, ladder, tracked, now)
    local day = Day(now)
    if e.o and e.o[1] ~= day then S.Close(e, tracked, day) end
    if not e.o then e.o = { day, "" } end
    local o = e.o
    if not full then
        if low then o[3] = o[3] and math.min(o[3], low) or low end
        return
    end
    local lv, blow, mkt, first, depth
    if ladder then
        lv = S.Levels(ladder)
        blow, mkt, first = S.Analyze(lv)
        depth = S.Depth(lv, first)
    end
    -- Sample of the day (merged with the previous one when it is the same scan).
    local sec = now - day * 86400
    local sample = PackOne({ sec, low, qty or 0, depth }, nil, SAMPLES)
    local list = Samples(o)
    local lastS = list[#list]
    local window = #list >= S.MAX_SAMPLES and S.MERGE_BUSY or S.MERGE
    if lastS and now - lastS[1] < window and now >= lastS[1] then
        local head = o[2]:match("^(.*);[^;]*$")
        o[2] = head and (head .. ";" .. sample) or sample
    else
        o[2] = o[2] == "" and sample or (o[2] .. ";" .. sample)
    end
    if not tracked then return end
    -- Per-scan point (tracked items): bait-free low, market price, units gone / added since the last scan.
    local gone, new
    if lv then
        low = blow
        local nowHi = #lv == 0 and math.huge or lv[math.min(#lv, S.LADDER_LEVELS)][1]
        if e.lad and e.lat and now - e.lat <= S.DIFF_MAX_GAP then
            gone, new = S.Diff(UnpackLadder(e.lad), (e.lhi == -1) and math.huge or e.lhi, ladder, nowHi)
        end
        -- lhi = highest price seen (-1: nothing listed, every future level counts as added)
        e.lad, e.lhi, e.lat = PackLadder(lv), nowHi ~= math.huge and nowHi or -1, now
    end
    local lastT = LastKey(e.s)
    if lastT and now >= lastT and now - lastT < S.MERGE then
        -- Same scan seen through two paths (full scan then search): keep the latest, add up the differences.
        local pts = Records(e.s, lastT, POINTS)
        local lp = pts[#pts]
        local g = (gone or lp[5]) and ((lp[5] or 0) + (gone or 0)) or nil
        local a = (new or lp[6]) and ((lp[6] or 0) + (new or 0)) or nil
        e.s = ReplaceLast(e.s, { lastT, low, mkt or lp[3], qty or 0, g, a, depth or lp[7] }, POINTS)
    else
        e.s = Append(e.s, { now, low, mkt, qty or 0, gone, new, depth }, POINTS)
        -- Keep the string bounded between two day closes (the busy-day cap).
        if select(2, e.s:gsub(";", "")) >= S.MAX_SCANS then S.Prune(e, true, day) end
    end
end

-- ------------------------------------------------------------ reading
-- Daily records from fromDay (nil: all), today's open day included as a last provisional record.
-- withPoints: the open day's market price, gone and added too (read from the per-scan points).
function S.Days(e, fromDay, withPoints)
    if not e then return {} end
    local out = Records(e.d, fromDay, DAYS)
    local open = DayRecord(e, withPoints)
    if open and (not fromDay or open[1] >= fromDay) then
        if out[#out] and out[#out][1] == open[1] then out[#out] = open else out[#out + 1] = open end
        open.open = true
    end
    return out
end

function S.Weeks(e, fromWeek) return e and Records(e.w, fromWeek, WEEKS) or {} end

-- Per-scan points from time fromT (nil: all): { {t, low, mkt, qty, gone, new, depth}, ... }
function S.Points(e, fromT) return e and Records(e.s, fromT, POINTS) or {} end

-- Closes every open day older than today (at login), and prunes.
function S.CloseAll(db, isTracked, today)
    for _, items in pairs(db.prices or {}) do
        if type(items) == "table" then
            for id, e in pairs(items) do
                if type(e) == "table" and e.o and e.o[1] < today then S.Close(e, isTracked(id), today) end
            end
        end
    end
end

-- ------------------------------------------------------------ merging (data saved under an empty realm name)
local function MergeLists(a, b, kind, better)
    local by, order = {}, {}
    for _, r in ipairs(a) do by[r[1]] = r; order[#order + 1] = r[1] end
    for _, r in ipairs(b) do
        local x = by[r[1]]
        if not x then by[r[1]] = r; order[#order + 1] = r[1]
        elseif better(r, x) then by[r[1]] = r end
    end
    table.sort(order)
    local out = {}
    for i, k in ipairs(order) do out[i] = by[k] end
    return #out > 0 and Pack(out, kind) or nil
end

function S.MergeEntry(dst, src, tracked, today)
    if dst.o and dst.o[1] < today then S.Close(dst, tracked, today) end
    if src.o and src.o[1] < today then S.Close(src, tracked, today) end
    local more = function(n) return function(r, x) return (r[n] or 0) > (x[n] or 0) end end
    dst.d = MergeLists(Records(dst.d, nil, DAYS), Records(src.d, nil, DAYS), DAYS, more(D_SCANS))
    dst.w = MergeLists(Records(dst.w, nil, WEEKS), Records(src.w, nil, WEEKS), WEEKS, more(W_SCANS))
    dst.s = MergeLists(Records(dst.s, nil, POINTS), Records(src.s, nil, POINTS), POINTS, function() return false end)
    if src.o then
        if not dst.o then dst.o = src.o
        else
            local all = {}
            for _, s in ipairs(Samples(dst.o)) do all[#all + 1] = s end
            for _, s in ipairs(Samples(src.o)) do all[#all + 1] = s end
            table.sort(all, function(a, b) return a[1] < b[1] end)
            local parts, base = {}, dst.o[1] * 86400
            for i, s in ipairs(all) do parts[i] = PackOne({ s[1] - base, s[2], s[3], s[4] }, nil, SAMPLES) end
            local p = (dst.o[3] and src.o[3]) and math.min(dst.o[3], src.o[3]) or dst.o[3] or src.o[3]
            dst.o = { dst.o[1], table.concat(parts, ";"), p }
        end
    end
    if (src.t or 0) >= (dst.t or 0) then dst.cur, dst.qty, dst.t = src.cur, src.qty, src.t end
    if (src.lst or 0) > (dst.lst or 0) then dst.lq, dst.lst = src.lq, src.lst end
    if (src.lat or 0) > (dst.lat or 0) then dst.lad, dst.lhi, dst.lat = src.lad, src.lhi, src.lat end
    S.Prune(dst, tracked, today)
end

-- ------------------------------------------------------------ migration from the v1.0 format
-- Old: prices[realm][id] = { cur, qty, t, d = { {day, low, qty}, ... }, h = { {t, low, qty}, ... } }
--      hist[realm][id]   = { s = { "t,low,mkt,qty,gone,new", ... }, d = { "day,low,Σmkt,n mkt,qty,gone,new,scans", ... },
--                            lad, lhi, lt }
-- Items with a hist entry were the tracked ones (in a list).
local function MigrateEntry(e, h, now)
    local today = Day(now)
    -- Per-scan points: the History ones (they have the market price), else the 15-min ones of prices.
    local pts = {}
    if h and h.s and #h.s > 0 then
        for _, s in ipairs(h.s) do
            local f = DecimalFields(s)
            if f[1] then pts[#pts + 1] = { f[1], f[2], f[3], f[4], f[5], f[6] } end
        end
    else
        for _, p in ipairs(e.h or {}) do
            pts[#pts + 1] = { p[1], p[2] ~= 0 and p[2] or nil, nil, p[3] }
        end
    end
    table.sort(pts, function(a, b) return a[1] < b[1] end)
    -- Daily records: History's, else prices'.
    local byDay, order = {}, {}
    local function Put(r) if not byDay[r[1]] then order[#order + 1] = r[1] end; byDay[r[1]] = r end
    if h and h.d and #h.d > 0 then
        for _, s in ipairs(h.d) do
            local f = DecimalFields(s)
            if f[1] then
                local r = { f[1] }
                r[D_LOW], r[D_USUAL], r[D_QTY] = f[2], f[2], f[5]
                r[D_MKT] = (f[4] or 0) > 0 and f[3] and f[3] / f[4] or nil
                r[D_GONE], r[D_NEW], r[D_SCANS] = f[6], f[7], f[8]
                Put(r)
            end
        end
    end
    for _, p in ipairs(e.d or {}) do
        if not byDay[p[1]] then
            local r = { p[1] }
            r[D_LOW], r[D_USUAL], r[D_QTY] = p[2], p[2], p[3]
            Put(r)
        end
    end
    -- Days covered by per-scan points: recompute high, usual, qty and sold from them.
    local ptsByDay = {}
    for _, p in ipairs(pts) do
        local dd = Day(p[1])
        ptsByDay[dd] = ptsByDay[dd] or {}
        table.insert(ptsByDay[dd], { p[1], p[2], p[4] })
    end
    local prevQ, prevT
    local days = {}
    for dd in pairs(ptsByDay) do days[#days + 1] = dd end
    table.sort(days)
    for _, dd in ipairs(days) do
        local list = ptsByDay[dd]
        if dd < today then
            local r = byDay[dd] or { dd }
            local lows, qtys, high, low = {}, {}, nil, r[D_LOW]
            for _, s in ipairs(list) do
                if s[2] then
                    lows[#lows + 1] = s[2]
                    high = high and math.max(high, s[2]) or s[2]
                    low = low and math.min(low, s[2]) or s[2]
                end
                if s[3] then qtys[#qtys + 1] = s[3] end
            end
            r[D_LOW], r[D_HIGH] = low, high
            r[D_USUAL] = Median(lows) or r[D_USUAL]
            r[D_QTY] = Median(qtys) or r[D_QTY]
            r[D_SCANS] = math.max(r[D_SCANS] or 0, #list)
            if #list >= 2 then r[D_SOLD] = SoldOver(list, prevQ, prevT) end
            Put(r)
        end
        for i = #list, 1, -1 do if list[i][3] then prevQ, prevT = list[i][3], list[i][1]; break end end
    end
    -- Today stays open: its points become the day's samples.
    local n = {}
    n.cur, n.qty, n.t = e.cur, e.qty, e.t
    local todayPts = ptsByDay[today]
    if todayPts or byDay[today] then
        local parts = {}
        for _, s in ipairs(todayPts or {}) do parts[#parts + 1] = PackOne({ s[1] - today * 86400, s[2], s[3] or 0 }, nil, SAMPLES) end
        local r = byDay[today]
        if #parts == 0 and r and e.t and Day(e.t) == today then
            parts[1] = PackOne({ e.t - today * 86400, r[D_LOW], r[D_QTY] or 0 }, nil, SAMPLES)
        end
        n.o = { today, table.concat(parts, ";"), (#parts == 0 and r) and r[D_LOW] or nil }
        byDay[today] = nil
    end
    -- Sales across midnight: the last point before today.
    for i = #pts, 1, -1 do
        if Day(pts[i][1]) < today and pts[i][4] then n.lq, n.lst = pts[i][4], pts[i][1]; break end
    end
    local list = {}
    table.sort(order)
    for _, dd in ipairs(order) do if byDay[dd] then list[#list + 1] = byDay[dd] end end
    n.d = #list > 0 and Pack(list, DAYS) or nil
    local keep = {}
    for _, p in ipairs(pts) do if now - p[1] <= S.KEEP_SCANS then keep[#keep + 1] = p end end
    n.s = (h and #keep > 0) and Pack(keep, POINTS) or nil
    if h then n.lad, n.lhi, n.lat = h.lad, h.lhi, h.lt end
    S.Prune(n, h ~= nil, today)
    return n
end
S.MigrateEntry = MigrateEntry

-- Converts every realm once. Returns the number of items converted.
function S.Migrate(db, now)
    if db.priceFormat == 2 then return 0 end
    now = now or time()
    local count = 0
    for realm, items in pairs(db.prices or {}) do
        if type(items) == "table" then
            local hist = db.hist and db.hist[realm] or {}
            for id, e in pairs(items) do
                if type(e) == "table" and (type(e.d) == "table" or e.h) then
                    items[id] = MigrateEntry(e, hist[id], now)
                    count = count + 1
                end
            end
            -- History of items never priced (should not happen): their own entry.
            for id, h in pairs(hist) do
                if not items[id] and type(h) == "table" then items[id] = MigrateEntry({}, h, now); count = count + 1 end
            end
        end
    end
    db.hist = nil
    db.priceFormat = 2
    return count
end
