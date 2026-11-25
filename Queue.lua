-- ImpotPointGouv: craft queue, shopping list, purchases (vendor / AH) and "Craft next".
--
-- Queue: ns.db.queue[key] = { prof, name, n, auto }  (key = profession .. "\001" .. recipe)
--   auto = added by "Queue profitable" (replaced on each new calculation), otherwise added by hand.
-- Plan: the queue + the intermediate crafts needed (e.g. Cured Light Hide) when crafting them
--   costs less than buying them, then the shopping list (need − bags/bank − alts).
local _, ns = ...
local Tr = ns.L
local T, P, CR, I = ns.Theme, ns.Prices, ns.Craft, ns.Inventory
local C = T.C
local Q = {}
ns.Queue = Q

local SEP = "\001"
local function Me() return UnitGUID("player") end
-- One queue per character: the key contains the owner.
local function Key(prof, name, owner) return (prof or "?") .. SEP .. name .. SEP .. (owner or Me() or "?") end
local function DB()
    ns.db.queue = ns.db.queue or {}
    local db = ns.db.queue
    if not ns.db.queueV2 then
        -- Old format (one shared queue): attach each entry to its owner.
        local moved = {}
        for k, e in pairs(db) do
            local _, n = k:gsub(SEP, "")
            if n < 2 then moved[k] = e end
        end
        for k, e in pairs(moved) do
            db[k] = nil
            db[Key(e.prof, e.name, e.owner)] = e
        end
        ns.db.queueV2 = true
    end
    return db
end

-- Crafting material (bolts, cured leather…): used by other recipes, never queued to be sold.
function Q.IsMaterial(id)
    local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not id or not f then return false end
    local ok, _, _, _, _, _, classID = pcall(f, id)
    return ok and classID == 7
end

-- ------------------------------------------------------------ crafters (several possible)
local function CrafterSet()
    local st = ns.db.settings
    if not st.crafters then
        st.crafters = {}
        if st.crafterChar then st.crafters[st.crafterChar] = true end
        for _, e in pairs(ns.db.queue or {}) do if e.owner then st.crafters[e.owner] = true end end
    end
    return st.crafters
