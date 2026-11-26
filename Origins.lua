-- ImpotPointGouv: where the items you sell come from (farmed, bought, crafted), to split your income.
-- Rebuilt from the logs the addon already keeps, nothing new is saved:
--   ns.db.loot : looted ("l"), crafted ("c"), quest reward ("q"), bought from a vendor ("v"),
--                taken from the mailbox ("p": a transfer between your characters or an AH return)
--   ns.db.tx   : AH purchases (ah_buy, price paid) and AH sales (ah_sale, net received)
-- Each item keeps a queue of units, oldest first, shared by your characters (mail keeps the origin).
-- A sale takes the oldest units. Units sold that the logs never saw arrive (owned before tracking,
-- quest items from before, ...) count as farmed.
local _, ns = ...
local Tr = ns.L
local O = {}
ns.Origins = O

O.KINDS = { farmed = true, bought = true, crafted = true }

local SRC = { l = "farmed", q = "farmed", c = "crafted", v = "bought" }

-- Events of the logs in time order: { t, name, kind, qty, unit (bought), net (sale) }.
local function Events()
    local ev = {}
    for _, e in ipairs(ns.db.loot or {}) do
        local kind = SRC[e.s]
        if kind and e.i then
            ev[#ev + 1] = { t = e.t, name = e.i, id = e.id, kind = kind, qty = e.n or 1,
                unit = kind == "bought" and e.id and ns.db.vendor and ns.db.vendor[e.id] or nil }
        end
    end
    for _, tx in ipairs(ns.db.tx or {}) do
        if tx.k == "ah_buy" and tx.i then
            local q = (tx.q and tx.q > 0) and tx.q or 1
            ev[#ev + 1] = { t = tx.t, name = tx.i, kind = "bought", qty = q, unit = math.floor(-(tx.a or 0) / q) }
        elseif tx.k == "ah_sale" and tx.i then
            ev[#ev + 1] = { t = tx.t, name = tx.i, sale = true, qty = (tx.q and tx.q > 0) and tx.q or 1, net = tx.a or 0 }
        end
    end
    -- Acquisitions before sales at the same second (a sale cannot use what arrives after it).
    table.sort(ev, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return (a.sale and 1 or 0) < (b.sale and 1 or 0)
    end)
    return ev
end

-- A craft uses up its reagents (oldest units first): what it consumed is no longer for sale.
local function Consume(lots, name, n)
    local q = lots[name]
    while q and n > 0 and q[1] do
        local take = math.min(n, q[1].n)
        q[1].n = q[1].n - take
        if q[1].n <= 0 then table.remove(q, 1) end
        n = n - take
    end
end
local function UseReagents(lots, e)
    if e.kind ~= "crafted" or not e.id or not (ns.Lists and ns.Lists.ReagentsOf) then return end
    local ok, rg = pcall(ns.Lists.ReagentsOf, e.id, true)
    if not ok or not rg then return end
    local crafts = e.qty / math.max(1, (ns.Lists.YieldOf and ns.Lists.YieldOf(e.id)) or 1)
    for _, r in ipairs(rg) do
        local name = ns.Prices.Name(r[1])
        if name then Consume(lots, name, math.ceil((r[2] or 1) * crafts - 1e-9)) end
    end
end
O._UseReagents = UseReagents

-- Splits the AH sales made since t0. Returns
--   { farmed = net, bought = net, boughtCost = paid, crafted = net, n = sales, items = { [name] = { ... } } }
-- trading profit = bought - boughtCost.
local splitCache = {}
function O.Split(t0)
    t0 = t0 or 0
    local key = t0 .. ":" .. #(ns.db.loot or {}) .. ":" .. #(ns.db.tx or {})
    if splitCache.key == key then return splitCache.v end
    local res = O.SplitRaw(t0)
    splitCache.key, splitCache.v = key, res
    return res
end
function O.SplitRaw(t0)
    local lots = {}
    local out = { farmed = 0, bought = 0, boughtCost = 0, crafted = 0, n = 0 }
    for _, e in ipairs(Events()) do
        local q = lots[e.name]
        if not q then q = {}; lots[e.name] = q end
        if not e.sale then
            UseReagents(lots, e)
            q[#q + 1] = { kind = e.kind, n = e.qty, unit = e.unit }
        else
            local left, perUnit = e.qty, e.net / e.qty
            while left > 0 do
                local lot = q[1]
                local take, kind, unit
                if lot then
                    take = math.min(left, lot.n)
                    kind, unit = lot.kind, lot.unit
                    lot.n = lot.n - take
                    if lot.n <= 0 then table.remove(q, 1) end
                else
                    take, kind = left, "farmed" -- owned before tracking
                end
                if e.t >= t0 then
                    out[kind] = out[kind] + perUnit * take
                    if kind == "bought" then out.boughtCost = out.boughtCost + (unit or 0) * take end
                end
                left = left - take
            end
            if e.t >= t0 then out.n = out.n + 1 end
        end
    end
    out.trading = out.bought - out.boughtCost
    return out
end

-- Units still held by origin, per item name (what is left in the queues): { [name] = { farmed = n, ... } }.
function O.Held()
    local lots = {}
    for _, e in ipairs(Events()) do
        local q = lots[e.name]
        if not q then q = {}; lots[e.name] = q end
        if not e.sale then
            UseReagents(lots, e)
            q[#q + 1] = { kind = e.kind, n = e.qty, unit = e.unit }
        else
            local left = e.qty
            while left > 0 and q[1] do
                local take = math.min(left, q[1].n)
                q[1].n = q[1].n - take
                if q[1].n <= 0 then table.remove(q, 1) end
                left = left - take
            end
        end
    end
    local out = {}
    for name, q in pairs(lots) do
        for _, lot in ipairs(q) do
            out[name] = out[name] or {}
            out[name][lot.kind] = (out[name][lot.kind] or 0) + lot.n
            if lot.kind == "bought" then out[name].paid = (out[name].paid or 0) + (lot.unit or 0) * lot.n end
        end
    end
    return out
end
