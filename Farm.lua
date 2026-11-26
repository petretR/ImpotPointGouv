-- ImpotPointGouv: what is worth farming now, for any player (Market tab, "Farm").
-- Candidates: raw materials that anyone can loot or that your gathering professions collect (cloth,
-- meat & fish, leather, ore, herbs, elemental, enchanting mats), plus the raw reagents of the recipes
-- your characters know. Rare drops are left out on purpose: only these item types are considered.
-- Each candidate gets: price, 7-day trend against the 30-day usual price, units sold per day, the stock
-- listed and how it moves, and (when you farmed it yourself) gold per hour and the best zone, from the
-- loot log and the time spent per zone.
local _, ns = ...
local Tr = ns.L
local P = ns.Prices
local F = {}
ns.Farm = F

-- Trade goods subclasses and who can get them ("any" = loot from mobs; otherwise a gathering profession).
F.RAW = {
    [5] = { "any", Tr("Cloth") }, [8] = { "any", Tr("Meat & fish") }, [10] = { "any", Tr("Elemental") },
    [6] = { "skinning", Tr("Leather") }, [7] = { "mining", Tr("Metal & Stone") }, [9] = { "herbalism", Tr("Herb") },
    [12] = { "enchanting", Tr("Enchanting") },
}
-- Profession skill lines and names (English and French clients) of the gathering-like professions.
local LINES = { [393] = "skinning", [186] = "mining", [182] = "herbalism", [356] = "fishing", [333] = "enchanting" }
local NAMES = {
    skinning = { "skinning", "dépeçage" }, mining = { "mining", "minage" }, herbalism = { "herbalism", "herboristerie" },
    fishing = { "fishing", "pêche" }, enchanting = { "enchanting", "enchantement" },
}

local function Instant(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not f then return nil end
    local ok, _, _, _, _, _, classID, subID = pcall(f, id)
    if ok then return classID, subID end
end

-- What your characters can collect: { any = true, skinning = true, ... }.
function F.Abilities()
    local out = { any = true }
    for _, c in pairs(ns.db.chars or {}) do
        for _, p in ipairs(c.profs or {}) do
            local k = p.line and LINES[p.line]
            if not k then
                local n = (p.name or ""):lower()
                for key, list in pairs(NAMES) do
                    for _, w in ipairs(list) do if n == w then k = key end end
                end
            end
            if k then out[k] = true end
        end
    end
    return out
end

-- Raw reagents of the recipes your characters know: { [itemID] = true }.
local function KnownReagents()
    local out = {}
    for _, recipes in pairs(ns.db.recipes or {}) do
        for _, r in pairs(recipes) do
            for _, rg in ipairs(r.r or {}) do
                if rg[1] and not (ns.db.vendor and ns.db.vendor[rg[1]]) then out[rg[1]] = true end
            end
        end
    end
    return out
end

-- Gold per hour you made looting an item, and the zone where it came fastest (loot log + time per zone).
function F.YourRates()
    local units = {}   -- [id][zone] = n
    for _, e in ipairs(ns.db.loot or {}) do
        if e.s == "l" and e.id and e.z then
            units[e.id] = units[e.id] or {}
            units[e.id][e.z] = (units[e.id][e.z] or 0) + (e.n or 1)
        end
    end
    local hours = {}   -- [zone] = h, all characters
    for _, zones in pairs(ns.db.zt or {}) do
        for z, sec in pairs(zones) do hours[z] = (hours[z] or 0) + sec / 3600 end
    end
    local out = {}
    for id, byZone in pairs(units) do
        local best, bestZ, bestN = 0, nil, 0
        for z, n in pairs(byZone) do
            local h = hours[z] or 0
            if h >= 0.5 and n >= 5 and n / h > best then best, bestZ, bestN = n / h, z, n end
        end
        if bestZ then out[id] = { perHour = best, zone = bestZ, units = bestN } end
    end
    return out
end

local function Median(t)
    if #t == 0 then return nil end
    table.sort(t)
    return t[math.floor((#t + 1) / 2)]
end

-- 30-day usual price, and the quantity listed about a week ago (daily records).
local function History(e)
    local S = ns.Store
    if not (e and S and S.Days) then return nil end
    local today = math.floor(time() / 86400)
    local days = S.Days(e, today - 30)
    local vals, qtyWeek = {}, nil
    for _, d in ipairs(days) do
        local v = d[S.D.usual] or d[S.D.low]
        if v and v > 0 then vals[#vals + 1] = v end
        -- Quantity listed a week ago: that day if known, else the closest day before it (up to 3 days).
        if d[S.D.qty] and d[1] <= today - 7 and d[1] >= today - 10 then qtyWeek = d[S.D.qty] end
    end
    return Median(vals), qtyWeek, #vals
end

-- The list, best first. mineOnly: only what your characters can collect (or use in a known recipe).
function F.List(mineOnly)
    local can = F.Abilities()
    local known = KnownReagents()
    local rates = F.YourRates()
    local out = {}
    for id, e in pairs(ns.db.prices and ns.db.prices[ns.Realm()] or {}) do
        if type(id) == "number" and e.cur then
            local classID, subID = Instant(id)
            local raw = classID == 7 and F.RAW[subID]
            local mine = raw and can[raw[1]] or false
            if raw and (not mineOnly or mine or known[id]) then
                local st = P.Stats and P.Stats(id)
                local price = P.AHValue and P.AHValue(id) or e.cur
                local usual30, qtyWeek, ndays = History(e)
                local sales = st and st.sales or nil
                local row = { id = id, price = price, sales = sales, listed = e.qty or 0, what = raw[2],
                    who = raw[1], known = known[id] or nil, usual = usual30 }
                if st and st.med and usual30 and usual30 > 0 and (ndays or 0) >= 5 then row.trend = st.med / usual30 - 1 end
                if qtyWeek and qtyWeek > 0 then row.stockMove = (e.qty or 0) / qtyWeek - 1 end
                local r = rates[id]
                if r and price then row.gph, row.zone = r.perHour * price * 0.95, r.zone end
                -- Worth farming now: the price rises, it sells, and the stock listed goes down.
                row.hot = (row.trend or 0) >= 0.10 and (sales or 0) >= 1 and (row.stockMove or 0) < 0
                -- Ranking: gold the market can absorb per day, boosted by a rising price.
                row.score = (price or 0) * math.min(sales or 0, 50) * (1 + math.max(0, row.trend or 0))
                if (sales or 0) >= 0.5 then out[#out + 1] = row end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.hot ~= b.hot then return a.hot end
        return a.score > b.score
    end)
    return out
end

function F.ZoneName(z)
    return (ns.db.zones and ns.db.zones[z]) or (C_Map and C_Map.GetMapInfo and (C_Map.GetMapInfo(z) or {}).name) or "?"
end

-- Wowhead page of an item (WoW Forever database).
function F.WowheadURL(id) return ("https://www.wowhead.com/forever/item=%d"):format(id) end

-- Copy box for the link: the addon's own dialog (a Blizzard popup taints the game's code, #33).
function F.ShowURL(id)
    local T = ns.Theme
    if not T.Dialog then return end
    T.Dialog({ text = Tr("Copy the link (Ctrl+C):"), input = true, default = F.WowheadURL(id), accept = OKAY or "OK", noCancel = true })
end