end
function Q.IsCrafter(key) return key ~= nil and CrafterSet()[key] == true end
function Q.SetCrafter(key, on) CrafterSet()[key] = on or nil; Q.Refresh() end
function Q.Crafters()
    local list = {}
    for k in pairs(CrafterSet()) do if ns.db.chars[k] then list[#list + 1] = k end end
    table.sort(list, function(a, b) return (ns.db.chars[a].name or "") < (ns.db.chars[b].name or "") end)
    return list
end
-- The character whose queue it is: yourself if you have a queue, otherwise "*" on the bank (all crafters).
function Q.Owner()
    local me = Me()
    for _, e in pairs(DB()) do if e.owner == me then return me end end
    if Q.IsCrafter(me) then return me end
    if ns.db.settings.bankChar == me then return "*" end
    return me
end

-- ------------------------------------------------------------ recipes
local function LiveRec(prof, name)
    if prof ~= CR.ProfName() then return nil end
    for _, r in ipairs(CR.GetRecipes()) do if r.name == name then return r end end
end

local function RecFrom(prof, name)
    local live = LiveRec(prof, name)
    if live then return live end
    local r = ns.db.recipes[prof] and ns.db.recipes[prof][name]
    if not r then return nil end
    local rec = { name = name, pid = r.p, made = r.m or 1, reagents = {}, enchant = r.p == nil,
        icon = r.p and ns.GetItemIcon(r.p) }
    for _, rg in ipairs(r.r or {}) do
        rec.reagents[#rec.reagents + 1] = { id = rg[1], n = rg[2], name = P.Name(rg[1]),
            icon = ns.GetItemIcon(rg[1]), have = ns.GetItemCount(rg[1]) }
    end
    return rec
end

-- ------------------------------------------------------------ queue management
function Q.Add(prof, name, n)
    if not prof or not name then return end
    local db = DB()
    local k = Key(prof, name)
    local e = db[k] or { prof = prof, name = name, n = 0 }
    e.n = math.max(0, e.n + (n or 1))
    e.auto = nil
    e.owner = UnitGUID("player")
    db[k] = e.n > 0 and e or nil
    ns.Print((Tr("queue: %s ×%d")):format(name, e.n))
    Q.Refresh()
end

function Q.Clear()
    local owner = Q.Owner()
    local db = DB()
    for k, e in pairs(db) do if owner == "*" or e.owner == owner then db[k] = nil end end
    Q.Refresh()
end

local function Clamp(v, a, b) return math.max(a, math.min(b, v)) end

-- Professions known by the logged-in character (saved when each profession is opened).
function Q.MyProfessions()
    local me, list = UnitGUID("player"), {}
    for prof, chars in pairs(ns.db.profChars or {}) do
        if chars[me] and ns.db.recipes[prof] then list[#list + 1] = prof end
    end
    table.sort(list)
    return list
end

local RecipesOf
function Q.FindRecipe(prof, name)
    for _, rec in ipairs(RecipesOf(prof)) do if rec.name == name then return rec end end
end

function RecipesOf(prof)
    if prof == CR.ProfName() and #CR.GetRecipes() > 0 then return CR.GetRecipes() end
    local list = {}
    for name in pairs(ns.db.recipes[prof] or {}) do
        local rec = RecFrom(prof, name)
        if rec then list[#list + 1] = rec end
    end
    return list
end

-- Fills the queue with profitable recipes, aiming at a target stock.
-- allProfs = true: all the character's professions (otherwise only the open profession).
-- ------------------------------------------------------------ adaptive target (demand)
-- Each item has its own stock target, adjusted from one session to the next according to how
-- the listings posted since the last adjustment went (rules in Q.Target below).
-- Only adjusted when the cycle is resolved (nothing listed any more).

local function AdaptDB() ns.db.settings.adapt = ns.db.settings.adapt or {}; return ns.db.settings.adapt end

-- Replays the history (FIFO): for each unit posted after `since`, sold (and how fast), expired, or still listed.
local function Cycle(name, since)
    local units, open = {}, {}
    local from = math.min(since, time() - 14 * 86400)
    for _, tx in ipairs(ns.db.tx) do
        if tx.t >= from and tx.i == name then
            if tx.k == "ah_deposit" then
                for _ = 1, (tx.q or 1) do local u = { t = tx.t }; units[#units + 1] = u; open[#open + 1] = u end
            elseif tx.k == "ah_sale" then
                local q = (tx.q and tx.q > 0) and tx.q or 1
                for _ = 1, q do local u = table.remove(open, 1); if u then u.sold = (tx.st or tx.t) end end
            elseif tx.k == "ah_expired" or tx.k == "ah_cancelled" then
                for _ = 1, (tx.q or 1) do local u = table.remove(open, 1); if u then u.expired = true end end
            end
        end
    end
    local c = { posted = 0, sold = 0, expired = 0, pending = 0, waits = {} }
    for _, u in ipairs(units) do
        if u.t > since then
            c.posted = c.posted + 1
            if u.sold then c.sold = c.sold + 1; c.waits[#c.waits + 1] = math.max(0, u.sold - u.t)
            elseif u.expired then c.expired = c.expired + 1
            else c.pending = c.pending + 1 end
        end
    end
    table.sort(c.waits)
    c.median = #c.waits > 0 and c.waits[math.ceil(#c.waits / 2)] or nil
    return c
end
Q.Cycle = Cycle

local function Ago(sec)
    if sec < 90 then return sec .. " s" elseif sec < 5400 then return math.floor(sec / 60 + 0.5) .. Tr(" min") end
    return math.floor(sec / 3600 + 0.5) .. " h"
end

-- Stock target to sell for a recipe; `commit` saves the adjustment (Queue profitable).
-- ------------------------------------------------------------ depth: how many to craft while it pays
-- Breaks a recipe down into raw purchases (intermediates crafted if cheaper), then "buys" the materials
-- level by level in the scanned AH, craft after craft, until the next craft is no longer profitable.
local function Expand(id, qty, depth, raw, acc)
    if P.IsVendorItem(id) then
        local vb = P.VendorBuy(id)
        if vb then acc.fixed = acc.fixed + vb * qty; return end
    end
    local prod = depth < 3 and CR.ProducerOf(id)
    if prod then
        local _, src = CR.UnitCost(id)
        if src == "craft" then
            for _, rg in ipairs(prod.r or {}) do Expand(rg[1], rg[2] * qty / math.max(1, prod.m or 1), depth + 1, raw, acc) end
            return
        end
    end
    raw[id] = (raw[id] or 0) + qty
end

function Q.Depth(rec, value, rules, cap)
    if not (ns.Market and ns.Market.Book) or not value then return nil end
    local raw, acc = {}, { fixed = 0 }
    for _, rg in ipairs(rec.reagents or {}) do
        if rg.id then Expand(rg.id, rg.n or 1, 0, raw, acc) end
    end
    -- Price ladder of each raw material, with your stock first (at the lowest price).
    local ladders, age = {}, 0
    for id, q in pairs(raw) do
        local book, a = ns.Market.Book(id)
        if not book then return nil end
        age = math.max(age, a or 0)
        local L = {}
        local stock = I.Mine(id) + (I.Alts(id))
        if stock > 0 then L[1] = { book[1] and book[1][1] or (P.AHValue(id) or 0), stock, own = true } end
        for _, b in ipairs(book) do L[#L + 1] = { b[1], b[2] } end
        ladders[id] = { L = L, i = 1, left = L[1] and L[1][2] or 0, q = q, max = nil, stock = stock }
    end
    local n = 0
    while n < cap do
        local cost, ok = acc.fixed, true
        local snap = {}
        for id, ld in pairs(ladders) do
            snap[id] = { ld.i, ld.left, ld.max }
            local need = ld.q
            while need > 1e-9 do
                local step = ld.L[ld.i]
                if not step then ok = false; break end
                local take = math.min(need, ld.left)
                cost = cost + take * step[1]
                if not step.own then ld.max = step[1] end
                need = need - take
                ld.left = ld.left - take
                if ld.left <= 1e-9 then ld.i = ld.i + 1; ld.left = ld.L[ld.i] and ld.L[ld.i][2] or 0 end
            end
            if not ok then break end
        end
        local profit = value - cost
        if not ok or profit < rules.minProfit or (cost > 0 and profit / cost * 100 < rules.minMargin) then
            for id, sp in pairs(snap) do ladders[id].i, ladders[id].left, ladders[id].max = sp[1], sp[2], sp[3] end
            break
        end
        n = n + 1
    end
    local out = { n = n, max = {}, buy = {}, even = {}, age = age, t = time() }
    for id, ld in pairs(ladders) do
        out.max[id] = ld.max
        out.buy[id] = math.max(0, math.ceil(n * ld.q - ld.stock))
    end
    -- Break-even of each material: the price above which the craft loses money
    -- (the other materials at their current lowest price).
    for id, ld in pairs(ladders) do
        local others = acc.fixed
        for oid, old in pairs(ladders) do
            if oid ~= id then
                local first = old.L[1] and old.L[1][1] or 0
                others = others + (old.max or first) * old.q
            end
        end
        out.even[id] = math.floor((value - others) / ld.q)
    end
    return out
end

-- Gear (not stackable, BoE…): test one at a time and go up 1 by 1.
local function IsSingle(id)
    local _, _, _, _, _, _, _, stack, equipLoc = ns.GetItemInfo(id)
    if stack == 1 then return true end
    return equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_BAG" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" or false
end
Q.IsSingle = IsSingle

-- Stock target to sell for a recipe; `commit` saves the adjustment (Queue profitable).
-- First batch: your own sales of the last 7 days if any, otherwise sized on the market: at most one
-- stack (startCap) and startShare % of the estimated daily sales (gear: 1). Then, from your real sales:
--   everything sold within fastHours → ×2    sold out or ≥ 70 % sold → same batch
--   more than half came back unsold  → ÷2    never above maxQty (5 stacks).
function Q.FirstBatch(rec, ev, rules)
    local single = IsSingle(rec.pid)
    if single then return 1, nil end
    local lo = rules.minQty
    if (ev.sold7 or 0) > 0 then return Clamp(ev.sold7, lo, rules.startCap or 20), nil end
    local rate = ns.Market and ns.Market.Rate and ns.Market.Rate(rec.pid) or 0
    if rate > 0 then
        local n = math.floor(rate * (rules.startShare or 5) / 100)
        return Clamp(n, lo, rules.startCap or 20), rate
    end
    return Clamp(rules.startQty, lo, rules.startCap or 20), nil
end

function Q.Target(rec, ev, rules, commit)
    local single = IsSingle(rec.pid)
    local lo = single and 1 or rules.minQty
    local A = AdaptDB()
    local st = A[rec.pid]
    if not st then
        local t, rate = Q.FirstBatch(rec, ev, rules)
        st = { t = t, at = 0 }
        if rate then st.why = (Tr("%d · first batch, ~%d sold/day on the AH")):format(t, math.floor(rate + 0.5)) end
        if commit then A[rec.pid] = st end
    end
    local name = ns.db.items[rec.pid] or rec.name
    local c = Cycle(name, st.at)
    -- For the vendor, demand is unlimited: aim at the "vendor" cap (the budget then decides).
    if ev.channel == "vendor" then
        local cap = rules.vendorCap or 40
        local made = math.max(1, rec.made or 1)
        local d = Q.Depth(rec, (P.VendorSell(rec.pid) or 0) * made, rules, cap)
        ns.db.depth = ns.db.depth or {}
        if d then
            ns.db.depth[rec.pid] = d
            return d.n * made + I.Stock(rec.pid), nil
        end
        ns.db.depth[rec.pid] = nil
        return cap, nil
    end
    -- Disenchanted and never posted: no AH demand to follow.
    if ev.channel == "de" and c.posted == 0 and (ev.posts14 or 0) == 0 then
        return st.t, nil
    end
    local fast = (rules.fastHours or 2) * 3600
    local t, why = st.t, nil
    if c.posted > 0 and c.pending == 0 then
        local soldOut = c.sold == c.posted
        if soldOut and c.median and c.median <= fast then
            t = t * 2; why = (Tr("sold out, %d in ~%s")):format(c.sold, Ago(c.median))
        elseif soldOut or c.sold >= 0.7 * c.posted then
            why = (Tr("sold %d/%d, holding")):format(c.sold, c.posted)
        elseif c.expired * 2 > c.posted then
            t = math.floor(t / 2); why = (Tr("only %d/%d sold")):format(c.sold, c.posted)
        else
            why = (Tr("sold %d/%d, holding")):format(c.sold, c.posted)
        end
    end
    t = Clamp(t, lo, rules.maxQty)
    if commit and why then
        if t ~= st.t then st.why = ("%d → %d · %s"):format(st.t, t, why) else st.why = ("%d · %s"):format(t, why) end
        st.t, st.at = t, time()
    end
    return t, st.why
end

-- Total gold: all your characters (last known amount) + warband bank.
function Q.TotalGold()
    local total = ns.Ledger and ns.Ledger.TotalMoney and ns.Ledger.TotalMoney() or (GetMoney and GetMoney() or 0)
    if C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType and Enum.BankType.Account then
        local ok, m = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
        if ok and type(m) == "number" then total = total + m end
    end
    return total
end

function Q.RichestAlt()
    local me, best, bestM = ns.Ledger and ns.Ledger.CharKey and ns.Ledger.CharKey(), nil, 0
    for key, c in pairs(ns.db.chars) do
        if key ~= me and (c.money or 0) > bestM then best, bestM = key, c.money end
    end
    return best and best:match("^[^%-]+") or nil
end

-- Units of an item the AH buys per day: your own sales of the last 7 days first, else the market's
-- (units gone between scans). nil when the data is too thin to tell.
function Q.Demand(rec, ev)
    if (ev.sold7 or 0) > 0 then return ev.sold7 / 7, "own" end
    local st = P.Stats and P.Stats(rec.pid)
    if st and st.sales and st.sales > 0 then return st.sales, "market" end
    if st and st.sales == 0 and (st.n or 0) >= 3 then return 0, "market" end
    return nil
end

-- Decides what Queue profitable does with an AH craft: "queue", "test" (one craft to try an item
-- whose demand is unknown), "nodemand" or "flooded". Also returns the expected profit per day.
function Q.DemandVerdict(rec, ev, rules)
    if ev.channel ~= "ah" then return "queue", ev.profit or 0 end
    local d = Q.Demand(rec, ev)
    if d == nil then
        local c = Cycle(ns.db.items[rec.pid] or rec.name, time() - 14 * 86400)
        if c.posted > 0 and c.sold == 0 then return "nodemand", 0 end
        return "test", 0
    end
    if d < (rules.minSales or 1) then return "nodemand", 0 end
    local listed = ev.listed or 0
    if listed / d > (rules.maxStockDays or 7) and (ev.sold7 or 0) == 0 then return "flooded", 0 end
    -- What you can expect to sell per day: your share of the market's sales, at least one unit a day
    -- when the market sells that many (a thin market leaves room for one more seller).
    local perUnit = (ev.profit or 0) / math.max(1, rec.made or 1)
    local mine = math.max(d * (rules.startShare or 5) / 100, math.min(d, 1))
    return "queue", perUnit * mine, d
end

function Q.AutoQueue(allProfs)
    local rules = CR.Rules()
    local profs = allProfs and Q.MyProfessions() or { CR.ProfName() }
    local me = UnitGUID("player")
    local db = DB()
    local added, skipped, pending, noDemand, tests, unprofitable = 0, 0, 0, 0, 0, 0
    local cands = {}
    for _, prof in ipairs(profs) do
        for k, e in pairs(db) do if e.auto and e.prof == prof and e.owner == me then db[k] = nil end end
        for _, rec in ipairs(RecipesOf(prof)) do
            local ev = CR.GetEval(rec)
            if ev.infoPending then pending = pending + 1 end
            local keepN = ns.Keep and rec.pid and ns.Keep.Get(rec.pid) or 0
            local profitable = not rec.enchant and ev.profit and not ev.unsold and not ev.whiteGear and not ev.infoPending
                and ev.profit >= rules.minProfit and (ev.margin or 0) * 100 >= rules.minMargin
            if keepN > 0 and not profitable and not rec.enchant then
                -- Personal use (e.g. cooking): craft up to the reserve, profitable or not.
                local runs = math.ceil(math.max(0, keepN - ns.GetItemCount(rec.pid)) / math.max(1, rec.made or 1))
                local k = Key(prof, rec.name)
                if runs > 0 and not (db[k] and not db[k].auto) then
                    cands[#cands + 1] = { k = k, prof = prof, name = rec.name, runs = runs, cost = ev.cost or 0, perDay = math.huge }
                end
            elseif not rec.enchant and ev.profit and not ev.infoPending and not ev.unsold and not ev.whiteGear
                and not profitable and not Q.IsMaterial(rec.pid) then
                -- Reagents count at their market price: under the minimum, selling them as they are pays about as much.
                unprofitable = unprofitable + 1
            elseif not rec.enchant and ev.profit and not ev.unsold and not ev.whiteGear and not ev.infoPending
                and not Q.IsMaterial(rec.pid)
                and ev.profit >= rules.minProfit and (ev.margin or 0) * 100 >= rules.minMargin then
                local flooded = ev.channel == "ah" and (ev.listed or 0) > rules.maxListed and (ev.sold7 or 0) == 0
                local verdict, perDay = "queue", 0
                if not flooded then verdict, perDay = Q.DemandVerdict(rec, ev, rules) end
                if flooded or verdict == "flooded" then
                    skipped = skipped + 1
                elseif verdict == "nodemand" then
                    noDemand = noDemand + 1
                elseif verdict == "test" then
                    -- Unknown demand: one craft to see if it sells, kept apart from the real queue.
                    local k = Key(prof, rec.name)
                    if I.Stock(rec.pid) == 0 and not (db[k] and not db[k].auto) then
                        cands[#cands + 1] = { k = k, prof = prof, name = rec.name, runs = 1, cost = ev.cost or 0,
                            perDay = -1, test = true }
                        tests = tests + 1
                    end
                else
                    local target = Q.Target(rec, ev, rules, true)
                    -- The personal reserve ("keep") adds to the target: it does not count as stock to sell.
                    target = target + (ns.Keep and ns.Keep.Get(rec.pid) or 0)
                    local stock = I.Stock(rec.pid)
                    local runs = math.ceil(math.max(0, target - stock) / math.max(1, rec.made or 1))
                    local k = Key(prof, rec.name)
                    if runs > 0 and not (db[k] and not db[k].auto) then
                        cands[#cands + 1] = { k = k, prof = prof, name = rec.name, runs = runs, cost = ev.cost or 0,
                            perDay = perDay }
                    end
                end
            end
        end
    end
    -- Budget: only queue what you can pay for (share of the character's gold), the recipes
    -- with the best return per gold invested first. Personal reserves (keep) go first.
    local budget = math.floor(Q.TotalGold() * (rules.budgetPct or 50) / 100)
    -- What the manual queue already uses.
    for _, e in pairs(db) do
        if not e.auto then
            local rec = Q.FindRecipe and Q.FindRecipe(e.prof, e.name)
            local ev = rec and CR.GetEval(rec)
            if ev and ev.cost then budget = budget - ev.cost * e.n end
        end
    end
    -- Best expected profit per day first (personal reserves first, one-craft tests last).
    table.sort(cands, function(a, b) return a.perDay > b.perDay end)
    local left, cut = math.max(0, budget), false
    for _, c in ipairs(cands) do
        local n = c.runs
        if c.cost > 0 then n = math.min(n, math.floor(left / c.cost)) end
        if n < c.runs then cut = true end
        if n > 0 then
            db[c.k] = { prof = c.prof, name = c.name, n = n, auto = true, owner = me, test = c.test or nil }
            left = left - n * c.cost
            added = added + 1
        end
    end
    if added > 0 and not Q.IsCrafter(me) then CrafterSet()[me] = true end -- filling a queue makes you a crafter
    local msg = (Tr("%d craft%s queued%s%s%s.")):format(added, added == 1 and "" or "s",
        cut and (Tr(" · capped by budget (%s)")):format(ns.FormatMoney(math.max(0, budget), { iconSize = 10 })) or "",
        (skipped > 0 and (Tr(" · %d skipped (flooded market)")):format(skipped) or "")
            .. (noDemand > 0 and (Tr(" · %d skipped (nobody buys them)")):format(noDemand) or "")
            .. (tests > 0 and (Tr(" · %d test craft%s (demand unknown)")):format(tests, tests == 1 and "" or "s") or "")
            .. (unprofitable > 0 and (Tr(" · %d below your minimum profit or margin")):format(unprofitable) or ""),
        pending > 0 and (Tr(" · %d still loading, click again in a second")):format(pending) or "")
    -- Crafts for the vendor: "×30 while Linen Cloth ≤ 24c".
    local vendorLines = {}
    for _, c in ipairs(cands) do
        local rec = Q.FindRecipe(c.prof, c.name)
        local d = rec and ns.db.depth and ns.db.depth[rec.pid]
        if d and db[c.k] then
            local parts = {}
            for id, mx in pairs(d.max) do
                parts[#parts + 1] = P.Name(id) .. " ≤ " .. ns.FormatMoney(mx, { iconSize = 10 })
                    .. (d.even and d.even[id] and (" (loses money above " .. ns.FormatMoney(d.even[id], { iconSize = 10 }) .. ")") or "")
            end
            if #parts > 0 then
                vendorLines[#vendorLines + 1] = (Tr("%s ×%d for the vendor, while %s")):format(c.name, db[c.k].n, table.concat(parts, ", "))
            end
        end
    end
    -- Direct purchases to resell to the vendor spotted in the last scan.
    local flips = ns.Market and ns.Market.FlipCount and ns.Market.FlipCount() or 0
    if flips > 0 then msg = msg .. (Tr(" · %d vendor flip%s on the AH (Market tab)")):format(flips, flips > 1 and "s" or "") end
    -- Gold is spread over your characters: flag when some must be sent to the buyer.
    local need = (Q.Plan().buyCost or 0) - (GetMoney and GetMoney() or 0)
    if need > 0 then
        local rich = Q.RichestAlt()
        msg = msg .. (Tr(" · mail yourself %s%s")):format(ns.FormatMoney(need, { iconSize = 10 }), rich and (" from " .. rich) or "")
    end
    if allProfs then msg = msg .. "  (" .. (#profs > 0 and table.concat(profs, ", ") or "open each profession once first") .. ")" end
    if #vendorLines > 0 then msg = msg .. Tr(" · vendor crafts: see chat") end
    Q.SetStatus(msg)
    for _, l in ipairs(vendorLines) do ns.Print(l) end
    Q.Refresh()
    return msg
end

-- "Reference" crafter: yourself if you are one, otherwise the first crafter with a queue (then simply the first).
function Q.Crafter()
    local me = Me()
    if Q.IsCrafter(me) then return me end
    local list = Q.Crafters()
    for _, k in ipairs(list) do
        for _, e in pairs(DB()) do if e.owner == k then return k end end
    end
    return list[1]
end

-- Loss threshold of a material (the highest among the queued recipes).
function Q.BreakEven(id)
    local best
    for pid, d in pairs(ns.db.depth or {}) do
        if d.even and d.even[id] then
            for _, e in pairs(DB()) do
                local rec = RecFrom(e.prof, e.name)
                if rec and rec.pid == pid then best = math.max(best or 0, d.even[id]); break end
            end
        end
    end
    return best
end

-- Maximum price to pay for a material (the highest a queued recipe tolerates).
function Q.MaxPrice(id)
    local best
    for pid, d in pairs(ns.db.depth or {}) do
        local queued = false
        for _, e in pairs(DB()) do
            local rec = RecFrom(e.prof, e.name)
            if rec and rec.pid == pid then queued = true; break end
        end
        if queued and d.max and d.max[id] then best = math.max(best or 0, d.max[id]) end
    end
    return best
end

-- ------------------------------------------------------------ plan + courses
function Q.Plan(owner)
    owner = owner or Q.Owner()
    local plan = { crafts = {}, shop = {}, cost = 0, revenue = 0, owner = owner }
    local need, order = {}, {}
    local function Need(id, qty)
        if not need[id] then need[id] = 0; order[#order + 1] = id end
        need[id] = need[id] + qty
    end
    for k, e in pairs(DB()) do
        local rec = (owner == "*" or e.owner == owner) and RecFrom(e.prof, e.name)
        if rec then
            local ev = CR.GetEval(rec)
            plan.crafts[#plan.crafts + 1] = { key = k, prof = e.prof, name = e.name, n = e.n, rec = rec, ev = ev, auto = e.auto, owner = e.owner }
            for _, rg in ipairs(rec.reagents) do if rg.id then Need(rg.id, rg.n * e.n) end end
            plan.cost = plan.cost + (ev.cost or 0) * e.n
            plan.revenue = plan.revenue + (ev.value or 0) * e.n
        end
    end
    table.sort(plan.crafts, function(a, b) return a.name < b.name end)
    -- Intermediates: a material cheaper crafted than bought, and that you can craft.
    local crafted = {}
    for _, id in ipairs({ unpack(order) }) do
        local _, src = CR.UnitCost(id)
        if src == "craft" then
            local prod, prof, name = CR.ProducerOf(id)
            if prod then
                crafted[id] = true
                local missing = need[id] - I.Mine(id) - (I.Alts(id)) -- all your characters
                local runs = math.ceil(math.max(0, missing) / math.max(1, prod.m or 1))
                if runs > 0 then
                    local rec = RecFrom(prof, name)
                    if rec then
                        table.insert(plan.crafts, 1, { key = Key(prof, name), prof = prof, name = name, n = runs,
                            rec = rec, ev = CR.GetEval(rec), inter = true })
                        for _, rg in ipairs(rec.reagents) do if rg.id then Need(rg.id, rg.n * runs) end end
                    end
                end
            end
        end
    end
    for _, id in ipairs(order) do
        local qty = need[id]
        local mine = I.Mine(id)
        local alts, detail = I.Alts(id)
        local row = { id = id, need = qty, mine = mine, alts = alts, detail = detail, name = P.Name(id),
            icon = ns.GetItemIcon(id) }
        if crafted[id] then
            row.src, row.buy = "craft", 0
            row.toCraft = math.max(0, qty - mine - alts) -- to craft before the recipes that use it
        else
            -- Vendor or AH: the cheaper. A vendor item is only bought at the AH if it is really cheaper there.
            row.src = P.IsVendorItem(id) and "vendor" or "ah"
            if row.src == "vendor" then
                local vb = P.VendorBuy(id)
                local ah = P.AHValue(id)
                if vb and ah and ah < vb then row.src, row.cheaper = "ah", vb - ah end
            end
            row.buy = math.max(0, qty - mine - alts)
        end
        row.fromAlts = math.min(alts, math.max(0, qty - mine))
        if row.buy > 0 and CR.UnitCost then
            local u = CR.UnitCost(id)
            plan.buyCost = (plan.buyCost or 0) + (u or 0) * row.buy
        end
        plan.shop[#plan.shop + 1] = row
    end
    table.sort(plan.shop, function(a, b)
        if (a.buy > 0) ~= (b.buy > 0) then return a.buy > 0 end
        return a.name < b.name
    end)
    plan.profit = plan.revenue - plan.cost
    -- List shown: only your queued recipes; intermediates appear in the shopping list ("Craft").
    plan.visible = {}
    for _, c in ipairs(plan.crafts) do if not c.inter then plan.visible[#plan.visible + 1] = c end end
    return plan
end

-- ------------------------------------------------------------ craft
local pendingCraft

-- How many times you can craft with what is IN THE BAGS (the game does not craft from the bank).
local function BagCount(id)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, false) or 0 end
    return ns.GetItemCount(id) or 0
end

local function FromBags(rec)
    local n
    for _, rg in ipairs(rec.reagents or {}) do
        if rg.id then
            local k = math.floor(BagCount(rg.id) / math.max(1, rg.n))
            n = n and math.min(n, k) or k
        end
    end
    return n or 0
end

local function FromBagsAndBank(rec)
    local n
    for _, rg in ipairs(rec.reagents or {}) do
        if rg.id then
            local k = math.floor(I.Mine(rg.id) / math.max(1, rg.n))
            n = n and math.min(n, k) or k
        end
    end
    return n or 0
end

local function Available(rec)
    local api = CR.GetAPI()
    local fromGame
    if api and api.key == "modern" and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local info = C_TradeSkillUI.GetRecipeInfo(rec.index)
        fromGame = info and info.numAvailable
    elseif api and GetTradeSkillInfo and rec.index then
        local _, _, avail = GetTradeSkillInfo(rec.index)
        fromGame = avail
    end
    -- If the game does not provide this number (or not yet), it is computed from the bags.
    local mine = FromBags(rec)
    if not fromGame or (fromGame == 0 and mine > 0) then return mine end
    return fromGame
end

local function NextCraft(plan)
    local prof = CR.ProfName()
    local blocked, inBank
    for _, c in ipairs(plan.crafts) do
        if c.prof == prof and c.n > 0 then
            local live = LiveRec(c.prof, c.name)
            if live then
                local avail = Available(live)
                if avail > 0 then return c, live, math.min(c.n, avail) end
                if not blocked then
                    blocked = c
                    inBank = FromBagsAndBank(live) > 0
                end
            end
        end
    end
    return nil, nil, 0, blocked, inBank
end

-- Next craft doable now (profession open, materials in the bags).
function Q.NextCraftable()
    if not CR.GetAPI() then return nil end
    local c, _, count = NextCraft(Q.Plan())
    return c, count
end

-- AH purchases of this character not collected yet (bought since their last mailbox visit).
-- The AH delivers by mail, and the minimap icon does not always show.
function Q.PendingMail()
    local key = ns.Ledger and ns.Ledger.CharKey and ns.Ledger.CharKey()
    local c = key and ns.db.chars[key]
    local since = c and c.lastMail or 0
    local items, order = {}, {}
    for i = #ns.db.tx, 1, -1 do
        local tx = ns.db.tx[i]
        if tx.t < since then break end
        if tx.k == "ah_buy" and tx.c == key and tx.i then
            if not items[tx.i] then items[tx.i] = 0; order[#order + 1] = tx.i end
            items[tx.i] = items[tx.i] + (tx.q or 1)
        end
    end
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = items[name] .. "× " .. name end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

function Q.CraftNext()
    local plan = Q.Plan()
    local c, live, count, blocked, inBank = NextCraft(plan)
    if not c then
        if blocked and inBank then
            Q.SetStatus((Tr("Reagents for %s are in your bank: take them out to your bags.")):format(blocked.name))
        elseif blocked and Q.PendingMail() then
            Q.SetStatus((Tr("Missing reagents for %s: your AH purchases are in the mailbox (%s).")):format(blocked.name, Q.PendingMail()))
        elseif blocked then
            Q.SetStatus((Tr("Missing reagents for %s: check the shopping list.")):format(blocked.name))
        elseif #plan.crafts > 0 then
            Q.SetStatus(Tr("Nothing to craft in this profession: open the profession of the queued recipes."))
        else
            Q.SetStatus(Tr("The queue is empty."))
        end
        return
    end
    pendingCraft = { key = c.key, left = count, inter = c.inter }
    local api = CR.GetAPI()
    if api.key == "modern" and C_TradeSkillUI.CraftRecipe then
        C_TradeSkillUI.CraftRecipe(live.index, count)
    elseif DoTradeSkill then
        DoTradeSkill(live.index, count)
    end
    Q.SetStatus((Tr("Crafting %s ×%d…")):format(c.name, count))
end

-- ------------------------------------------------------------ vendor purchases
local vendorButton
local UpdateVendorButton
local function VendorNeeds()
    local plan = Q.Plan()
    local wants = {}
    for _, row in ipairs(plan.shop) do if row.src == "vendor" and row.buy > 0 then wants[row.id] = row.buy end end
    local list = {}
    for i = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
        local id = P.ItemID(GetMerchantItemLink(i))
        if id and wants[id] then list[#list + 1] = { index = i, id = id, qty = wants[id] } end
    end
    return list
end

function Q.VendorNeedCount()
    local n = 0
    for _, w in ipairs(VendorNeeds()) do n = n + w.qty end
    return n
end

-- Buys from the vendor everything the queue still needs (vendor unit price).
-- Manual: checklist preview first; "only" = { [id] = true } limits the purchase to the checked rows.
function Q.BuyVendorNeeds(auto, only)
    local list = VendorNeeds()
    if #list == 0 then return end
    if not auto and not only and ns.Preview then
        local rows = {}
        for _, w in ipairs(list) do
            local _, _, price, stack = ns.GetMerchantItemInfo(w.index)
            local unit = (price and stack and stack > 0) and price / stack or 0
            rows[#rows + 1] = { id = w.id, qty = w.qty, value = math.floor(unit * w.qty) }
        end
        ns.Preview.Show(rows, { title = Tr("Buy from this vendor"), sub = Tr("Reagents your craft queue still needs."), confirm = Tr("Buy") },
            function(chosen)
                local set = {}
                for _, r in ipairs(chosen) do set[r.id] = true end
                Q.BuyVendorNeeds(false, set)
            end)
        return
    end
    if only then
        local f = {}
        for _, w in ipairs(list) do if only[w.id] then f[#f + 1] = w end end
        list = f
    end
    local total, spent = 0, 0
    for _, w in ipairs(list) do
        local _, _, price, stack = ns.GetMerchantItemInfo(w.index)
        local unit = (price and stack and stack > 0) and price / stack or 0
        local cost = unit * w.qty
        if GetMoney() < spent + cost then
            ns.Print(Tr("|cffed5c52not enough gold for all the vendor reagents.|r"))
            break
        end
        local left = w.qty
        local maxStack = (GetMerchantItemMaxStack and GetMerchantItemMaxStack(w.index)) or 20
        while left > 0 do
            local n = math.min(left, math.max(1, maxStack))
            BuyMerchantItem(w.index, n)
            left = left - n
        end
        total, spent = total + w.qty, spent + cost
    end
    if total > 0 then
        ns.Print((Tr("%sbought %d vendor reagent%s for your craft queue (%s).")):format(auto and "auto-" or "",
            total, total > 1 and "s" or "", ns.FormatMoney(spent, { iconSize = 11 })))
    end
    C_Timer.After(0.5, function() if UpdateVendorButton then UpdateVendorButton() end end)
end

function UpdateVendorButton()
    if ns.Routine and ns.Routine.UpdateMerchantBar then ns.Routine.UpdateMerchantBar(); return end
    if not MerchantFrame or not MerchantFrame:IsShown() then return end
    local list = VendorNeeds()
    if not vendorButton then
        vendorButton = T.Button(MerchantFrame, "", 230, 26, function()
            Q.BuyVendorNeeds(false)
        end, "primary")
        vendorButton:SetPoint("BOTTOMLEFT", MerchantFrame, "TOPLEFT", 60, 4)
        vendorButton.tooltip = Tr("Buys every vendor reagent your craft queue still needs.")
    end
    if #list > 0 then
        local n = 0
        for _, w in ipairs(list) do n = n + w.qty end
        vendorButton.text:SetText((Tr("Buy queue reagents (%d)")):format(n))
        vendorButton:Show()
    else
        vendorButton:Hide()
    end
end

-- ------------------------------------------------------------ interface ("Queue" tab)
local view
local QROWS, SROWS = 6, 6

function Q.SetStatus(text)
    if view then view.status:SetText(text or "") end
end

local SRC = {
    vendor = { "Vendor", { 0.88, 0.66, 0.24 } }, ah = { "AH", { 0.55, 0.75, 0.95 } },
    craft = { "Craft", { 0.65, 0.85, 0.55 } },
}

local function Stepper(parent, y, label, get, set, step, fmt)
    local l = T.Text(parent, 12, { color = C.text, text = label }); l:SetPoint("TOPLEFT", 16, y)
    local v = T.Text(parent, 12, { bold = true, justify = "CENTER" }); v:SetPoint("TOPRIGHT", -52, y); v:SetWidth(70)
    local minus = T.Button(parent, "−", 22, 20, function() set(get() - step); v:SetText(fmt(get())) end)
    minus:SetPoint("RIGHT", v, "LEFT", -4, 0)
    local plus = T.Button(parent, "+", 22, 20, function() set(get() + step); v:SetText(fmt(get())) end)
    plus:SetPoint("LEFT", v, "RIGHT", 4, 0)
    v:SetText(fmt(get()))
    return v
end

local function BuildRules(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    f:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
    f:EnableMouse(true)
    T.Surface(f, C.surface2, 10)
    local t = T.Text(f, 13, { bold = true, text = Tr("Queue rules") }); t:SetPoint("TOPLEFT", 16, -14)
    local r = CR.Rules()
    local function Num(k, lo, hi) return function() return r[k] end, function(v) r[k] = math.max(lo, math.min(hi, v)) end end
    local money = function(v) return ns.FormatMoney(v, { iconSize = 10 }) end
    local plain = function(v) return tostring(v) end
    local g, s
    local rows = {
        { "minProfit", 0, 1000000, "Min profit per craft", 50, money },
        { "minMargin", 0, 500, "Min margin", 5, function(v) return v .. " %" end },
        { "startQty", 1, 50, "First batch (no market data)", 1, plain },
        { "startCap", 1, 200, "First batch at most", 5, plain },
        { "startShare", 1, 100, "First batch, share of AH daily sales", 1, function(v) return v .. " %" end },
        { "fastHours", 1, 48, "Double when sold out within", 1, function(v) return v .. " h" end },
        { "minQty", 1, 50, "Stock target min", 1, plain },
        { "maxQty", 1, 1000, "Stock target cap (adaptive)", 10, plain },
        { "maxListed", 0, 1000000, "Skip if more listed than", 1000, plain },
        { "unsoldPosts", 1, 50, "\"Doesn't sell\" after posts", 1, plain },
        { "deposit", 0, 100000, "AH deposit per post", 10, money },
        { "sellChance", 5, 100, "Sell chance (no history yet)", 5, function(v) return v .. " %" end },
        { "budgetPct", 5, 100, "Spend at most (of your gold)", 5, function(v) return v .. " %" end },
        { "vendorCap", 0, 500, "Crafts for the vendor (per session)", 10, plain },
    }
    for i, d in ipairs(rows) do
        g, s = Num(d[1], d[2], d[3])
        Stepper(f, -44 - (i - 1) * 24, d[4], g, s, d[5], d[6])
    end
    -- Switch: white gear at vendor price
    local wy = -44 - #rows * 24
    local wl = T.Text(f, 12, { color = C.text, text = Tr("White gear: vendor price only") }); wl:SetPoint("TOPLEFT", 16, wy)
    local wb
    wb = T.Button(f, "", 70, 20, function()
        r.ignoreWhiteGear = not r.ignoreWhiteGear
        wb.text:SetText(r.ignoreWhiteGear and "On" or "Off"); wb:SetSelected(r.ignoreWhiteGear)
    end, "pill")
    wb:SetPoint("TOPRIGHT", -52, wy + 3)
    wb.text:SetText(r.ignoreWhiteGear and "On" or "Off"); wb:SetSelected(r.ignoreWhiteGear)
    wb.tooltip = Tr("White (common) gear rarely sells on the AH: value it at the vendor price only. Bags, armor kits and reagents are not affected.")
    local hint = T.Text(f, 11, { color = C.faint, wrap = true, justify = "LEFT",
        text = Tr("First batch: one stack at most, and a small share of what the AH sells per day (gear: 1). Then ×2 when everything sells quickly, the same when it sells, ÷2 when most comes back. Capped by your budget.") })
    hint:SetPoint("TOPLEFT", 16, -44 - (#rows + 1) * 24 - 4)
    hint:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    local done = T.Button(f, Tr("Done"), 90, 26, function() f:Hide(); CR.Refresh() end, "primary")
    done:SetPoint("BOTTOMRIGHT", -12, 12)
    f:Hide()
    return f
end

local function Card(parent)
    local f = CreateFrame("Frame", nil, parent)
    T.Surface(f, C.surface, 10)
    return f
end

local function Build(panel)
    view = CreateFrame("Frame", nil, panel)
    view:SetPoint("TOPLEFT", 12, -46)
    view:SetPoint("BOTTOMRIGHT", -12, 12)

    local auto = T.Button(view, Tr("Auto-fill"), 110, 26, function() Q.AutoQueue(IsShiftKeyDown()) end)
    auto:SetPoint("TOPLEFT", 0, 0)
    auto.tooltip = Tr("Fills the queue with what's worth crafting now, in the right quantities and within your budget. Shift-click: all your professions.")
    local clear = T.Button(view, Tr("Clear"), 64, 26, function() Q.Clear() end)
    clear:SetPoint("LEFT", auto, "RIGHT", 6, 0)
    local rulesBtn = T.Button(view, Tr("Settings"), 80, 26, function() ns.UI.Toggle("settings") end)
    rulesBtn:SetPoint("LEFT", clear, "RIGHT", 6, 0)
    rulesBtn.tooltip = Tr("Profit, margin, budget, quantities.")
    view.status = T.Text(view, 11, { color = C.muted })
    view.status:SetPoint("TOPLEFT", 2, -34)
    view.status:SetWidth(PW and PW - 30 or 400)

    -- File
    local qc = Card(view)
    qc:SetPoint("TOPLEFT", 0, -52); qc:SetPoint("TOPRIGHT", 0, -52); qc:SetHeight(32 + QROWS * 24 + 6)
    local qt = T.Text(qc, 12, { bold = true, text = Tr("To craft") }); qt:SetPoint("TOPLEFT", 14, -10)
    view.sum = T.Text(qc, 11, { color = C.muted, justify = "RIGHT" }); view.sum:SetPoint("TOPRIGHT", -12, -11)
    view.qrows = {}
    for i = 1, QROWS do
        local r = CreateFrame("Frame", nil, qc)
        r:SetHeight(24)
        r:SetPoint("TOPLEFT", 8, -30 - (i - 1) * 24); r:SetPoint("TOPRIGHT", -8, -30 - (i - 1) * 24)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(18, 18); r.icon:SetPoint("LEFT", 2, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 12); r.name:SetPoint("LEFT", 26, 0); r.name:SetWidth(124)
        r.keep = ns.Keep.Button(r); r.keep:SetPoint("LEFT", 154, 0)
        r.minus = T.Button(r, "−", 20, 18, function() if r.entry then Q.Add(r.entry.prof, r.entry.name, -1) end end)
        r.minus:SetPoint("LEFT", 204, 0)
        r.count = T.Text(r, 12, { bold = true, justify = "CENTER" }); r.count:SetPoint("LEFT", r.minus, "RIGHT", 2, 0)
        r.count:SetWidth(34)
        r.plus = T.Button(r, "+", 20, 18, function() if r.entry then Q.Add(r.entry.prof, r.entry.name, 1) end end)
        r.plus:SetPoint("LEFT", r.count, "RIGHT", 2, 0)
        r.profit = T.Text(r, 11, { justify = "RIGHT" }); r.profit:SetPoint("RIGHT", -2, 0)
        r.chan = T.Text(r, 10, { bold = true, justify = "RIGHT" }); r.chan:SetPoint("RIGHT", r.profit, "LEFT", -6, 0)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            local c = self.entry
            if not c or not c.rec.pid then return end
            T.ItemTooltip(self, c.rec.pid)
            if c.inter then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(Tr("Crafted as a reagent for the recipes below it in the queue: not sold, not mailed."), 0.6, 0.85, 0.55, true)
                GameTooltip:Show()
                return
            end
            if c.ev and c.ev.verdict then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cffe0a83dImpot|rPointGouv: " .. c.ev.verdict, 1, 1, 1)
                if c.ev.profit then
                    GameTooltip:AddDoubleLine(Tr("Profit per craft"), ns.FormatMoney(c.ev.profit, { sign = true, color = true, iconSize = 11 }), 0.7, 0.7, 0.7)
                end
                if c.prof then GameTooltip:AddDoubleLine(Tr("Profession"), c.prof, 0.7, 0.7, 0.7, 1, 1, 1) end
                local d = ns.db.depth and ns.db.depth[c.rec.pid]
                if c.ev.channel == "vendor" and not d then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine((Tr("For the vendor: up to %d per session (Rules).")):format(CR.Rules().vendorCap or 40), 0.88, 0.66, 0.24)
                    GameTooltip:AddLine(Tr("Click Scan at the AH, then Queue profitable: it tells you up to which reagent price it stays profitable."), 0.6, 0.6, 0.6, true)
                elseif d and c.ev.channel == "vendor" then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine((Tr("Profitable at the vendor up to %d crafts while:")):format(d.n), 0.88, 0.66, 0.24)
                    for id, mx in pairs(d.max) do
                        GameTooltip:AddDoubleLine((Tr("  %s (buy %d)")):format(P.Name(id), d.buy[id] or 0),
                            "≤ " .. ns.FormatMoney(mx, { iconSize = 11 }), 0.8, 0.8, 0.8, 1, 1, 1)
                        if d.even and d.even[id] then
                            GameTooltip:AddDoubleLine(Tr("    loses money above"), ns.FormatMoney(d.even[id], { iconSize = 11 }), 0.6, 0.6, 0.6, 0.93, 0.36, 0.32)
                        end
                    end
                    GameTooltip:AddLine((Tr("From your scan %s ago.")):format(P.Ago(time() - (d.t or time()) + (d.age or 0))), 0.5, 0.5, 0.5)
                else
                    local st = ns.db.settings.adapt and ns.db.settings.adapt[c.rec.pid]
                    if st then GameTooltip:AddDoubleLine(Tr("Stock target"), st.why or tostring(st.t), 0.7, 0.7, 0.7, 1, 1, 1) end
                end
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        view.qrows[i] = r
    end
    view.qempty = T.Text(qc, 12, { color = C.faint, justify = "CENTER", wrap = true,
        text = Tr("Empty. Click Auto-fill, or right-click a recipe in the profession window.") })
    view.qempty:SetPoint("CENTER", 0, -10); view.qempty:SetWidth(320)
    view.qoff = 0
    qc:EnableMouseWheel(true)
    qc:SetScript("OnMouseWheel", function(_, d)
        view.qoff = math.max(0, math.min(math.max(0, (view.ncrafts or 0) - QROWS), view.qoff - d))
        Q.Refresh()
    end)

    -- Courses
    local sc = Card(view)
    sc:SetPoint("TOPLEFT", qc, "BOTTOMLEFT", 0, -10); sc:SetPoint("TOPRIGHT", qc, "BOTTOMRIGHT", 0, -10)
    sc:SetHeight(46 + SROWS * 22 + 6)
    local st = T.Text(sc, 12, { bold = true, text = Tr("Shopping list") }); st:SetPoint("TOPLEFT", 14, -10)
    view.ssum = T.Text(sc, 11, { color = C.muted, justify = "RIGHT" }); view.ssum:SetPoint("TOPRIGHT", -12, -11)
    local cols = { { "Need", 186 }, { "Have", 226 }, { "Alts", 266 }, { "Buy", 306 } }
    for _, c in ipairs(cols) do
        local h = T.Text(sc, 10, { bold = true, color = C.faint, justify = "RIGHT", text = c[1] })
        h:SetPoint("TOPRIGHT", sc, "TOPLEFT", c[2] + 8, -30); h:SetWidth(40)
    end
    view.srows = {}
    for i = 1, SROWS do
        local r = CreateFrame("Frame", nil, sc)
        r:SetHeight(22)
        r:SetPoint("TOPLEFT", 8, -44 - (i - 1) * 22); r:SetPoint("TOPRIGHT", -8, -44 - (i - 1) * 22)
        r:EnableMouse(true)
        r.icon = r:CreateTexture(nil, "ARTWORK"); r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", 2, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.name = T.Text(r, 11); r.name:SetPoint("LEFT", 24, 0); r.name:SetWidth(126)
        local function Col(x) local t = T.Text(r, 11, { justify = "RIGHT" }); t:SetPoint("RIGHT", r, "LEFT", x, 0); t:SetWidth(40); return t end
        r.need, r.have, r.alts, r.buy = Col(186), Col(226), Col(266), Col(306)
        r.src = T.Text(r, 10, { bold = true }); r.src:SetPoint("LEFT", 318, 0)
        r:SetScript("OnEnter", function(self)
            local row = self.row
            if not row then return end
            T.ItemTooltip(self, row.id)
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(Tr("Needed"), row.need, 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine(Tr("On this character (bags + bank)"), row.mine, 0.7, 0.7, 0.7, 1, 1, 1)
            for _, d in ipairs(row.detail or {}) do
                GameTooltip:AddDoubleLine("  " .. d[1], d[2], 0.7, 0.7, 0.7, 1, 1, 1)
            end
            if row.fromAlts > 0 then GameTooltip:AddLine(Tr("Mail ") .. row.fromAlts .. Tr(" from your alts."), 0.88, 0.66, 0.24) end
            if row.src == "craft" then GameTooltip:AddLine(Tr("Cheaper to craft: added to the queue automatically."), 0.65, 0.85, 0.55) end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        view.srows[i] = r
    end
    view.sempty = T.Text(sc, 12, { color = C.faint, justify = "CENTER", text = Tr("Nothing to buy.") })
    view.sempty:SetPoint("CENTER", 0, -10)
    view.soff = 0
    sc:EnableMouseWheel(true)
    sc:SetScript("OnMouseWheel", function(_, d)
        view.soff = math.max(0, math.min(math.max(0, (view.nshop or 0) - SROWS), view.soff - d))
        Q.Refresh()
    end)

    view.rules = BuildRules(view)

    view.craft = T.Button(view, Tr("Craft next"), 200, 36, function() Q.CraftNext() end, "primary")
    view.craft:HookScript("OnEnter", function(self)
        local key = ns.Next and ns.Next.Key()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(Tr("Crafts every queued copy of the next recipe."), 1, 1, 1, true)
        GameTooltip:AddLine(key and ("\"Next action\" key: " .. key .. Tr(" (crafts; disenchants when the Disenchant window is open)"))
            or "Tip: bind \"Next action\" in Options > Keybindings > AddOns > ImpotPointGouv to craft and disenchant with one key.",
            0.88, 0.66, 0.24, true)
        GameTooltip:Show()
    end)
    view.craft:SetPoint("BOTTOMLEFT", 0, 0); view.craft:SetPoint("BOTTOMRIGHT", 0, 0)
    view:Hide()
end

function Q.ShowIn(panel)
    if not view then Build(panel) end
    view:Show()
    Q.Refresh()
end

function Q.HideView() if view then view:Hide() end end

function Q.Refresh()
    UpdateVendorButton()
    if ns.Routine and ns.Routine.Refresh then ns.Routine.Refresh() end
    if ns.Next then C_Timer.After(0.2, ns.Next.Arm) end
    if not view or not view:IsShown() then return end
    local plan = Q.Plan()
    local list = plan.visible
    view.ncrafts = #list
    view.qoff = math.min(view.qoff, math.max(0, #list - QROWS))
    for i, r in ipairs(view.qrows) do
        local c = list[view.qoff + i]
        if c then
            r.entry = c
            r.icon:SetTexture(c.rec.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local qe = c.key and DB()[c.key]
            r.name:SetText(c.inter and ("|cff9ad98c" .. c.name .. Tr("|r  |cff615f5c· reagent|r"))
                or (qe and qe.test and (c.name .. Tr("  |cff615f5c· test|r")) or c.name))
            r.name:SetWidth(c.inter and 186 or 124) -- no keep button or +/- on an intermediate
            r.keep:SetItem(not c.inter and c.rec.pid or nil)
            r.count:SetText("×" .. c.n)
            r.minus:SetShown(not c.inter); r.plus:SetShown(not c.inter)
            if c.ev.profit and not c.inter then
                r.profit:SetText(ns.FormatMoney(c.ev.profit * c.n, { sign = true, color = true, short = true, iconSize = 10 }))
            else
                r.profit:SetText("")
            end
            r.chan:SetText(c.inter and "" or ns.ChannelLabel(c.ev.channel))
            r:Show()
        else
            r.entry = nil
            r:Hide()
        end
    end
    view.qempty:SetShown(#plan.crafts == 0)
    view.sum:SetText(#plan.crafts > 0 and (Tr("cost %s  ·  profit %s")):format(
        ns.FormatMoney(plan.cost, { short = true, iconSize = 10 }),
        ns.FormatMoney(plan.profit, { sign = true, color = true, short = true, iconSize = 10 })) or "")

    view.nshop = #plan.shop
    view.soff = math.min(view.soff, math.max(0, #plan.shop - SROWS))
    local buyCost = 0
    for _, row in ipairs(plan.shop) do
        if row.buy > 0 then
            local unit = row.src == "vendor" and P.VendorBuy(row.id) or P.AHValue(row.id)
            buyCost = buyCost + (unit or 0) * row.buy
        end
    end
    for i, r in ipairs(view.srows) do
        local row = plan.shop[view.soff + i]
        r.row = row
        if row then
            r.icon:SetTexture(row.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(row.name)
            r.need:SetText(row.need)
            r.have:SetText(row.mine >= row.need and ("|cff5cd173" .. row.mine .. "|r") or row.mine)
            r.alts:SetText(row.alts > 0 and ("|cffe0a83d" .. row.alts .. "|r") or "|cff615f5c0|r")
            if row.src == "craft" then
                r.buy:SetText((row.toCraft or 0) > 0 and ("|cff9ad98c" .. row.toCraft .. "|r") or "|cff5cd173✓|r")
            else
                r.buy:SetText(row.buy > 0 and ("|cffed5c52" .. row.buy .. "|r") or "|cff5cd173✓|r")
            end
            local s = SRC[row.src]
            local mx = row.src == "ah" and Q.MaxPrice(row.id)
            r.src:SetText(mx and ("≤ " .. ns.FormatMoney(mx, { short = true, iconSize = 9 })) or s[1])
            r.src:SetTextColor(s[2][1], s[2][2], s[2][3])
            r:Show()
        else
            r:Hide()
        end
    end
    view.sempty:SetShown(#plan.shop == 0)
    view.ssum:SetText(buyCost > 0 and ("to buy ≈ " .. ns.FormatMoney(buyCost, { short = true, iconSize = 10 })) or "")

    local c, _, count, blocked, inBank = NextCraft(plan)
    if c then
        view.craft.text:SetText((Tr("Craft next:  %s ×%d")):format(c.name, count))
        view.craft:SetDisabled(false)
    else
        view.craft.text:SetText(blocked and (inBank and ("Reagents in your bank (" .. blocked.name .. ")")
            or (Q.PendingMail() and "Your AH purchases are in the mailbox")
            or ("Missing reagents for " .. blocked.name)) or "Craft next")
        view.craft:SetDisabled(true)
    end
    -- Tab: counter
    local panel = CR.Panel()
    if panel and panel.tabButtons then
        local n = 0
        for _, e in pairs(DB()) do n = n + e.n end
        panel.tabButtons.queue.text:SetText(n > 0 and ("Queue (" .. n .. ")") or "Queue")
    end
end

-- ------------------------------------------------------------ events
local ev = CreateFrame("Frame")
if ns.Profile then ns.Profile.Frame(ev, "Queue") end
for _, e in ipairs({ "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
    "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, a1, a2)
    if not ns.db then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" and pendingCraft and pendingCraft.left > 0 then
            pendingCraft.left = pendingCraft.left - 1
            if not pendingCraft.inter then
                local e = DB()[pendingCraft.key]
                if e then
                    e.n = e.n - 1
                    if e.n <= 0 then DB()[pendingCraft.key] = nil end
                end
            end
            if pendingCraft.left <= 0 then pendingCraft = nil end
            C_Timer.After(0.3, Q.Refresh)
        end
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        if a1 == "player" and pendingCraft then pendingCraft = nil; C_Timer.After(0.3, Q.Refresh) end
    elseif event == "MERCHANT_SHOW" then
        -- Automatic purchase of the queue's vendor materials (can be turned off: /ipg vendor).
        if ns.db.settings.autoVendorBuy == true then
            C_Timer.After(0.4, function() Q.BuyVendorNeeds(true) end)
        end
        C_Timer.After(0.1, UpdateVendorButton)
    elseif event == "MERCHANT_UPDATE" then
        C_Timer.After(0.1, UpdateVendorButton)
    end
end)
ns.On("INVENTORY_CHANGED", function() Q.Refresh() end)
